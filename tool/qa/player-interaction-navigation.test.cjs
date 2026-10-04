const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

// Extract only the native page adapter; execute its real route and rotation flow.
function fixture() {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'pages/VideoDetail.ets'), 'utf8');
  const begin = source.indexOf('  private openInteractionVideo(');
  const end = source.indexOf('  private onPlayerEnded()', begin);
  assert.ok(begin >= 0 && end > begin, 'production interaction/navigation adapters are present');
  const code = ts.transpileModule('class Page {\n' + source.slice(begin, end) + '\n}; return Page;',
    {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const effects = [];
  const Page = new Function('PlayerCommandBus', 'AppNavStack', 'NAV_VIDEO_DETAIL', code)(
    {stop: () => effects.push(['stop']), exitFullscreen: () => effects.push(['rotate'])},
    {pushPathByName: (name, param) => effects.push(['push', name, param]),
      replacePathByName: (name, param) => effects.push(['replace', name, param])}, 'video');
  const page = Object.assign(new Page(), {destroyed: false, playerFullscreen: false,
    pendingVideoNavigation: null, pendingVideoReplace: false});
  return {page, effects};
}

test('UP link click opens the exact ordinary video and retains the current page for return', () => {
  const f = fixture();
  const target = {aid: 170001, bvid: 'BV17x411w7KC', epId: 0, title: '链接视频', cover: 'https://i0.hdslb.com/example.jpg'};
  f.page.openInteractionVideo(target);
  assert.deepEqual(f.effects.find(item => item[0] === 'push'), ['push', 'video', target]);
  assert.ok(f.effects.some(item => item[0] === 'stop'));
  assert.equal(f.effects.some(item => item[0] === 'replace'), false);
});

test('UP episode link preserves the episode identity even when aid/bvid are absent', () => {
  const f = fixture(), target = {aid: 0, bvid: '', epId: 123456, title: '剧集', cover: ''};
  f.page.openInteractionVideo(target);
  assert.deepEqual(f.effects.find(item => item[0] === 'push'), ['push', 'video', target]);
  f.page.openInteractionVideo({aid: 0, bvid: '', epId: 0, title: '无效', cover: ''});
  assert.equal(f.effects.filter(item => item[0] === 'push').length, 1);
});

test('fullscreen UP link waits for portrait rotation before opening the target page', () => {
  const f = fixture(); f.page.playerFullscreen = true;
  const target = {aid: 42, bvid: 'BV1test', epId: 0, title: '目标', cover: ''};
  f.page.openInteractionVideo(target);
  assert.ok(f.effects.some(item => item[0] === 'rotate'));
  assert.equal(f.effects.some(item => item[0] === 'push'), false);
  f.page.playerFullscreen = false; f.page.flushPendingVideoNavigation();
  assert.deepEqual(f.effects.find(item => item[0] === 'push'), ['push', 'video', target]);
  assert.equal(f.page.pendingVideoNavigation, null);
  f.page.flushPendingVideoNavigation();
  assert.equal(f.effects.filter(item => item[0] === 'push').length, 1);
});

test('destroyed source page cannot complete a delayed interaction navigation', () => {
  const f = fixture(); f.page.playerFullscreen = true;
  f.page.openInteractionVideo({aid: 42, bvid: '', epId: 0, title: '', cover: ''});
  f.page.destroyed = true; f.page.flushPendingVideoNavigation();
  assert.equal(f.effects.some(item => item[0] === 'push'), false);
});
