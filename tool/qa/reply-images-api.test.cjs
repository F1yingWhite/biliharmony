const test = require('node:test');
const assert = require('node:assert/strict');
const {environment} = require('./dynamic-test-env.cjs');

// Load Controller → CommentApi → DynamicApi → MultipartBody → ApiCommon unchanged.
// Replace filesystem/image preparation and HTTP; unused emote/WBI module boundaries are inert.
function fixture(options = {}) {
  const binary = [], posts = [], cleaned = [], accepted = [];
  let images = [], draft = '  附图评论  ';
  const uploadJson = options.uploadJson || {code: 0, data: {
    image_url: 'https://i0.hdslb.com/bfs/new_dyn/a.jpg', image_width: 640, image_height: 480, img_size: 12.25,
  }};
  const response = json => ({ok: true, status: 200, body: JSON.stringify(json), json: () => json});
  const env = environment({
    'services/network/HttpClient': {RequestPriority: {HIGH: 1}, HttpClient: {
      getCookie: key => options.noCsrf && key === 'bili_jct' ? '' : (key === 'bili_jct' ? 'csrf-test' : 'session-test'),
      buildQuery: params => new URLSearchParams(params).toString(),
      async postBinary(url, contentType, body) {binary.push({url, contentType, body}); return response(uploadJson);},
      async post(url, body) {posts.push({url, params: Object.fromEntries(new URLSearchParams(body))});
        return response({code: options.replyCode || 0, message: '评论失败', data: {rpid: 901}});},
    }},
    'common/WbiSign': {WbiSign: {}},
    'common/EmotePackageCache': {EmotePackageCache: {}},
    'common/CommentLog': {CommentLog: {nextRequestId: () => 1, elapsed: () => 0, errorText: String,
      info() {}, warn() {}, error() {}}},
    'services/auth/CookieRefresher': {CookieRefresher: {onAuthFailure() {}}},
    'services/auth/UserStore': {UserStore: {isLogin: true, current: {mid: 7, uname: '我', face: '', level: 1}}},
    'model/Models': {},
    'BuildProfile': {DEBUG: false}, '@kit.PerformanceAnalysisKit': {hilog: {info() {}}},
    'common/DynImagePreparer': {DynImagePreparer: {
      prepare: async (_context, uri) => ({key: uri, cachePath: uri, fileName: 'photo.jpg', mimeType: 'image/jpeg'}),
      readBytes: async () => new Uint8Array([0, 255, 10, 128]).buffer,
      cleanup: items => cleaned.push(...items.map(image => image.key)),
    }},
  });
  const api = env.load('api/CommentApi').CommentApi;
  const {ReplySubmissionController} = env.load('components/reply/ReplySubmissionController');
  const controller = new ReplySubmissionController({isAlive: () => true,
    getTarget: () => ({oid: 100, type: 1, root: 0, parent: 0, scope: 'main', active: true}),
    getDraft: () => draft, setSending() {}, setImages: items => images = items, toast() {},
    onSuccess: (_snapshot, reply, clearDraft) => {accepted.push(reply); if (clearDraft) draft = '';},
  });
  return {api, controller, binary, posts, cleaned, accepted, images: () => images, draft: () => draft};
}

test('reply image full chain uses the official multipart fields and pictures JSON, retaining fractional img_size', async () => {
  const f = fixture(); await f.controller.pick({}, async () => ['a']); await f.controller.send();
  assert.equal(f.binary.length, 1); const upload = f.binary[0];
  assert.equal(upload.url, 'https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs');
  assert.match(upload.contentType, /^multipart\/form-data; boundary=BiliHarmonyForm/);
  const body = Buffer.from(upload.body), text = body.toString('latin1');
  for (const [name, value] of [['category', 'daily'], ['biz', 'new_dyn'], ['csrf', 'csrf-test']]) {
    assert.ok(text.includes('name="' + name + '"\r\n\r\n' + value + '\r\n'));
  }
  assert.ok(text.includes('name="file_up"; filename="photo.jpg"\r\nContent-Type: image/jpeg'));
  assert.ok(body.includes(Buffer.from([0, 255, 10, 128])), 'binary bytes must not pass through text encoding');
  assert.equal(f.posts.length, 1); assert.equal(f.posts[0].url, 'https://api.bilibili.com/x/v2/reply/add');
  assert.deepEqual(f.posts[0].params, {oid: '100', type: '1', message: '附图评论', plat: '1', csrf: 'csrf-test',
    pictures: JSON.stringify([{img_src: 'https://i0.hdslb.com/bfs/new_dyn/a.jpg', img_width: 640,
      img_height: 480, img_size: 12.25}])});
  assert.equal(f.draft(), ''); assert.deepEqual(f.images(), []); assert.deepEqual(f.cleaned, ['a']);
  assert.deepEqual(f.accepted[0].pictures, ['https://i0.hdslb.com/bfs/new_dyn/a.jpg']);
});

for (const options of [
  {uploadJson: {code: -400, message: '图片不合规'}},
  {uploadJson: {code: 0, data: {image_url: 'https://image', image_width: 0, image_height: 480}}},
  {noCsrf: true},
]) {
  test('reply image full chain retains draft and sends no reply after rejected upload: ' + JSON.stringify(options), async () => {
    const f = fixture(options); await f.controller.pick({}, async () => ['a']); await f.controller.send();
    assert.deepEqual(f.posts, []); assert.equal(f.images().length, 1); assert.equal(f.draft(), '  附图评论  ');
    assert.deepEqual(f.cleaned, []); assert.deepEqual(f.accepted, []);
  });
}

test('reply image full chain preserves draft when the final reply business response rejects the write', async () => {
  const f = fixture({replyCode: -400}); await f.controller.pick({}, async () => ['a']); await f.controller.send();
  assert.equal(f.binary.length, 1); assert.equal(f.posts.length, 1); assert.equal(f.images().length, 1);
  assert.equal(f.draft(), '  附图评论  '); assert.deepEqual(f.cleaned, []); assert.deepEqual(f.accepted, []);
});

test('reply API text-only callers retain their original form and attachment maximum rejects before transport', async () => {
  const f = fixture(); await f.api.addReply(100, 1, '文字', 20, 21);
  assert.deepEqual(f.posts[0].params, {oid: '100', type: '1', message: '文字', plat: '1', root: '20', parent: '21', csrf: 'csrf-test'});
  const result = await f.api.addReply(100, 1, '文字', 0, 0, Array.from({length: 10}, () => ({url: 'x', width: 1, height: 1, size: 1})));
  assert.equal(result.ok, false); assert.equal(f.posts.length, 1);
});
