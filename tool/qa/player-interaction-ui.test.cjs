const test = require('node:test');
const assert = require('node:assert/strict');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');

function fixture(card) {
  const callbacks = [];
  const ui = createNativeComponent('components/player/PlayerInteractionPanel', {props: {
    current: card, loading: false, submitting: false, message: '', fullscreen: false,
    onGrade: (...args) => callbacks.push(['grade', ...args]), onVote: (...args) => callbacks.push(['vote', ...args]),
    onLink: (...args) => callbacks.push(['link', ...args]), onDismiss: (...args) => callbacks.push(['dismiss', ...args]),
  }});
  // ArkUI's branch creates a Builder once; retain its first argument instead of
  // calling build() again with the latest card. This is a narrow closure regression,
  // not a replacement for the device's native partial-update runtime.
  const retainBuilder = name => {
    const first = ui.component.current;
    const callback = ui.component[name].bind(ui.component, first);
    return () => {ui.nodes.length = 0; ui.loops.length = 0; callback();};
  };
  return {panel: ui.component, nodes: ui.nodes, loops: ui.loops, callbacks, build: ui.build, retainBuilder,
    button: label => ui.nodes.find(item => item.type === 'Button' && item.props.accessibilityText === label)};
}
const grade = () => ({id: '100000000000000001', kind: 'grade', title: '这段怎么样', maxStars: 5,
  selectedStars: 0, averageScore: 8.4, count: 20, options: [], link: null});

test('real interaction build renders five stars and routes grade/dismiss with the rendered command ID', () => {
  const f = fixture(grade()); f.build();
  assert.equal(f.nodes.filter(node => node.type === 'Button' && /^评分\d星$/.test(node.props.accessibilityText || '')).length, 5);
  f.button('评分4星').props.onClick(); assert.deepEqual(f.callbacks, [['grade', '100000000000000001', 4]]);
  f.button('关闭当前互动卡片').props.onClick(); assert.deepEqual(f.callbacks.at(-1), ['dismiss', '100000000000000001']);
  const rootNode = f.nodes[0];
  assertCompactWidth(rootNode, 180);
  const stars = f.nodes.filter(node => node.type === 'Button' && /^评分\d星$/.test(node.props.accessibilityText || ''));
  assert.ok(stars.every(node => node.props.width === 26 && node.props.height === 28 && node.props.fontSize === 22 && node.props.padding === 0));
  assert.equal(f.button('关闭当前互动卡片').props.padding, 0, 'native Button padding must not clip the compact close glyph');
  assert.ok(stars.reduce((width, node) => width + node.props.width, 0) + stars[0].parent.args[0].space * 4 <= 180 - 12,
    'five compact stars must fit the portrait card without horizontal clipping');
  f.panel.fullscreen = true; f.build(); assertCompactWidth(f.nodes[0], 210);
});

test('real grade buttons ignore busy, completed and stale card clicks', () => {
  const f = fixture(grade()); f.build(); const click = f.button('评分5星').props.onClick;
  f.panel.submitting = true; click(); f.panel.submitting = false;
  f.panel.current = {...grade(), selectedStars: 4}; click();
  f.panel.current = {...grade(), id: '200000000000000002'}; click();
  assert.deepEqual(f.callbacks, []);
  f.build(); f.button('评分3星').props.onClick(); assert.deepEqual(f.callbacks, [['grade', '200000000000000002', 3]]);
});

