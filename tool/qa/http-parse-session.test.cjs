const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const ts=require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const ROOT=process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname,'../../entry/src/main/ets');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
function fixture({large=true,transportError=null}={}){
 const modules=new Map(),storage=new Map(),parses=[],requests=[];let destroys=0;
 const mocks={
  '@kit.BasicServicesKit':{},
  '@kit.NetworkKit':{connection:{},http:{RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{STRING:0,ARRAY_BUFFER:1},createHttp:()=>({
   async request(url,options){requests.push({url,options});if(transportError)throw transportError;return {responseCode:200,result:JSON.stringify({owner:url.endsWith('/new')?'new':'old',pad:large?'x'.repeat(33000):''}),header:{'set-cookie':'SESSDATA=from-server'}};},
   destroy(){destroys++;}})}},
  '@kit.ArkTS':{taskpool:{execute(fn,body){const d=deferred();parses.push({...d,body});return d.promise;}}}
 };
 function load(name){if(modules.has(name))return modules.get(name);const filename=path.join(ROOT,name+'.ets'),module={exports:{}};
  const code=ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
  const requireLocal=n=>{if(n in mocks)return mocks[n];assert.ok(n.startsWith('.'),'unexpected external dependency '+n);return load(path.relative(ROOT,path.resolve(path.dirname(filename),n)).replaceAll('\\','/'));};
  new Function('require','module','exports','AppStorage','PersistentStorage','Concurrent',code)(requireLocal,module,module.exports,
   {get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},{persistProp(){}},target=>target);
  modules.set(name,module.exports);return module.exports;
 }
 const {HttpClient}=load('services/network/HttpClient'),{AuthSession}=load('services/auth/AuthSession');HttpClient.setCookie('buvid3','mock-device');
 function request(method,url='https://api.bilibili.com/old'){
  if(method==='get')return HttpClient.get(url);
  if(method==='post')return HttpClient.post(url,'mock=1');
  return HttpClient.postBinary(url,'application/octet-stream',new ArrayBuffer(0));
 }
 function finishParse(index,failure=false){const p=parses[index];assert.ok(p,'expected taskpool parse');if(failure)p.reject(new Error('mock taskpool failure'));else p.resolve(JSON.parse(p.body));}
 return {HttpClient,AuthSession,request,parses,requests,finishParse,destroys:()=>destroys};
}
for(const method of ['get','post','postBinary']){
 for(const failedParse of [false,true])test(`HTTP ${method}: generation changed during ${failedParse?'failed':'successful'} background parse invalidates old response`,async()=>{
  const f=fixture(),old=f.request(method);await tick();assert.equal(f.parses.length,1);f.AuthSession.advance();f.HttpClient.setCookie('SESSDATA','new-account');f.finishParse(0,failedParse);const resp=await old;
  assert.equal(resp.status,-1);assert.equal(resp.body,'');assert.deepEqual(resp.json(),{});assert.equal(f.HttpClient.getCookie('SESSDATA'),'new-account');assert.equal(f.destroys(),1);
 });
 for(const failedParse of [false,true])test(`HTTP ${method}: unchanged session preserves ${failedParse?'fallback':'parsed'} response`,async()=>{
  const f=fixture(),request=f.request(method);await tick();f.finishParse(0,failedParse);const resp=await request;assert.equal(resp.status,200);assert.equal(resp.json().owner,'old');assert.equal(f.destroys(),1);
 });
 for(const failedParse of [false,true])test(`HTTP ${method}: external public ${failedParse?'fallback':'parsed'} response survives account generation change`,async()=>{
  const f=fixture(),request=f.request(method,'https://example.com/old');await tick();f.AuthSession.advance();f.finishParse(0,failedParse);const resp=await request;
  assert.equal(resp.status,200);assert.equal(resp.json().owner,'old');assert.equal(f.requests[0].options.header.Cookie,undefined);assert.equal(f.HttpClient.getCookie('SESSDATA'),'');
 });
}
test('HTTP: inverse old/new parse completion keeps new response and cookies authoritative',async()=>{
 const f=fixture(),old=f.request('get');await tick();f.AuthSession.advance();f.HttpClient.setCookie('SESSDATA','new-account');const next=f.request('get','https://api.bilibili.com/new');await tick();f.finishParse(1);assert.equal((await next).json().owner,'new');
 f.HttpClient.setCookie('SESSDATA','new-account');f.finishParse(0);assert.equal((await old).status,-1);assert.equal(f.HttpClient.getCookie('SESSDATA'),'new-account');assert.equal(f.destroys(),2);
});
test('HTTP: same-session concurrent parse completion remains independent',async()=>{
 const f=fixture(),a=f.request('get'),b=f.request('get','https://api.bilibili.com/new');await tick();f.finishParse(1);assert.equal((await b).json().owner,'new');f.finishParse(0);assert.equal((await a).json().owner,'old');
});
test('HTTP: platform rejection returns transport failure without parsing and releases request',async()=>{
 const f=fixture({transportError:{code:901,message:'mock cancellation'}});const resp=await f.request('get');assert.equal(resp.status,-1);assert.equal(resp.transportCode,901);assert.equal(f.parses.length,0);assert.equal(f.destroys(),1);
});
test('HTTP: small responses preserve the existing synchronous parse path',async()=>{
 const f=fixture({large:false});const resp=await f.request('get');assert.equal(resp.json().owner,'old');assert.equal(f.parses.length,0);assert.equal(f.destroys(),1);
});
