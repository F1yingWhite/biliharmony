const test = require('node:test');
const assert = require('node:assert/strict');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');
const {deferred, tick} = require('./arkts-module.cjs');

function fixture({kind = 'dynamic', login = true, metadataSelected = []} = {}) {
  const reads = [], writes = [], notices = [], navigation = [], user = {isLogin: login, current: login ? {mid: 42} : null};
  const ui = createNativeComponent('components/reply/ReplyVotePanel', {mocks: {
    'services/auth/UserStore': {UserStore: user},
    'api/ReplyVoteApi': {ReplyVoteApi: {
      load(card) {const gate = deferred(); reads.push({card, ...gate}); return gate.promise;},
      submit(source, card, ids) {const gate = deferred(); writes.push({source, card, ids, ...gate}); return gate.promise;},
    }},
    'common/AppRouter': {NAV_LOGIN: 'Login', AppNavStack: {pushPathByName: (...args) => navigation.push(args)}},
  }});
  const models = ui.load('model/reply/ReplyVoteModels');
  const source = (rpid = 112) => Object.assign(new models.ReplyVoteSource(),
    {oid: 170001, type: 1, rpid, sourceKey: 'reply:170001:1:' + rpid});
  const detail = ({id = '11936440', maxSelect = 1, selectedIds = [], counts = [2, 6],
    ended = false, deleted = false, image = false, long = false, publisherMid = 0} = {}) => {
    const card = Object.assign(new models.ReplyVoteCard(), {id, kind, title: '评论区投票题目',
      count: 4, maxSelect, selectedIds, ended, deleted, publisherMid, loaded: true, endTime: Math.floor(Date.now() / 1000) + 3600});
    card.options = counts.map((count, index) => Object.assign(new models.ReplyVoteOption(), {
      id: [2, 9, 17, 22][index], text: long ? '可以完整换行显示的很长选项文本'.repeat(12) : '答案' + (index + 1),
      count, imageUrl: image && index === 0 ? 'https://i0.hdslb.com/bfs/vote/image.jpg' : '',
    }));
    return card;
  };
  const metadata = (id = '11936440') => Object.assign(new models.ReplyVoteCard(),
    {id, kind, title: '评论区投票题目', count: 4, selectedIds: metadataSelected});
  Object.assign(ui.component, {source: source(), vote: metadata(),
    getUIContext: () => ({getPromptAction: () => ({showToast: ({message}) => notices.push(message)})})});
  ui.component.aboutToAppear();
  const build = () => ui.build();
  const button = label => ui.nodes.find(node => node.type === 'Button' && node.props.accessibilityText === label);
  const ready = async value => {reads.at(-1).resolve(value || detail()); await tick(); build();};
  return {...ui, reads, writes, notices, navigation, user, models, source, detail, metadata, build, button, ready,
    auth: ui.load('services/auth/AuthSession').AuthSession};
}

function cardFixture() {
  const ui = createNativeComponent('components/reply/ReplyCard', {
    recordComponents: {
      'components/UserDecorations': ['DecoratedAvatar', 'UserDecorationBanner'],
      'components/reply/ReplyActionBar': ['ReplyActionBar'],
      'components/reply/ReplyRichText': ['ReplyRichText'],
      'components/reply/ReplyPreview': ['ReplyPreview'],
      'components/reply/ReplyThreadGuides': ['ReplyThreadGuides'],
      'components/reply/ReplyVotePanel': ['ReplyVotePanel'],
    }, mocks: {
      'common/AppTheme': {AppTheme: {}}, 'common/AppRouter': {}, 'common/PlayerCommandBus': {},
      'common/Haptic': {}, '@kit.ArkUI': {}, '@kit.BasicServicesKit': {}, '@kit.AbilityKit': {},
      'api/UserApi': {}, 'services/auth/UserStore': {}, 'api/CommentApi': {},
      'services/cache/RemoteAssetCache': {RemoteAssetCache: {cachedDecoration: url => url}},
      'components/reply/ReplyLinkController': {ReplyLinkController: class {dispose() {}}},
    }, globals: {TapGesture: () => ({onAction() {return this;}})},
  });
  const {ReplyItem} = ui.load('model/Models');
  const reply = (rpid = 112, voteId = 11936440) => ReplyItem.from({rpid, oid: 170001, type: 1,
    content: {message: '请参与本评论的投票', vote: voteId ? {id: voteId, title: '大家选哪个', cnt: 123} : null}});
  ui.component.item = reply(); ui.component.aboutToAppear();
  return {...ui, reply};
}