test('real vote options submit their protocol option ID and disable custom/previously-voted choices', () => {
  const card = {...grade(), id: 'vote-1', kind: 'vote', selectedOptionId: 0,
    options: [{id: 2, text: '方案甲', votes: 15, hasSelfDef: false}, {id: 9, text: '自定义', votes: 1, hasSelfDef: true}]};
  const f = fixture(card); f.build();
  const normal = f.button('投票选项2'), custom = f.button('投票选项9');
  assert.equal(custom.props.enabled, false); custom.props.onClick(); assert.deepEqual(f.callbacks, []);
  normal.props.onClick(); assert.deepEqual(f.callbacks, [['vote', 'vote-1', 2]]);
  f.panel.current = {...card, selectedOptionId: 2}; normal.props.onClick(); assert.equal(f.callbacks.length, 1);
  f.build(); assert.equal(f.button('投票选项2').props.enabled, false);
  const scroll = f.nodes.find(node => node.type === 'Scroll');
  assert.equal(scroll.props.height, 60);
  assert.ok(!scroll.children.some(node => node.props.accessibilityText === '关闭当前互动卡片'));
  assertCompactVoteLayout(f, 104, 180, 28);
  f.panel.fullscreen = true; f.build();
  assertCompactVoteLayout(f, 120, 210, 32);
});

function descendants(node) {
  return node.children.flatMap(child => [child, ...descendants(child)]);
}

function assertCompactWidth(rootNode, maximum) {
  const width = typeof rootNode.props.width === 'number' ? rootNode.props.width : rootNode.props.constraintSize?.maxWidth;
  assert.equal(width, maximum, 'interaction footprint must use the compact portrait/fullscreen width');
  if (rootNode.props.constraintSize?.maxWidth !== undefined) assert.ok(rootNode.props.constraintSize.maxWidth <= maximum);
}

function assertCompactVoteLayout(f, height, width, optionHeight) {
  assertCompactWidth(f.nodes[0], width);
  const scroll = f.nodes.find(node => node.type === 'Scroll'), card = scroll.parent;
  const header = card.children.find(node => node.type === 'Row');
  assert.equal(card.props.constraintSize.maxHeight, height);
  assert.equal(card.props.padding, 6); assert.equal(card.args[0].space, 4); assert.equal(header.props.height, 28);
  assert.equal(scroll.props.height, height - header.props.height - card.args[0].space - card.props.padding * 2);
  const buttons = descendants(scroll).filter(node => node.type === 'Button' && /^投票选项/.test(node.props.accessibilityText || ''));
  assert.ok(buttons.every(button => button.props.height === optionHeight));
  const close = f.button('关闭当前互动卡片'); assert.equal(close.props.width, 24); assert.equal(close.props.height, 24);
  const question = descendants(header).find(node => node.type === 'Text' && node.args[0] === f.panel.current.title);
  assert.equal(question.props.fontSize, 10); assert.equal(question.props.maxLines, 1);
  for (const button of buttons) {
    const label = descendants(button).find(node => node.type === 'Text' && node.args[0] === button.props.accessibilityDescription);
    assert.equal(label.props.fontSize, 11); assert.equal(label.props.maxLines, 1);
  }
}

const voteCard = (selectedOptionId = 0, votes = [30, 70]) => ({...grade(), id: 'two-answer-vote', kind: 'vote',
  title: '很长的投票题目需要在窄屏中保持两个答案同时可见，不能把第二个答案挤到视口之外',
  selectedOptionId, options: [
    {id: 2, text: '第一个答案也有长文字，应在卡片内截断', votes: votes[0], hasSelfDef: false},
    {id: 9, text: '第二个答案', votes: votes[1], hasSelfDef: false},
  ]});

test('portrait vote reserves a measured body for both answers and keeps its question/close outside scrolling', () => {
  const f = fixture(voteCard());
  for (const availableHeight of [104, 120, 132, 140]) {
    f.panel.availableHeight = availableHeight; f.build();
    assertCompactVoteLayout(f, 104, 180, 28);
    const scroll = f.nodes.find(node => node.type === 'Scroll');
    const first = f.button('投票选项2'), second = f.button('投票选项9');
    assert.ok(first && second);
    assert.equal(descendants(scroll).some(node => node.type === 'Text' && node.args[0] === f.panel.current.title), false,
      'question must not consume the answer viewport');
    assert.equal(first.props.height, second.props.height); assert.equal(first.props.height, 28);
    assert.ok(scroll.props.height >= first.props.height + second.props.height + first.parent.args[0].space,
      'both real answer buttons must fit before scrolling');
    assert.equal(scroll.props.flexShrink, 0, 'parent must not shrink the reserved answer viewport');
    assert.equal(scroll.props.scrollBar, 'Auto', 'additional answers need a visible scroll affordance');
    const card = scroll.parent;
    const header = card.children.find(node => node.type === 'Row');
    assert.ok(descendants(header).includes(f.button('关闭当前互动卡片')));
    assert.ok(header.props.height + scroll.props.height + card.args[0].space + card.props.padding * 2 <= availableHeight,
      'header, padding and body must fit actual player space');
  }
  f.button('投票选项9').props.onClick(); assert.deepEqual(f.callbacks, [['vote', 'two-answer-vote', 9]]);
});

