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
  assert.ok(scroll.props.constraintSize.maxHeight <= 90);
  assert.ok(!scroll.children.some(node => node.props.accessibilityText === '关闭当前互动卡片'));
  assert.ok(f.nodes.some(node => node.type === 'Column' && node.props.constraintSize?.maxHeight === 140));
  f.panel.fullscreen = true; f.build();
  assert.ok(f.nodes.some(node => node.type === 'Scroll' && node.props.constraintSize?.maxHeight === 230));
  assert.ok(f.nodes.some(node => node.type === 'Column' && node.props.constraintSize?.maxHeight === 280));
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