test('the real shared comment card builds its parsed vote between rich text and actions in main and thread layouts', () => {
  const f = cardFixture();
  for (const depth of [0, 1, 3]) {
    f.component.threadDepth = depth; f.build();
    const panel = f.nodes.find(node => node.type === 'ReplyVotePanel');
    assert.ok(panel, 'content.vote must render inline, not be relegated to a link');
    assert.equal(panel.args[0].vote.id, '11936440'); assert.equal(panel.args[0].vote.count, 123);
    assert.deepEqual({...panel.args[0].source}, {oid: 170001, type: 1, rpid: 112, sourceKey: 'reply:170001:1:112'});
    assert.equal(panel.props.width, '100%');
    assert.ok(f.nodes.indexOf(panel) > f.nodes.findIndex(node => node.type === 'ReplyRichText'));
    assert.ok(f.nodes.indexOf(panel) < f.nodes.findIndex(node => node.type === 'ReplyActionBar'));
    let navigated = false; panel.args[0].onNavigate(() => navigated = true); assert.equal(navigated, true);
  }
});

test('comment-card reuse reads fresh hook params before Prop updates and removes a missing attachment', () => {
  const f = cardFixture(); f.build();
  const next = f.reply(221, 15591912); f.component.aboutToReuse({item: next}); f.build();
  const panel = f.nodes.find(node => node.type === 'ReplyVotePanel');
  assert.equal(panel.args[0].vote.id, '15591912'); assert.equal(panel.args[0].source.rpid, 221);
  f.component.item = next; f.component.onItemChanged(); f.build();
  assert.equal(f.nodes.find(node => node.type === 'ReplyVotePanel').args[0].vote.id, '15591912');
  f.component.aboutToReuse({item: f.reply(332, 0)}); f.build();
  assert.equal(f.nodes.some(node => node.type === 'ReplyVotePanel'), false);
});

test('single-choice real buttons replace selection, submit exact IDs once, and rebuild confirmed ratio bars in place', async () => {
  const f = fixture({kind: 'reply'}); f.build(); assert.ok(f.nodes.some(node => node.type === 'LoadingProgress'));
  assert.equal(f.nodes.some(node => node.type === 'Progress'), false); await f.ready();
  f.button('评论投票选项2').props.onClick(); f.build();
  f.button('评论投票选项9').props.onClick(); f.build();
  assert.deepEqual(f.component.voteState.selectedOptionIds, [9]);
  const draftKeys = f.loops[0].keys.slice();
  const submit = f.button('提交评论投票'); assert.equal(submit.props.enabled, true); submit.props.onClick(); submit.props.onClick();
  assert.equal(f.writes.length, 1); assert.deepEqual(f.writes[0].ids, [9]);
  assert.equal(f.writes[0].card.kind, 'reply'); assert.equal(f.writes[0].source.rpid, 112);
  f.writes[0].resolve(new f.models.ReplyVoteResult(true, '', 0, f.detail({selectedIds: [9], counts: [2, 7]})));
  await tick(); f.build();
  assert.ok(f.loops[0].keys.every((key, index) => key !== draftKeys[index]),
    'stable option IDs must rebuild native ForEach snapshots when confirmation/results change');
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [22, 78]);
  assert.equal(f.button('评论投票选项9').props.enabled, false); assert.equal(f.button('提交评论投票'), undefined);
  const confirmedKeys = f.loops[0].keys.slice();
  f.component.vote = f.metadata(); f.component.onVoteSourceChanged(); f.build();
  assert.deepEqual(f.loops[0].keys, confirmedKeys, 'same-card old metadata must preserve confirmed native identities');
  assert.deepEqual(f.component.voteState.detail.selectedIds, [9], 'old same-card metadata must not revert confirmation');
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [22, 78]);
});

