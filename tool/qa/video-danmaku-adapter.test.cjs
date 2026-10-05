const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {createArktsLoader, deferred} = require('./arkts-module.cjs');

// Only translate the native page field/adapter; its actual submission controller runs whole.
function fixture() {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'pages/VideoDetail.ets'), 'utf8');
  function section(start, end) {
    const begin = source.indexOf(start), finish = source.indexOf(end, begin);
    assert.ok(begin >= 0 && finish > begin, start); return source.slice(begin, finish);
  }
  const pending = [], notices = [];
  const load = createArktsLoader({mocks: {'api/BiliApi': {BiliApi: {sendDanmaku(...args) {
    const request = deferred(); pending.push({args, ...request}); return request.promise;
  }}}}});
  const code = ts.transpileModule('class Page {\n' +
    section('  private danmakuSubmit:', '  private playback:') +
    section('  private updateDanmakuDraft(', '  private danmakuComposerWidth():') + '\n}; return Page;',
    {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const Page = new Function('VideoDanmakuSubmissionController', code)(
    load('components/video/VideoDanmakuSubmissionController').VideoDanmakuSubmissionController);
  const page = Object.assign(new Page(), {destroyed: false, closing: false, danmakuDraftVersion: 0,
    detail: {aid: 170001, bvid: 'BV17x411w7KC'},
    currentCid: 279786, playerSourceVersion: 1, videoProgressSeconds: 12.375, danmakuDraft: '发送回显',
    danmakuSending: false, danmakuOn: false, localDanmakuText: '', localDanmakuId: '', localDanmakuSeconds: 0,
    localDanmakuToken: 0, ensureLogin: () => true, toast: text => notices.push(text)});
  return {page, pending, notices};
}

test('real video page send publishes all local event props and enables danmaku before its token changes', async () => {
  const f = fixture(), sending = f.page.sendVideoDanmaku();
  assert.equal(f.page.danmakuSending, true);
  f.page.videoProgressSeconds = 14;
  f.pending[0].resolve({ok: true, data: {dmid_str: '1234567890123456789'}}); await sending;
  assert.deepEqual([f.page.localDanmakuText, f.page.localDanmakuSeconds, f.page.localDanmakuId,
    f.page.localDanmakuToken, f.page.danmakuOn, f.page.danmakuSending],
  ['发送回显', 12.375, '1234567890123456789', 1, true, false]);
});

test('real video page preserves next draft and rejects a prior part send completion', async () => {
  const f = fixture(), old = f.page.sendVideoDanmaku();
  f.page.currentCid++; f.page.danmakuDraft = '新的分P'; const fresh = f.page.sendVideoDanmaku();
  f.pending[0].resolve({ok: true, data: {}}); await old;
  assert.equal(f.page.localDanmakuToken, 0); assert.equal(f.page.danmakuSending, true);
  f.page.danmakuDraft = '下一条'; f.pending[1].resolve({ok: true, data: {}}); await fresh;
  assert.equal(f.page.localDanmakuToken, 1); assert.equal(f.page.localDanmakuText, '新的分P');
  assert.equal(f.page.danmakuDraft, '下一条'); assert.equal(f.page.danmakuSending, false);
});

test('real video page rejects completion during its closing animation before disposal', async () => {
  const f = fixture(), sending = f.page.sendVideoDanmaku(); f.page.closing = true;
  f.pending[0].resolve({ok: true, data: {}}); await sending;
  assert.equal(f.page.localDanmakuToken, 0); assert.equal(f.page.danmakuDraft, '发送回显');
  assert.deepEqual(f.notices, []);
});

test('real video page input revision preserves a newly typed identical draft', async () => {
  const f = fixture(), sending = f.page.sendVideoDanmaku();
  f.page.updateDanmakuDraft('别的内容'); f.page.updateDanmakuDraft('发送回显');
  f.pending[0].resolve({ok: true, data: {}}); await sending;
  assert.equal(f.page.danmakuDraft, '发送回显'); assert.equal(f.page.localDanmakuToken, 1);
});
