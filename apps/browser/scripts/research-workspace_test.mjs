// 执行真实界面函数，覆盖选择边界、失败刷新和网页标题的惰性显示。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
const root=fileURLToPath(new URL('../../../', import.meta.url));
const ts=createRequire(root+'/packages/core/package.json')('typescript');
const path=root+'/apps/browser/overlay/chrome/browser/resources/aegis_agent/agent.ts';
const source=readFileSync(path,'utf8');
const tree=ts.createSourceFile(path,source,ts.ScriptTarget.Latest,true);
const names=['refreshResearchTabs','updateResearchSelection','researchMessage','renderSavedResearch','refreshSavedResearch','renderDownloadEvidence','render'];
const functions=tree.statements.filter(n=>ts.isFunctionDeclaration(n)&&names.includes(n.name?.text));
assert.equal(functions.length,names.length);
const compile=ts.transpileModule(functions.map(n=>n.getText(tree)).join('\n'),{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
function dom(){return {children:[],events:{},dataset:{},value:'比较事实',disabled:false,checked:false,
 get childElementCount(){return this.children.length},
 append(...children){this.children.push(...children)},replaceChildren(){this.children=[]},
 setAttribute(){},focus(){},addEventListener(name,callback){this.events[name]=callback}};}
const elements=new Map();const element=id=>{if(!elements.has(id))elements.set(id,dom());return elements.get(id)};
let fail=false;
const tabs=Array.from({length:11},(_,i)=>({tabId:i+1,title:i===0?'<script>不要执行</script>':'来源'+i,url:'https://fixture.example/'+i}));
const ctx=vm.createContext({element,document:{createElement:dom,querySelector:()=>dom()},loadTimeData:{getString:key=>key},
 busy:false,researchTabs:[],selectedResearchTabs:new Set(),proxy:{handler:{listResearchTabs:async()=>{
 if(fail)throw new Error('fixture failure');return {tabs,error:''};}}}});
vm.runInContext(compile,ctx);
await ctx.refreshResearchTabs();
assert.equal(element('research-sources').children.length,11);
assert.equal(element('research-start').disabled,true);assert.equal(element('research-group').disabled,true);
const check=i=>element('research-sources').children[i].children[0];
check(0).checked=true;check(0).events.change();
assert.equal(element('research-start').disabled,true);assert.equal(element('research-group').disabled,false);
for(let i=0;i<3;i++){check(i).checked=true;check(i).events.change();}
assert.equal(element('research-start').disabled,false);assert.equal(element('research-group').disabled,false);
assert.equal(element('research-sources').children[0].children[1].children[0].textContent,tabs[0].title);
for(let i=3;i<11;i++){check(i).checked=true;check(i).events.change();}
assert.equal(element('research-start').disabled,true);assert.equal(element('research-group').disabled,true);
check(10).checked=false;check(10).events.change();
assert.equal(element('research-start').disabled,false);assert.equal(element('research-group').disabled,false);
ctx.busy=true;ctx.updateResearchSelection();assert.equal(element('research-start').disabled,true);assert.equal(element('research-group').disabled,true);
ctx.busy=false;element('research-goal').value=' ';ctx.updateResearchSelection();assert.equal(element('research-start').disabled,true);assert.equal(element('research-group').disabled,false);
element('research-goal').value='比较事实';fail=true;await ctx.refreshResearchTabs();
assert.equal(ctx.selectedResearchTabs.size,0);assert.equal(element('research-sources').children.length,0);
assert.equal(element('research-start').disabled,true);assert.equal(element('research-group').disabled,true);assert.equal(element('research-error').hidden,false);
console.log('研究选择真实函数回归通过：范围3–10、空目标、忙碌、惰性标题及失败刷新；不是App验收。');

const record={id:'saved',goal:'<script>不执行</script>',summary:'比较结果',outcome:'partial',createdMs:'1789530000000',unfinished:['一个来源不可读'],sources:[{title:'文章',url:'https://fixture.example/source',excerpt:'可核对的原文',available:true}]};
let status='changed';const calls=[];
ctx.proxy.handler.listSavedResearch=async()=>({records:[record],error:'',sessionOnly:false});
ctx.proxy.handler.openResearchSource=async(...args)=>{calls.push(args);return {ok:true}};
ctx.proxy.handler.reviewResearchSource=async(...args)=>{calls.push(args);return {status}};
ctx.proxy.handler.deleteSavedResearch=async id=>{calls.push(id);return {error:''}};
ctx.renderView=()=>{};
await ctx.refreshSavedResearch();
const saved=element('saved-research-list').children[0];
assert.equal(saved.children[0].textContent,record.goal);
assert.equal(saved.children[3].textContent,'resultPartialHelp');
assert.equal(saved.children[4].children[0].textContent,record.unfinished[0]);
const sourceRow=saved.children[5];
await sourceRow.children[3].events.click();
assert.equal(sourceRow.children[6].textContent,'researchSourceOpened');
await sourceRow.children[4].events.click();
assert.equal(sourceRow.children[6].textContent,'researchSourceChanged');
status='matched';await sourceRow.children[4].events.click();
assert.equal(sourceRow.children[6].textContent,'researchSourceMatched');
status='unexpected';await sourceRow.children[4].events.click();
assert.equal(sourceRow.children[6].textContent,'researchSourceUnavailable');
assert.equal(JSON.stringify(calls.slice(0,2)),JSON.stringify([['saved',0],['saved',0]]));
// 023 原生验收曾出现预填目标后按钮仍禁用，直到手动编辑才启用。
// 执行实际 render 与点击回调，保留忙碌/模型未配置时的禁用约束。
Object.assign(ctx, {creatingTask:false,selectedTaskId:null,taskCreationError:'',
  snapshot:{taskId:'saved',state:'completed',modelConfigured:true,downloadEvidence:[]},
  statusTone:()=>'',humanStatus:()=>'',refersToCurrentPage:()=>false,
  renderModel:()=>{},renderPlan:()=>{},renderResult:()=>{},renderTimeline:()=>{},
  renderMonitors:()=>{},friendlyError:()=>'',renderCheckoutSummary:()=>{},
  scheduledTaskStatus:()=>false,maybeAutoRun:()=>{}});
element('automation-goal').value='';ctx.render(ctx.snapshot);
assert.equal(element('create-automation-button').disabled,true);
sourceRow.children[5].events.click();
assert.equal(ctx.activeView,'automation');
assert.equal(element('create-automation-button').disabled,false);
ctx.busy=true;sourceRow.children[5].events.click();
assert.equal(element('create-automation-button').disabled,true);
ctx.busy=false;ctx.snapshot.modelConfigured=false;sourceRow.children[5].events.click();
assert.equal(element('create-automation-button').disabled,true);
console.log('研究转监控回归通过：预填后立即可创建；忙碌和模型未配置继续禁用。');
ctx.proxy.handler.listSavedResearch=async()=>{throw new Error('解密失败')};
await ctx.refreshSavedResearch();
assert.equal(element('saved-research-list').children.length,0);
assert.equal(element('saved-research-status').textContent,'researchStorageFailed');
console.log('研究保存界面回归通过：惰性来源、部分结果、正文变化、未知状态拒绝和读取失败清空旧列表。');

ctx.renderDownloadEvidence({downloadEvidence:[
 {name:'file_name',value:'yes'}, {name:'final_url',value:'https://fixture.example/<script>'},
 {name:'publisher',value:'not_verified'}, {name:'authorization',value:'secret'}]});
const downloadRows=element('download-evidence').children;
assert.equal(downloadRows.length,6);
assert.equal(downloadRows[1].textContent,'yes');
assert.equal(downloadRows[3].textContent,'https://fixture.example/<script>');
assert.equal(downloadRows[5].textContent,'downloadEvidenceUnknown');
assert.equal(element('download-evidence-card').hidden,false);
ctx.renderDownloadEvidence({downloadEvidence:[]});
assert.equal(element('download-evidence-card').hidden,true);
assert.equal(element('download-evidence').children.length,0);
console.log('下载证据界面回归通过：白名单、未核验身份、惰性文本、文件名与空态。');