test('retained production Card and Option builder arguments read loaded, replaced and confirmed details without a fresh outer build', async () => {
  const f = fixture({kind: 'reply'});
  // Native @Builder observers retain the initial argument closures. Replaying
  // those exact arguments catches snapshots that a full build() conceals; this
  // remains a builder contract check, not a replacement for native VM coverage.
  f.component.vote = f.detail({counts: [108, 0]}); f.component.vote.loaded = false;
  let cardArgs, optionArgs;
  const cardBuilder = f.component.Card, optionBuilder = f.component.Option;
  f.component.Card = function (...args) {cardArgs ??= args; return cardBuilder.apply(this, args);};
  f.component.Option = function (...args) {optionArgs ??= args; return optionBuilder.apply(this, args);};
  f.build();
  assert.ok(cardArgs && optionArgs, 'capture actual production builder invocations from the metadata render');
  f.component.Card = cardBuilder; f.component.Option = optionBuilder;
  assert.equal(f.button('评论投票选项2').props.enabled, false);

  const loaded = f.detail({counts: [3, 1]}); loaded.title = '服务器加载的投票';
  loaded.options[0].text = '详情里的第一答案';
  f.reads[0].resolve(loaded); await tick();
  f.render(() => cardBuilder.apply(f.component, cardArgs));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === loaded.title));
  assert.equal(f.button('评论投票选项2').props.enabled, true);
  assert.equal(f.button('重新加载评论投票'), undefined);
  assert.ok(f.button('提交评论投票'));

  f.button('评论投票选项9').props.onClick();
  f.render(() => cardBuilder.apply(f.component, cardArgs));
  f.button('提交评论投票').props.onClick();
  f.writes[0].resolve(new f.models.ReplyVoteResult(true, '', 0,
    f.detail({selectedIds: [9], counts: [2, 8]})));
  await tick();
  f.render(() => cardBuilder.apply(f.component, cardArgs));
  assert.equal(f.button('提交评论投票'), undefined);
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [20, 80]);

  const refreshed = f.detail({selectedIds: [9], counts: [4, 6], image: true});
  refreshed.options[0].text = '刷新后的第一答案';
  f.button('查看评论投票结果').props.onClick();
  f.reads.at(-1).resolve(refreshed); await tick();
  f.render(() => optionBuilder.apply(f.component, optionArgs));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === refreshed.options[0].text));
  assert.ok(f.nodes.some(node => node.type === 'Image' && node.args[0] === refreshed.options[0].imageUrl));
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [40]);
  assert.equal(f.button('评论投票选项2').props.enabled, false);
});

test('multi-choice controls enforce the real selection limit and show ratios over choices, not participant count', async () => {
  const f = fixture(); await f.ready(f.detail({maxSelect: 2, counts: [5, 3, 2]}));
  for (const id of [2, 9, 17]) {f.button('评论投票选项' + id).props.onClick(); f.build();}
  assert.deepEqual(f.component.voteState.selectedOptionIds, [2, 9]);
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '最多选择 2 项'));
  f.button('提交评论投票').props.onClick(); assert.deepEqual(f.writes[0].ids, [2, 9]);
  f.writes[0].resolve(new f.models.ReplyVoteResult(true, '', 0, f.detail({maxSelect: 2, selectedIds: [2, 9], counts: [5, 3, 2]})));
  await tick(); f.build();
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [50, 30, 20]);
});