test('confirmed vote rebuild shows proportional bars, selected state and prevents any second submit', () => {
  const f = fixture(voteCard()); f.build();
  assert.equal(f.nodes.some(node => node.type === 'Progress'), false, 'unconfirmed draft must not display vote results');
  f.button('投票选项9').props.onClick();
  f.panel.submitting = true; f.build();
  assert.equal(f.nodes.some(node => node.type === 'Progress'), false);
  f.panel.submitting = false; f.panel.message = '提交失败，请重试'; f.build();
  assert.equal(f.nodes.some(node => node.type === 'Progress'), false, 'failed submission must not fabricate results');
  f.panel.current = voteCard(9, [30, 71]); f.panel.message = '已投票'; f.build();
  const bars = f.nodes.filter(node => node.type === 'Progress');
  assert.deepEqual(bars.map(node => node.args[0].value), [29, 71]);
  assert.ok(bars.every(node => node.args[0].total === 100 && node.args[0].type === 'Linear'));
  assert.ok(descendants(f.button('投票选项9')).some(node => node.type === 'Text' && node.args[0] === '✓'));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '71%'));
  assert.equal(f.button('投票选项2').props.enabled, false); f.button('投票选项2').props.onClick();
  assert.deepEqual(f.callbacks, [['vote', 'two-answer-vote', 9]]);
});

test('both confirmed answer labels and comparison bars fit the smallest supported player space', () => {
  const f = fixture(voteCard(9)); f.panel.availableHeight = 104; f.build();
  assertCompactVoteLayout(f, 104, 180, 28);
  const scroll = f.nodes.find(node => node.type === 'Scroll');
  for (const button of [f.button('投票选项2'), f.button('投票选项9')]) {
    const content = button.children.find(node => node.type === 'Column');
    const row = content.children.find(node => node.type === 'Row');
    const bar = content.children.find(node => node.type === 'Progress');
    assert.ok(row.props.height + content.args[0].space + bar.props.height +
      button.props.padding.top + button.props.padding.bottom <= button.props.height,
    'confirmed text and bar must fit without native Button compression');
  }
  assert.ok(f.button('投票选项2').props.height + f.button('投票选项9').props.height + 4 <= scroll.props.height);
});

test('server-selected zero-vote results remain finite and all multi-option choices scroll in fullscreen', () => {
  const f = fixture(voteCard(2, [0, 0])); f.panel.fullscreen = true; f.panel.availableHeight = 270; f.build();
  assertCompactVoteLayout(f, 120, 210, 32);
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [0, 0]);
  assert.equal(f.button('投票选项2').props.enabled, false);
  f.panel.current = {...voteCard(), options: [...voteCard().options,
    {id: 17, text: '第三个答案', votes: 0, hasSelfDef: false}, {id: 22, text: '第四个答案', votes: 0, hasSelfDef: false}]};
  f.build(); const scroll = f.nodes.find(node => node.type === 'Scroll');
  assert.equal(descendants(scroll).filter(node => node.type === 'Button').length, 4);
  assert.equal(scroll.props.scrollBar, 'Auto'); assert.equal(scroll.props.height, 76);
  const first = f.button('投票选项2'), second = f.button('投票选项9');
  assert.ok(first.props.height + second.props.height + first.parent.args[0].space <= scroll.props.height,
    'fullscreen stays compact while its first two answers fit and additional answers remain scrollable');
  f.button('投票选项22').props.onClick(); assert.deepEqual(f.callbacks, [['vote', 'two-answer-vote', 22]]);
});

