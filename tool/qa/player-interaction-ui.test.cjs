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
  return {panel: ui.component, nodes: ui.nodes, callbacks, build: ui.build,
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
  assert.equal(rootNode.props.width, '85%'); assert.ok(rootNode.props.constraintSize.maxWidth <= 260);
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
  assert.ok((scroll.props.height || scroll.props.constraintSize?.maxHeight) <= 90);
  assert.ok(!scroll.children.some(node => node.props.accessibilityText === '关闭当前互动卡片'));
  assert.ok(f.nodes.some(node => node.type === 'Column' && node.props.constraintSize?.maxHeight === 140));
  f.panel.fullscreen = true; f.build();
  assert.ok(f.nodes.some(node => node.type === 'Scroll' && (node.props.height || node.props.constraintSize?.maxHeight) >= 220));
  assert.ok(f.nodes.some(node => node.type === 'Column' && node.props.constraintSize?.maxHeight === 280));
});

function descendants(node) {
  return node.children.flatMap(child => [child, ...descendants(child)]);
}

const voteCard = (selectedOptionId = 0, votes = [30, 70]) => ({...grade(), id: 'two-answer-vote', kind: 'vote',
  title: '很长的投票题目需要在窄屏中保持两个答案同时可见，不能把第二个答案挤到视口之外',
  selectedOptionId, options: [
    {id: 2, text: '第一个答案也有长文字，应在卡片内截断', votes: votes[0], hasSelfDef: false},
    {id: 9, text: '第二个答案', votes: votes[1], hasSelfDef: false},
  ]});

test('portrait vote reserves a measured body for both answers and keeps its question/close outside scrolling', () => {
  const f = fixture(voteCard());
  for (const availableHeight of [120, 132, 140]) {
    f.panel.availableHeight = availableHeight; f.build();
    const scroll = f.nodes.find(node => node.type === 'Scroll');
    const first = f.button('投票选项2'), second = f.button('投票选项9');
    assert.ok(first && second);
    assert.equal(descendants(scroll).some(node => node.type === 'Text' && node.args[0] === f.panel.current.title), false,
      'question must not consume the answer viewport');
    assert.equal(first.props.height, second.props.height); assert.ok(first.props.height >= 30);
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
  assert.deepEqual(f.nodes.filter(node => node.type === 'Progress').map(node => node.args[0].value), [0, 0]);
  assert.equal(f.button('投票选项2').props.enabled, false);
  f.panel.current = {...voteCard(), options: [...voteCard().options,
    {id: 17, text: '第三个答案', votes: 0, hasSelfDef: false}, {id: 22, text: '第四个答案', votes: 0, hasSelfDef: false}]};
  f.build(); const scroll = f.nodes.find(node => node.type === 'Scroll');
  assert.equal(descendants(scroll).filter(node => node.type === 'Button').length, 4);
  assert.equal(scroll.props.scrollBar, 'Auto'); assert.ok(scroll.props.height > 90);
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