test('view and refresh use only real reads, and logged-out users get the existing login navigation', async () => {
  const f = fixture({login: false}); await f.ready();
  assert.equal(f.button('提交评论投票'), undefined);
  f.button('登录参与评论投票').props.onClick(); assert.deepEqual(f.navigation, [['Login', null]]);
  f.button('查看评论投票结果').props.onClick(); await tick(); f.build();
  assert.equal(f.writes.length, 0); assert.equal(f.nodes.filter(node => node.type === 'Progress').length, 2);
  const count = f.reads.length; f.button('查看评论投票结果').props.onClick();
  assert.equal(f.reads.length, count + 1, 'refresh must not merely redisplay a cached count');
  f.reads.at(-1).resolve(f.detail({counts: [4, 4]})); await tick(); f.build();
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [50, 50]);
  assert.equal(f.writes.length, 0);
});

test('load and submission errors keep retryable choices while accepted writes never offer a second submit', async () => {
  const f = fixture(); f.reads[0].reject(Error('offline')); await tick(); f.build();
  assert.ok(f.button('重新加载评论投票')); assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0].includes('加载失败')));
  f.button('重新加载评论投票').props.onClick(); await f.ready();
  f.button('评论投票选项9').props.onClick(); f.build(); f.button('提交评论投票').props.onClick();
  f.writes[0].resolve(new f.models.ReplyVoteResult(false, '投票提交失败')); await tick(); f.build();
  assert.deepEqual(f.component.voteState.selectedOptionIds, [9]); assert.equal(f.nodes.some(node => node.type === 'Progress'), false);
  f.button('提交评论投票').props.onClick(); f.writes[1].resolve(new f.models.ReplyVoteResult(true, '', 0, null));
  await tick(); f.build(); assert.equal(f.button('提交评论投票'), undefined);
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0].includes('已投票，结果刷新失败')));
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [25, 75],
    'failed refresh must retain real old counts without inventing a local increment');
  f.button('查看评论投票结果').props.onClick(); assert.equal(f.reads.length, 3); assert.equal(f.writes.length, 2);
});

test('ended and already-voted zero-count polls show finite bars, while deleted polls have no actionable choices', async () => {
  for (const value of [{ended: true}, {selectedIds: [9]}]) {
    const f = fixture(); await f.ready(f.detail({...value, counts: [0, 0]}));
    assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [0, 0]);
    assert.equal(f.button('提交评论投票'), undefined); assert.equal(f.button('评论投票选项2').props.enabled, false);
    f.button('评论投票选项2').props.onClick(); assert.deepEqual(f.component.voteState.selectedOptionIds, value.selectedIds || []);
  }
  const f = fixture(); await f.ready(f.detail({deleted: true}));
  assert.equal(f.button('评论投票选项2'), undefined); assert.equal(f.button('查看评论投票结果'), undefined);
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '投票已失效'));
});

test('the publisher sees real results and an owner label without a fabricated voted selection or submit button', async () => {
  const f = fixture(); await f.ready(f.detail({publisherMid: 42}));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '你发布的投票'));
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [25, 75]);
  assert.deepEqual(f.component.voteState.detail.selectedIds, []);
  assert.equal(f.button('提交评论投票'), undefined); assert.equal(f.button('评论投票选项2').props.enabled, false);
  f.button('评论投票选项2').props.onClick(); assert.deepEqual(f.component.voteState.selectedOptionIds, []);
  assert.equal(f.writes.length, 0);
});