test('real link button routes a navigable video ID and ignores an unavailable or stale target', () => {
  const card = {...grade(), id: 'link-1', kind: 'link', link: {aid: 170001, bvid: 'BV17x411w7KC', epId: 0, title: '推荐视频', cover: ''}};
  const f = fixture(card); f.build(); f.button('观看推荐视频').props.onClick();
  assert.deepEqual(f.callbacks, [['link', 'link-1']]);
  const click = f.button('观看推荐视频').props.onClick;
  f.panel.current = {...card, id: 'link-2'}; click(); assert.equal(f.callbacks.length, 1);
  f.panel.current = {...card, link: null}; f.build(); assert.equal(f.button('观看推荐视频').props.enabled, false);
});

test('no command builds no interactive buttons, and unknown command kinds expose no fake action', () => {
  const f = fixture(null); f.build(); assert.equal(f.nodes.filter(node => node.type === 'Button').length, 0);
  f.panel.current = {...grade(), kind: 'unknown'}; f.build();
  assert.equal(f.nodes.filter(node => node.type === 'Button' && node.props.accessibilityText !== '关闭当前互动卡片').length, 0);
});

test('retained grade Builder updates same-ID confirmed stars and statistics without reconstructing its call', () => {
  const f = fixture(grade()), update = f.retainBuilder('GradeContent'); update();
  const initialKeys = f.loops[0].keys.slice();
  f.panel.current = {...grade(), selectedStars: 4, averageScore: 9, count: 21}; update();
  assert.deepEqual(f.nodes.filter(node => node.type === 'Button').map(node => node.args[0]), ['★', '★', '★', '★', '☆']);
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '已评 4 星'));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '9.0 分 · 21 人评分'));
  assert.notDeepEqual(f.loops[0].keys, initialKeys, 'native ForEach must discard initial star snapshots after confirmation');
  assert.equal(f.button('评分5星').props.enabled, false); f.button('评分5星').props.onClick(); assert.deepEqual(f.callbacks, []);
});

test('retained vote Builder updates confirmed bars, selection and current answer text after a cloned response', () => {
  const f = fixture(voteCard()), update = f.retainBuilder('VoteContent'); update(); const initialKeys = f.loops[0].keys.slice();
  const latest = voteCard(9, [30, 71]); latest.options[1].text = '已刷新第二答案'; f.panel.current = latest; update();
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [29, 71]);
  assert.ok(descendants(f.button('投票选项9')).some(node => node.type === 'Text' && node.args[0] === '✓'));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '已刷新第二答案'));
  assert.notDeepEqual(f.loops[0].keys, initialKeys, 'result comparison must replace native answer snapshots');
  assert.equal(f.button('投票选项2').props.enabled, false);
});

test('retained Card Builder follows non-null grade → vote → link windows and rejects an old window click', () => {
  const f = fixture(grade()), update = f.retainBuilder('Card'); update();
  const oldStar = f.button('评分4星').props.onClick, oldClose = f.button('关闭当前互动卡片').props.onClick;
  f.panel.current = {...voteCard(), id: 'window-vote', title: '新投票窗口'}; update();
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '新投票窗口'));
  assert.equal(f.button('评分4星'), undefined); assert.ok(f.button('投票选项9'));
  oldStar(); oldClose(); assert.deepEqual(f.callbacks, []);
  f.button('投票选项9').props.onClick(); assert.deepEqual(f.callbacks, [['vote', 'window-vote', 9]]);
  f.panel.current = {...grade(), id: 'window-link', kind: 'link', title: '关联窗口',
    link: {aid: 170001, bvid: 'BV17x411w7KC', epId: 0, title: '当前关联视频', cover: ''}}; update();
  assert.equal(f.button('投票选项9'), undefined); assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '当前关联视频'));
  f.button('观看推荐视频').props.onClick(); assert.deepEqual(f.callbacks.at(-1), ['link', 'window-link']);
});
