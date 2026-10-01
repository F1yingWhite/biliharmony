const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const ROOT = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const ANCHORS = [
 ['  async onSourceVersionChanged():', '  onExternalDanmakuChanged():'],
 ['  private invalidatePlayerCreation():', '  private tryStartPreparedPlayers():'],
 ['  async handlePlayerError(', '  togglePlay():'],
];
function deferred() {let resolve, reject; const promise = new Promise((yes, no) => {resolve = yes; reject = no;}); return {promise, resolve, reject};}
function fixture() {
 const source = fs.readFileSync(path.join(ROOT, 'components/player/PlayerView.ets'), 'utf8').replace(/\r\n/g, '\n');
 const methods = ANCHORS.map(([a,b]) => {const begin = source.indexOf(a), end = source.indexOf(b, begin); assert.ok(begin >= 0 && end > begin); return source.slice(begin, end);}).join('\n');
 const code = ts.transpileModule('class Harness {\n'+methods+'\n}; return Harness;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
 const Harness = new Function(code)(); const view = new Harness(); let epoch = 0; const creations = [], releases = [];
 function player(id, pending = null) {return {id, release() {releases.push(id); return pending?.promise || Promise.resolve();}};}
 const release = deferred(), video = player('old-video', release), audio = player('old-audio');
 Object.assign(view, {destroyed:false, playerCreateGeneration:0, playerCreating:false, player:video, audioPlayer:audio,
 retryingSource:false, sourceIndex:0, audioSourceIndex:0, runtimeSources:['old-main','old-backup'],runtimeAudioSources:['old-audio','old-audio-backup'],
 videoUrls:['new-main','new-backup'],videoUrl:'',audioUrls:['new-audio','new-audio-backup'],qualityOptions:[],currentQuality:80,
 playheadSec:10, playing:true, seekRecoveryAttempts:0, seekCtl:{cancel(){},seekResumePlaying:true},
 sourceRequests:{next:()=>++epoch,isCurrent:n=>n===epoch},
 sourceCount(){return this.runtimeSources.length;},releaseSeekPreview(){},cancelAudioGate(){},cancelFirstFrameMute(){},loadDanmaku(){},armDeferredLoads(){},
 sponsorCtl:{invalidateForSourceChange(){}},dmClock:{stop(){}},dmEngine:{list:[],cursor:0},seekTargetCtl:{show(){}},
 onPlayingChange(){},canStartPlayback:()=>true,
 async initPlayer(){if(this.destroyed || this.player !== null || this.playerCreating) return;creations.push({sourceIndex:this.sourceIndex,audioSourceIndex:this.audioSourceIndex});this.playerCreateGeneration++;this.player=player('new-video-'+creations.length);this.audioPlayer=player('new-audio-'+creations.length);},
 release(){this.invalidatePlayerCreation();this.player=null;this.audioPlayer=null;}});
 return {view,video,audio,release,creations,releases,player};
}
function recover(f, kind) {
 if(kind==='video')return f.view.handlePlayerError(f.video,'CDN failed');
 if(kind==='audio'){f.audio.release=()=>{f.releases.push('old-audio');return f.release.promise;}; f.video.release=()=>{f.releases.push('old-video');return Promise.resolve();};return f.view.handleAudioPlayerError(f.audio,'audio failed');}
 throw new Error('unknown recovery kind');
}
for(const kind of ['video','audio']) {
 test(`player ${kind} recovery: switching video during release keeps the new primary source`,async()=>{
  const f=fixture(),old=recover(f,kind);await f.view.onSourceVersionChanged();f.release.resolve();await old;
  assert.equal(f.view.sourceIndex,0);assert.equal(f.view.audioSourceIndex,0);assert.equal(f.creations.length,1);assert.equal(f.view.retryingSource,false);
  assert.deepEqual(new Set(f.releases),new Set(['old-video','old-audio']));
 });
 test(`player ${kind} recovery: leaving while release waits never rebuilds`,async()=>{
  const f=fixture(),old=recover(f,kind);f.view.destroyed=true;f.view.release();f.release.resolve();await old;assert.deepEqual(f.creations,[]);
 });
 test(`player ${kind} recovery: normal recovery still rebuilds the intended source`,async()=>{
  const f=fixture(),old=recover(f,kind);f.release.resolve();await old;
  assert.equal(f.creations.length,1);assert.equal(f.view.sourceIndex,kind==='video'?1:0);assert.equal(f.view.audioSourceIndex,kind==='audio'?1:0);assert.equal(f.view.retryingSource,false);
 });
}
test('player: source switch releases a previous retry lock before new player errors',async()=>{
 const f=fixture(),old=recover(f,'video');await f.view.onSourceVersionChanged();assert.equal(f.view.retryingSource,false);
 f.release.resolve();await old;
});
test('player: old retry completion cannot release the lock or advance indexes of a newer retry',async()=>{
 const f=fixture(),old=recover(f,'video');await f.view.onSourceVersionChanged();
 const nextRelease=deferred(),newPlayer=f.view.player;newPlayer.release=()=>nextRelease.promise;
 const next=f.view.handlePlayerError(newPlayer,'new CDN failed');assert.equal(f.view.retryingSource,true);assert.equal(f.view.player,null);
 f.release.resolve();await old;assert.equal(f.view.retryingSource,true);assert.equal(f.view.sourceIndex,0);assert.equal(f.creations.length,1);
 nextRelease.resolve();await next;assert.equal(f.view.sourceIndex,1);assert.equal(f.view.retryingSource,false);assert.equal(f.creations.length,2);
});
