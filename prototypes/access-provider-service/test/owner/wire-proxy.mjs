// Import-safe PostgreSQL protocol fixture. start() alone opens an owned listener.
import { createServer, createConnection } from 'node:net';
import { createHash, randomBytes } from 'node:crypto';
import { performance } from 'node:perf_hooks';

export const WIRE_LIMITS = Object.freeze({ connections:12, startup:8192, frame:262144,
  buffered:524288, total:8388608, transactionMs:5000, metadata:1024 });
export class WireError extends Error { constructor(code){super(code);this.code=code;} }
const fail=code=>{throw new WireError(code);};
const types=new Set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'.split(''));
export function cstring(data, offset=0) {
  const end=data.indexOf(0,offset);if(end<offset)fail('WIRE_CSTRING');
  return { value:data.subarray(offset,end).toString('utf8'), next:end+1 };
}
export class FrameDecoder {
  #buffer=Buffer.alloc(0);#startup;
  constructor({startup=false}={}){this.#startup=startup;}
  get bufferedBytes(){return this.#buffer.length;}
  push(chunk) {
    if(!Buffer.isBuffer(chunk))fail('WIRE_BUFFER');
    if(this.#buffer.length+chunk.length>WIRE_LIMITS.buffered)fail('WIRE_BUFFER_LIMIT');
    this.#buffer=Buffer.concat([this.#buffer,chunk]);const frames=[];
    while(this.#buffer.length>=(this.#startup?4:5)) {
      const startup=this.#startup,offset=startup?0:1,length=this.#buffer.readUInt32BE(offset);
      if(length<(startup?8:4)||length>(startup?WIRE_LIMITS.startup:WIRE_LIMITS.frame))fail('WIRE_FRAME_LIMIT');
      const bytes=length+(startup?0:1);if(this.#buffer.length<bytes)break;
      const raw=Buffer.from(this.#buffer.subarray(0,bytes));this.#buffer=this.#buffer.subarray(bytes);
      if(startup){if(raw.readUInt32BE(4)!==196608)fail('WIRE_SSL_CANCEL_OR_PROTOCOL');this.#startup=false;}
      else if(!types.has(String.fromCharCode(raw[0])))fail('WIRE_MESSAGE_TYPE');
      frames.push({type:startup?'Startup':String.fromCharCode(raw[0]),body:raw.subarray(startup?4:5),raw});
    }
    return frames;
  }
  clear(){this.#buffer=Buffer.alloc(0);}
}
export function classifySql(sql) {
  if(typeof sql!=='string'||Buffer.byteLength(sql)>WIRE_LIMITS.frame)fail('WIRE_SQL_LIMIT');
  // The reviewed migration is one simple-query batch. Permit exactly its
  // immutable bytes; arbitrary multiple statements remain unsupported.
  if(createHash('sha256').update(sql).digest('hex')==='540f1bbcf801adc89e7c1b08c76a77992ac85b881b7090dc41acd29dcf6b0757')return 'migration';
  const s=sql.trim().replace(/;$/,'').toUpperCase();
  // This fixture intentionally refuses multi-command simple queries.
  if(s.includes(';')||/\bCOPY\b/.test(s))fail('WIRE_UNSUPPORTED_SQL');
  if(/^BEGIN(?:\s|$)/.test(s))return /SERIALIZABLE/.test(s)?'business-begin':'clock-begin-tx';
  if(s==='COMMIT')return 'commit';if(s==='ROLLBACK')return 'rollback';
  if(/\bPROVIDER_B1\.CLOCK_BEGIN\s*\(/.test(s))return 'marker';
  if(/\bPROVIDER_B1\.CLOCK_FINISH\s*\(/.test(s))return 'observation';
  if(/^INSERT\s+INTO\s+PROVIDER_B1\.OPERATIONS\b/.test(s))return 'issuance';
  return 'other';
}
export function errorSqlState(body) {
  let offset=0,code=null;
  while(offset<body.length&&body[offset]!==0){const type=String.fromCharCode(body[offset++]);const field=cstring(body,offset);offset=field.next;if(type==='C')code=field.value;}
  if(offset!==body.length-1||!code||!/^[0-9A-Z]{5}$/.test(code))fail('WIRE_ERROR_RESPONSE');
  return code;
}
// Tracks only a single query at a time; SCRAM/parameters are never interpreted.
export class CommitTracker {
  transaction=null;pending=null;kind=null;issuance=false;commitAck=false;
  #statements=new Map();#portals=new Map();#stored=0;#select;#record;#extended=false;
  constructor({select=()=>false,record=()=>{}}={}){this.#select=select;this.#record=record;}
  get storedBytes(){return this.#stored;}
  #remember(map,key,value){
    const old=map.get(key);this.#stored-=old?Buffer.byteLength(key)+Buffer.byteLength(old):0;
    this.#stored+=Buffer.byteLength(key)+Buffer.byteLength(value);
    if(map.size>=64&&!map.has(key)||this.#stored>262144)fail('WIRE_STATEMENT_LIMIT');map.set(key,value);
  }
  #query(kind){
    if(this.pending)fail('WIRE_PIPELINING');this.pending=kind;
    if(kind==='business-begin'||kind==='clock-begin-tx'){
      if(this.transaction)fail('WIRE_NESTED_TRANSACTION');this.transaction=kind==='business-begin'?'business':'clock';this.kind=null;this.issuance=false;
    }
    if(kind==='marker'||kind==='observation'){if(this.transaction!=='clock')fail('WIRE_CLOCK_SEQUENCE');this.kind=kind;}
    if(kind==='issuance'){if(this.transaction!=='business')fail('WIRE_ISSUANCE_SEQUENCE');this.issuance=true;}
    if(kind==='commit'){
      const mode=this.transaction==='business'&&this.issuance?'issuance':this.transaction==='clock'?this.kind:null;
      this.selected=mode!==null&&this.#select(mode);this.mode=mode;this.commitAck=false;
    }
  }
  frontend(frame){
    const {type,body}=frame;
    if(type==='Startup'||type==='p')return; // Authentication bytes pass through without logging.
    if(['d','f','c'].includes(type))fail('WIRE_COPY_UNSUPPORTED');
    if(type==='Q'){
      const q=cstring(body);if(q.next!==body.length)fail('WIRE_QUERY');this.#extended=false;this.#query(classifySql(q.value));return;
    }
    if(type==='P'){
      if(this.pending)fail('WIRE_PIPELINING');const n=cstring(body),q=cstring(body,n.next);
      if(q.next+2>body.length||q.next+2+body.readUInt16BE(q.next)*4!==body.length)fail('WIRE_PARSE');
      this.#remember(this.#statements,n.value,q.value);return;
    }
    if(type==='B'){
      if(this.pending)fail('WIRE_PIPELINING');const p=cstring(body),s=cstring(body,p.next);let o=s.next;
      const count=()=>{if(o+2>body.length)fail('WIRE_BIND');const n=body.readUInt16BE(o);o+=2;return n;};
      const formats=count();if(o+formats*2>body.length)fail('WIRE_BIND');o+=formats*2;
      const parameters=count();for(let i=0;i<parameters;i++){if(o+4>body.length)fail('WIRE_BIND');const n=body.readInt32BE(o);o+=4;if(n< -1||n>body.length-o)fail('WIRE_BIND');if(n>=0)o+=n;}
      const results=count();o+=results*2;if(o!==body.length||!this.#statements.has(s.value))fail('WIRE_BIND');
      this.#remember(this.#portals,p.value,s.value);return;
    }
    if(type==='E'){
      const p=cstring(body);if(p.next+4!==body.length||body.readUInt32BE(p.next)!==0||!this.#portals.has(p.value))fail('WIRE_EXECUTE');
      this.#extended=true;this.#query(classifySql(this.#statements.get(this.#portals.get(p.value))));return;
    }
    if(type==='S'){if(body.length!==0||!this.pending||!this.#extended)fail('WIRE_SYNC');this.#extended=false;return;}
    if(type==='D'){if(this.pending)fail('WIRE_PIPELINING');const d=cstring(body,1);if(!['S','P'].includes(String.fromCharCode(body[0]))||d.next!==body.length)fail('WIRE_DESCRIBE');return;}
    if(type==='C'){if(this.pending)fail('WIRE_PIPELINING');const c=cstring(body,1),map=body[0]===83?this.#statements:body[0]===80?this.#portals:null;if(!map||c.next!==body.length)fail('WIRE_CLOSE');const old=map.get(c.value);if(old)this.#stored-=Buffer.byteLength(c.value)+Buffer.byteLength(old);map.delete(c.value);return;}
    if(type==='X'&&body.length===0)return;
    fail('WIRE_FRONTEND_UNSUPPORTED');
  }
  backend(frame){
    const {type,body}=frame;
    if(['G','H','W','d','c'].includes(type))fail('WIRE_COPY_UNSUPPORTED');
    if(type==='E'){
      const state=errorSqlState(body);this.#record({sqlState:state});
      if(this.selected)fail('WIRE_SELECTED_COMMIT_ERROR');return {forward:true};
    }
    if(type==='C'){
      const c=cstring(body);if(c.next!==body.length)fail('WIRE_COMMAND_COMPLETE');
      if(this.selected){if(this.pending!=='commit'||c.value!=='COMMIT')fail('WIRE_SELECTED_NOT_COMMIT');this.commitAck=true;return {forward:false};}
    }
    if(type==='Z'){
      if(body.length!==1||!'ITE'.includes(String.fromCharCode(body[0])))fail('WIRE_READY');
      const status=String.fromCharCode(body[0]);
      if(this.selected){if(!this.commitAck||status!=='I')fail('WIRE_COMMIT_NOT_CONFIRMED');return {forward:false,disconnect:true,committed:this.mode};}
      if(this.pending==='commit'||this.pending==='rollback'||status==='I'){this.transaction=null;this.kind=null;this.issuance=false;}
      this.pending=null;
    }
    return {forward:true};
  }
  clear(){this.#statements.clear();this.#portals.clear();this.#stored=0;}
}
function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});promise.catch(()=>{});return {promise,resolve,reject};}
// Startup is complete only after AuthenticationOk and the initial idle Ready.
// This same timer state is used by the listener and by pure transport tests.
export class WireLifetime {
  startupComplete=false;#startupSeen=false;#authenticated=false;#startupTimer;#transactionTimer=null;#schedule;#cancel;
  constructor({onExpire,schedule=setTimeout,cancel=clearTimeout}) {
    this.#schedule=schedule;this.#cancel=cancel;
    this.onExpire=onExpire;this.#startupTimer=schedule(()=>onExpire(new WireError('WIRE_STARTUP_DEADLINE')),WIRE_LIMITS.transactionMs);
  }
  frontend(frame){
    if(frame.type==='Startup'){if(this.#startupSeen)fail('WIRE_DUPLICATE_STARTUP');this.#startupSeen=true;return;}
    if(!this.startupComplete&&frame.type!=='p')fail('WIRE_AUTHENTICATION_INCOMPLETE');
  }
  backend(frame){
    if(this.startupComplete)return;
    if(frame.type==='R'){
      if(!this.#startupSeen||frame.body.length<4)fail('WIRE_AUTHENTICATION_SEQUENCE');
      if(frame.body.readUInt32BE(0)===0){if(frame.body.length!==4)fail('WIRE_AUTHENTICATION_OK');this.#authenticated=true;}
    }
    if(frame.type==='Z'){
      if(!this.#startupSeen||!this.#authenticated||frame.body.length!==1||frame.body[0]!==73)fail('WIRE_STARTUP_NOT_COMPLETE');
      this.startupComplete=true;this.#cancel(this.#startupTimer);this.#startupTimer=null;
    }
  }
  transaction(active){
    if(!this.startupComplete)return;
    if(active&&this.#transactionTimer===null)this.#transactionTimer=this.#schedule(()=>this.onExpire(new WireError('WIRE_TRANSACTION_DEADLINE')),WIRE_LIMITS.transactionMs);
    if(!active&&this.#transactionTimer!==null){this.#cancel(this.#transactionTimer);this.#transactionTimer=null;}
  }
  close(){if(this.#startupTimer!==null)this.#cancel(this.#startupTimer);if(this.#transactionTimer!==null)this.#cancel(this.#transactionTimer);this.#startupTimer=null;this.#transactionTimer=null;}
}
export class WireProxy {
  #server=null;#connections=new Set();#fault=null;#salt=randomBytes(32);#events=[];#authorize;#onFailure;#backend;#closed=false;#starting=false;#createListener;
  constructor({backendPort,authorize,onFailure=()=>{},createListener=createServer}){
    if(!Number.isSafeInteger(backendPort)||backendPort<1||backendPort>65535||typeof authorize!=='function'||typeof createListener!=='function')fail('WIRE_OWNER_REQUIRED');
    this.#backend=backendPort;this.#authorize=authorize;this.#onFailure=onFailure;this.#createListener=createListener;
  }
  get metadata(){return this.#events.map(x=>({...x}));}
  connectionIdentity(frontendPort){return [...this.#connections].find(c=>c.front.remotePort===frontendPort)?.id??null;}
  arm(mode){
    if(!['issuance','marker','observation'].includes(mode)||this.#fault)fail('WIRE_ARM');
    const d=deferred();this.#fault={...d,mode,selected:null};return d.promise;
  }
  disarm(reason=new WireError('WIRE_NOT_INJECTED')){const f=this.#fault;this.#fault=null;f?.reject(reason);}
  #record(event){if(this.#events.length>=WIRE_LIMITS.metadata)this.#events.shift();this.#events.push({atMs:performance.now(),...event});}
  #bounds(){
    let total=0;for(const c of this.#connections){const n=c.frontDecode.bufferedBytes+c.backDecode.bufferedBytes+c.tracker.storedBytes+c.front.writableLength+c.back.writableLength;if(n>WIRE_LIMITS.buffered)fail('WIRE_BUFFER_LIMIT');total+=n;}
    if(total>WIRE_LIMITS.total)fail('WIRE_TOTAL_LIMIT');
  }
  async start({deadline,signal}={}){
    if(this.#server||this.#closed||this.#starting)fail('WIRE_ALREADY_STARTED');
    if(!signal||typeof signal.addEventListener!=='function')fail('WIRE_OWNER_REQUIRED');
    const check=()=>{if(this.#closed)fail('WIRE_ALREADY_STARTED');if(signal.aborted)fail('WIRE_CANCELLED');if(!Number.isFinite(deadline)||performance.now()>=deadline)fail('WIRE_PHASE_DEADLINE');};
    this.#starting=true;let server;
    try{
      check();await this.#authorize('start-owned-wire-proxy');check();
      server=this.#createListener(front=>this.#accept(front));check();this.#server=server;
      server.on('error',error=>{this.disarm(error);this.#onFailure(error);});
      await new Promise((resolve,reject)=>{
        let timer,done=false;
        const finish=error=>{if(done)return;done=true;clearTimeout(timer);signal.removeEventListener('abort',abort);server.removeListener('error',failed);error?reject(error):resolve();};
        const abort=()=>finish(new WireError('WIRE_CANCELLED')),failed=error=>finish(error);
        server.once('error',failed);signal.addEventListener('abort',abort,{once:true});
        timer=setTimeout(()=>finish(new WireError('WIRE_PHASE_DEADLINE')),Math.max(0,Math.floor(deadline-performance.now())));
        try{check();server.listen({host:'127.0.0.1',port:0,exclusive:true},()=>{try{check();finish();}catch(error){finish(error);}});}catch(error){finish(error);}
      });
      check();return server.address().port;
    }catch(error){if(server){this.#closed=true;try{server.close(()=>{});}catch{}}throw error;}
    finally{this.#starting=false;}
  }
  #accept(front){
    if(this.#closed||this.#connections.size>=WIRE_LIMITS.connections){front.destroy();return;}
    const back=createConnection({host:'127.0.0.1',port:this.#backend});
    const id=createHash('sha256').update(this.#salt).update(randomBytes(16)).digest('hex').slice(0,24);
    const c={id,front,back,frontDecode:new FrameDecoder({startup:true}),backDecode:new FrameDecoder(),tracker:null,lifetime:null};
    const abort=error=>{if(error){this.disarm(error);this.#onFailure(error);}c.lifetime?.close();front.destroy();back.destroy();c.frontDecode.clear();c.backDecode.clear();c.tracker.clear();this.#connections.delete(c);};
    c.lifetime=new WireLifetime({onExpire:abort});
    c.tracker=new CommitTracker({select:mode=>{
      if(this.#fault?.mode!==mode||this.#fault.selected!==null)return false;this.#fault.selected=id;return true;
    },record:event=>this.#record({connection:id,...event})});this.#connections.add(c);
    front.on('error',abort);back.on('error',abort);front.on('close',()=>abort());back.on('close',()=>{if(this.#fault?.selected===id)abort(new WireError('WIRE_EOF_BEFORE_ACK'));else abort();});
    const pipe=(input,decoder,output,direction)=>input.on('data',chunk=>{
      try{
        for(const frame of decoder.push(chunk)){
          // Authentication messages contain SCRAM/passwords and are omitted entirely.
          if(frame.type!=='p'&&frame.type!=='R'&&frame.type!=='Startup')this.#record({connection:id,direction,type:frame.type,bytes:frame.raw.length});
          let action={forward:true};
          if(direction==='front'){c.lifetime.frontend(frame);c.tracker.frontend(frame);}else{c.lifetime.backend(frame);action=c.tracker.backend(frame);}
          c.lifetime.transaction(c.tracker.transaction!==null);
          if(action.forward&&!output.write(frame.raw)){input.pause();output.once('drain',()=>{if(!input.destroyed)input.resume();});}
          this.#bounds();
          if(action.disconnect){const f=this.#fault;this.#fault=null;this.#record({connection:id,mode:action.committed,commitCommandComplete:true,readyForQuery:'I',ackForwarded:false});f?.resolve({connection:id,mode:action.committed,commitCommandComplete:true,readyForQuery:'I',ackForwarded:false});abort();break;}
        }
        this.#bounds();
      }catch(error){abort(error);}
    });
    pipe(front,c.frontDecode,back,'front');pipe(back,c.backDecode,front,'back');

  }
  async close(ms=1000){
    this.#closed=true;this.disarm();for(const c of [...this.#connections]){c.lifetime.close();c.front.destroy();c.back.destroy();}
    const server=this.#server;if(!server)return;
    let timer;try{await Promise.race([new Promise(resolve=>server.close(resolve)),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new WireError('WIRE_CLOSE_INCOMPLETE')),ms);})]);}finally{clearTimeout(timer);}
  }
}
