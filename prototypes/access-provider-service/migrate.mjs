import { readFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { validateTrust, reject } from './proof.mjs';
import { withOwnedPgClient,closeOwnedPool } from './store.mjs';

// Consumes the dedicated owned bootstrap pool. No CLI/import side effects.
// Admission/read/checkout/DDL share 4s, with up to 1s reserved for closure.
export async function migrate({pool,trust,owner,verifyOwner,signal}) {
  const totalDeadline=performance.now()+5000,controller=new AbortController();
  const relay=()=>controller.abort(signal.reason);
  signal?.addEventListener('abort',relay,{once:true});if(signal?.aborted)relay();
  let entered=false;
  try {
    const binding=validateTrust(trust);
    if(!pool||typeof pool.connect!=='function'||typeof pool.on!=='function'||typeof pool.end!=='function'||typeof verifyOwner!=='function')reject('SQL_NOT_ADMITTED');
    entered=true;
    return await withOwnedPgClient(pool,{deadline:totalDeadline-1000,signal:controller.signal},async context=>{
      await verifyOwner(owner,'create-fresh-schema',context);
      return readFile(new URL('./sql/001-b1.sql',import.meta.url),'utf8');
    },async(client,scope,sql)=>{
      let began=false,commitSent=false;
      try {
        await client.query('BEGIN');began=true;
        await client.query("SET LOCAL lock_timeout = '250ms'");await client.query("SET LOCAL statement_timeout = '1s'");
        await client.query("SET LOCAL idle_in_transaction_session_timeout = '1s'");
        const {rows}=await client.query("SELECT current_user AS role, current_database() AS database, to_regnamespace('provider_b1') AS schema");
        if(rows.length!==1||rows[0].role!=='b1_bootstrap'||rows[0].database!=='b1'||rows[0].schema!==null)reject('SQL_NOT_ADMITTED');
        await client.query('SET LOCAL ROLE b1_migrator');await client.query(sql);
        await client.query('INSERT INTO provider_b1.domains (issuer,realm,service_environment,audience,trust_epoch,time_highwater,revocation_seq) VALUES ($1,$2,$3,$4,$5,0,0)',
          [binding.issuer,binding.realm,binding.serviceEnvironment,binding.audience,binding.trustEpoch]);
        scope.check();commitSent=true;await client.query('COMMIT');began=false;
      }catch(error){
        if(commitSent)client.release(true);else await client.rollback(began);
        throw error;
      }
    });
  }finally{
    controller.abort();signal?.removeEventListener('abort',relay);
    if(entered)await closeOwnedPool(pool,Math.max(0,totalDeadline-performance.now()));
  }
}
