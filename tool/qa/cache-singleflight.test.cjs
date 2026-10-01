const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const ts=require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const ROOT=process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname,'../../entry/src/main/ets');
function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
function fixture(){
 const source=fs.readFileSync(path.join(ROOT,'services/cache/RemoteAssetCache.ets'),'utf8').replace(/\r\n/g,'\n');
 const a=source.indexOf('  private static async ensure('),b=source.indexOf('  /** 过期记录',a);assert.ok(a>=0&&b>a);
 const code=ts.transpileModule('class RemoteAssetCache {\n'+source.slice(a,b)+'\n}; return RemoteAssetCache;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
 const cache=new Function('VERIFIED_TTL_MS',code)(5000),reads=[],downloads=[],checks=[],requests=[];
 Object.assign(cache,{inFlight:new Map(),verifiedPaths:new Map(),localPath:(url,dir)=>'/cache/'+dir+'/'+url,
 scheduleRevalidate:(...args)=>checks.push(args),
 validateFile:(p)=>{const d=deferred();reads.push({path:p,...d});return d.promise;},
 remember:(p)=>{const uri='file://'+p;cache.verifiedPaths.set(p,{uri,at:Date.now()});return uri;},
 download:(url,p,dir,media)=>{downloads.push({url,path:p,dir,media});const d=deferred();requests.push(d);return d.promise.then(()=>cache.remember(p));}});
 return {cache,reads,downloads,checks,requests};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));const url='https://cdn/image';
test('asset: cold concurrent readers share validation and one download despite late disk miss',async()=>{
 const f=fixture(),a=f.cache.ensure(url,'thumb',false),b=f.cache.ensure(url,'thumb',false);
 f.reads[0].resolve(false);await tick();f.requests[0].resolve();const first=await a;
 // On the old implementation B owns a second slow disk check, finishing after A's download.
 if(f.reads[1])f.reads[1].resolve(false);await tick();if(f.requests[1])f.requests[1].resolve();const second=await b;
 assert.equal(first,second);assert.equal(f.reads.length,1);assert.equal(f.downloads.length,1);assert.equal(f.cache.inFlight.size,0);
});
test('asset: disk hit is shared and retained without downloads',async()=>{
 const f=fixture(),a=f.cache.ensure(url,'thumb',false),b=f.cache.ensure(url,'thumb',false);f.reads.forEach(r=>r.resolve(true));
 assert.equal(await a,await b);assert.equal(f.reads.length,1);assert.equal(f.downloads.length,0);assert.equal(f.cache.inFlight.size,0);
});
test('asset: shared failed download is released and a later call can retry',async()=>{
 const f=fixture(),a=f.cache.ensure(url,'thumb',false),b=f.cache.ensure(url,'thumb',false);const results=Promise.allSettled([a,b]);f.reads.forEach(r=>r.resolve(false));await tick();f.requests.forEach(r=>r.reject(new Error('network')));
 assert.ok((await results).every(r=>r.status==='rejected'));assert.equal(f.downloads.length,1);assert.equal(f.cache.inFlight.size,0);
 const retry=f.cache.ensure(url,'thumb',false);f.reads.at(-1).resolve(false);await tick();f.requests.at(-1).resolve();assert.match(await retry,/^file:/);assert.equal(f.cache.inFlight.size,0);
});
test('asset: failed disk validation cannot leave a permanent in-flight task',async()=>{
 const f=fixture(),a=f.cache.ensure(url,'thumb',false);f.reads[0].reject(new Error('disk'));await assert.rejects(a,/disk/);assert.equal(f.cache.inFlight.size,0);
 const retry=f.cache.ensure(url,'thumb',false);f.reads[1].resolve(true);assert.match(await retry,/^file:/);
});
for(const differentDirectory of [false,true])test(`asset: independent ${differentDirectory?'directories':'URLs'} remain concurrent`,async()=>{
 const f=fixture(),a=f.cache.ensure(url,'thumb',false),b=f.cache.ensure(differentDirectory?url:url+'2',differentDirectory?'emote':'thumb',false);
 assert.equal(f.reads.length,2);f.reads.forEach(r=>r.resolve(false));await tick();assert.equal(f.downloads.length,2);f.requests.forEach(r=>r.resolve());assert.notEqual(await a,await b);
});
test('asset: valid and expired memory hits retain zero IO and existing revalidation policy',async()=>{
 const f=fixture(),p=f.cache.localPath(url,'thumb');f.cache.verifiedPaths.set(p,{uri:'file://hit',at:Date.now()});assert.equal(await f.cache.ensure(url,'thumb',false),'file://hit');assert.equal(f.checks.length,0);
 f.cache.verifiedPaths.get(p).at-=6000;assert.equal(await f.cache.ensure(url,'thumb',false),'file://hit');assert.equal(f.checks.length,1);assert.equal(f.reads.length,0);assert.equal(f.downloads.length,0);
});
test('asset: local URIs bypass cache tasks',async()=>{const f=fixture();assert.equal(await f.cache.ensure('file://local','thumb',false),'file://local');assert.equal(f.reads.length,0);assert.equal(f.cache.inFlight.size,0);});