test('Panel recycle/reuse and delayed Prop/account watchers cannot paint an old vote or selected account', async () => {
  const f = fixture({metadataSelected: [2]}); f.build();
  assert.equal(f.nodes.some(node => node.type === 'Progress'), false, 'metadata selectedIds are not a current-account detail');
  f.component.aboutToRecycle();
  f.component.aboutToReuse({source: {...f.source(221)}, vote: f.metadata('15591912')});
  f.reads[0].resolve(f.detail({selectedIds: [2]})); await tick(); f.build();
  assert.equal(f.component.voteState.detail, null); assert.equal(f.nodes.some(node => node.type === 'Progress'), false);
  f.reads[1].resolve(f.detail({id: '15591912', selectedIds: [9]})); await tick(); f.build();
  assert.deepEqual(f.component.voteState.detail.selectedIds, [9]);
  f.auth.advance(); f.component.onAccountChanged(); f.build();
  assert.equal(f.nodes.some(node => node.type === 'Progress'), false); assert.equal(f.button('提交评论投票'), undefined);
  f.reads[2].resolve(f.detail({id: '15591912'})); await tick(); f.build();
  assert.equal(f.button('评论投票选项2').props.enabled, true);
  f.button('查看评论投票结果').props.onClick(); f.build(); f.button('查看评论投票结果').props.onClick();
  const pending = f.reads.at(-1); f.component.source = f.source(332); // Watch deliberately has not run yet.
  pending.resolve(f.detail({id: '15591912', selectedIds: [2]})); await tick();
  assert.deepEqual(f.component.voteState.detail.selectedIds, [], 'host must read live Prop identity before a delayed Watch');
});

test('retained real button events cannot select or submit after poll reuse, source ABA or an account switch', async () => {
  const f = fixture(); await f.ready();
  const chooseOld = f.button('评论投票选项9').props.onClick;
  f.button('评论投票选项2').props.onClick(); f.build();
  const submitOld = f.button('提交评论投票').props.onClick;
  const resultsOld = f.button('查看评论投票结果').props.onClick;
  f.component.aboutToRecycle();
  f.component.aboutToReuse({source: f.source(221), vote: f.metadata('15591912')});
  await f.ready(f.detail({id: '15591912'}));
  chooseOld(); submitOld(); resultsOld();
  assert.deepEqual(f.component.voteState.selectedOptionIds, []);
  assert.equal(f.writes.length, 0); assert.equal(f.component.voteState.resultsVisible, false);

  f.component.aboutToRecycle();
  f.component.aboutToReuse({source: f.source(), vote: f.metadata()}); await f.ready();
  chooseOld(); assert.deepEqual(f.component.voteState.selectedOptionIds, [], 'matching IDs after source ABA must still reject a retained old event');
  const beforeAccount = f.button('评论投票选项9').props.onClick;
  f.auth.advance(); f.component.onAccountChanged(); await f.ready();
  beforeAccount(); assert.deepEqual(f.component.voteState.selectedOptionIds, []);
  f.button('评论投票选项9').props.onClick(); assert.deepEqual(f.component.voteState.selectedOptionIds, [9]);
});

test('long answers/images and multi-answer result rebuilds retain natural comment-list height without clipped rows', async () => {
  const f = fixture(); await f.ready(f.detail({maxSelect: 2, counts: [1, 1, 1], long: true, image: true}));
  const options = f.nodes.filter(node => node.type === 'Button' && /^评论投票选项/.test(node.props.accessibilityText || ''));
  assert.equal(options.length, 3);
  for (const option of options) {
    assert.equal(option.props.width, '100%'); assert.equal(option.props.height, undefined);
    assert.deepEqual(option.props.constraintSize, {minHeight: 44});
    const label = f.nodes.find(node => node.type === 'Text' && node.args[0] === f.component.voteState.detail.options[0].text);
    assert.equal(label.props.height, undefined); assert.equal(label.props.maxLines, undefined); assert.equal(label.props.lineHeight, 18);
  }
  assert.ok(f.nodes.some(node => node.type === 'Image' && node.props.height === 36));
  assert.equal(f.nodes.some(node => node.type === 'Scroll'), false, 'comment list owns scrolling; card must not clip answers into an inner viewport');
  f.button('查看评论投票结果').props.onClick(); await tick(); f.build();
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [33, 33, 33]);
  assert.ok(f.nodes.filter(node => node.type === 'Progress').every(node => node.props.width === '100%' && node.props.height === 4));
  assert.equal(f.nodes.some(node => node.type === 'Column' && (node.props.height !== undefined || node.props.constraintSize?.maxHeight)), false);
});
