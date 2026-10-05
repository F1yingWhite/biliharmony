const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {createArktsLoader} = require('./arkts-module.cjs');

function fixture({retainSpans = false} = {}) {
  const nodes = [], opened = [], copied = [], stack = [];
  const retained = new Map();
  const native = type => (...args) => {
    const node = {type, args, props: {}, parent: stack.at(-1)}; nodes.push(node);
    if (typeof args.at(-1) === 'function') {stack.push(node); args.at(-1)(); stack.pop();}
    let proxy; proxy = new Proxy({}, {get: (_target, property) => (...values) => {
      node.props[property] = values[0]; return proxy;
    }}); return proxy;
  };
  const globals = {Text: native('Text'), Span: native('Span'), ImageSpan: native('ImageSpan'),
    // Narrowly preserve a native ForEach child's original callbacks when its key
    // is reused. This checks callback rebinding, not native glyph measurement.
    ForEach: (items, render, key) => items.forEach(item => {
      const id = key(item);
      if (retainSpans && retained.has(id)) {nodes.push(...retained.get(id)); return;}
      const start = nodes.length; render(item);
      if (retainSpans) retained.set(id, nodes.slice(start));
    }),
    LongPressGesture: () => ({onAction(action) {this.action = action; return this;}}),
    TouchType: {Down: 0, Up: 1, Move: 2, Cancel: 3}, ImageFit: {}, ImageSpanAlignment: {BOTTOM: 1}};
  const load = createArktsLoader({mocks: {
    'common/CommentLog': {CommentLog: {info() {}}},
    'common/EmoteImageCache': {EmoteImageCache: {localPathOf: url => url, ensure: async url => url}},
  }, globals});
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  let source = fs.readFileSync(path.join(root, 'components/reply/ReplyRichText.ets'), 'utf8').replace(/\r\n/g, '\n');
  // As in arkui-ui-harness, translate native child-block syntax only. The entire
  // production component and parser execute; no layout or click logic is copied.
  assert.ok(source.includes('      Text() {') && source.includes('      }\n      .fontSize(this.fontSize)'));
  source = source.replace('      Text() {', '      Text(() => {')
    .replace('      }\n      .fontSize(this.fontSize)', '      })\n      .fontSize(this.fontSize)')
    .replace(/\bstruct\s+(\w+)/g, 'class $1')
    .replace(/@(?:Component|Prop|State|StorageProp|Watch)\b(?:\([^)]*\))?\s*/g, '');
  const module = {exports: {}}, code = ts.transpileModule(source, {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS},
  }).outputText;
  new Function('require', 'module', 'exports', ...Object.keys(globals), code)(specifier => load(
    path.posix.normalize(path.posix.join('components/reply', specifier))), module, module.exports, ...Object.values(globals));
  const {ReplyItem, ReplyJump} = load('model/Models');
  const reply = Object.assign(new ReplyItem(), {rpid: 9, oid: 170001, type: 1,
    content: '长正文中的混排 abc '.repeat(80) + 'oto 的配置，openutau 的教学，还有 oto。',
    jumps: ['oto', 'openutau'].map(label => Object.assign(new ReplyJump(), {label,
      url: 'https://search.bilibili.com/all?keyword=' + label}))});
  const component = new module.exports.ReplyRichText();
  Object.assign(component, {reply, onOpenPart: part => opened.push(part), onLongPress: () => copied.push('copy')});
  component.build();
  const text = nodes.find(node => node.type === 'Text');
  const touch = (type, x = 11, y = 250) => text.props.onTouch({type: globals.TouchType[type], touches: [{x, y}]});
  return {component, nodes, opened, copied, text, touch, rebuild() {nodes.length = 0; component.build();},
    span: label => nodes.find(node => node.type === 'Span' && node.args[0] === label)};
}

test('actual long mixed comment spans own native clicks and Text touch never estimates a navigation', () => {
  const f = fixture();
  for (const label of ['oto', 'openutau']) {
    const span = f.span(label); assert.equal(typeof span.props.onClick, 'function');
    f.touch('Down', 11, 250); f.touch('Up', 11, 250);
    const before = f.opened.length; assert.equal(before, label === 'oto' ? 0 : 1);
    span.props.onClick();
    assert.equal(f.opened.length, before + 1, 'a native Span click must open exactly once regardless of estimated glyph positions');
    assert.equal(f.opened.at(-1).text, label);
    assert.equal(f.opened.at(-1).url, 'https://search.bilibili.com/all?keyword=' + label);
  }
});

test('Text long press copies once and suppresses its trailing native Span click until the next touch', () => {
  const f = fixture(), click = f.span('oto').props.onClick; assert.equal(typeof click, 'function');
  f.touch('Down'); f.text.props.gesture.action(); f.touch('Up'); click();
  assert.deepEqual(f.copied, ['copy']); assert.equal(f.opened.length, 0);
  f.touch('Down'); f.touch('Up'); click(); assert.equal(f.opened.length, 1);
});

test('scroll movement and cancellation suppress clicks but do not swallow the next normal native tap', () => {
  const f = fixture(), click = f.span('openutau').props.onClick; assert.equal(typeof click, 'function');
  f.touch('Down'); f.touch('Move', 11, 280); f.touch('Up', 11, 280); click();
  f.touch('Down'); f.touch('Cancel'); click(); assert.equal(f.opened.length, 0);
  f.touch('Down'); f.touch('Up'); click(); assert.equal(f.opened.length, 1);
});

test('plain spans and callbacks retained from another comment cannot open a link', () => {
  const f = fixture(), click = f.span('oto').props.onClick; assert.equal(typeof click, 'function');
  const plain = f.nodes.find(node => node.type === 'Span' && node.args[0].startsWith('长正文'));
  plain.props.onClick(); assert.equal(f.opened.length, 0);
  f.component.reply = {...f.component.reply, rpid: 10}; f.component.onReplyChanged(); click();
  assert.equal(f.opened.length, 0);
});

test('same-identity reply clones rebind native Span callbacks and reject the retained old callback', () => {
  const f = fixture({retainSpans: true}), old = f.span('oto').props.onClick;
  const current = f.component.reply.clone(); current.like++;
  current.jumps = current.jumps.map(jump => ({...jump, url: jump.label === 'oto' ?
    'https://search.bilibili.com/all?keyword=current-oto' : jump.url}));
  f.component.reply = current; f.component.onReplyChanged(); f.rebuild();
  old(); assert.equal(f.opened.length, 0);
  const rebound = f.span('oto').props.onClick;
  assert.notEqual(rebound, old, 'same-rpid ForEach children must replace their generation-bound callback');
  rebound(); assert.equal(f.opened.length, 1);
  assert.equal(f.opened[0].url, 'https://search.bilibili.com/all?keyword=current-oto');
  f.component.aboutToDisappear(); rebound(); assert.equal(f.opened.length, 1);
});
