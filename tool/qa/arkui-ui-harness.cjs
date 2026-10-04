const fs = require('node:fs');
const path = require('node:path');
const {createArktsLoader} = require('./arkts-module.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

// Translate only native container blocks to child callbacks. Production build,
// conditions, loops, property chains and event handlers execute without copies.
function nativeBlocks(source) {
  const scanner = ts.createScanner(ts.ScriptTarget.ES2020, true, ts.LanguageVariant.Standard, source), tokens = [];
  for (let kind = scanner.scan(); kind !== ts.SyntaxKind.EndOfFileToken; kind = scanner.scan()) {
    tokens.push({kind, text: scanner.getTokenText(), start: scanner.getTokenPos(), end: scanner.getTextPos()});
  }
  const edits = [], containers = new Set(['Column', 'Row', 'Scroll', 'Button', 'Flex', 'List', 'ListItem', 'Stack']);
  const balanced = (start, open, close) => {
    let depth = 0;
    for (let index = start; index < tokens.length; index++) {
      if (tokens[index].kind === open) depth++;
      else if (tokens[index].kind === close) {depth--; if (depth === 0) return index;}
    }
    throw Error('unbalanced native UI block');
  };
  for (let index = 0; index < tokens.length; index++) {
    if (!containers.has(tokens[index].text) || tokens[index + 1]?.kind !== ts.SyntaxKind.OpenParenToken) continue;
    const paren = balanced(index + 1, ts.SyntaxKind.OpenParenToken, ts.SyntaxKind.CloseParenToken);
    if (tokens[paren + 1]?.kind !== ts.SyntaxKind.OpenBraceToken) continue;
    const end = balanced(paren + 1, ts.SyntaxKind.OpenBraceToken, ts.SyntaxKind.CloseBraceToken);
    edits.push({start: tokens[paren].start, end: tokens[paren].end,
      text: (paren === index + 2 ? '' : ', ') + '() =>'});
    edits.push({start: tokens[end].end, end: tokens[end].end, text: ')'});
  }
  for (const edit of edits.sort((a, b) => b.start - a.start)) source = source.slice(0, edit.start) + edit.text + source.slice(edit.end);
  return source;
}

function createNativeComponent(name, {props = {}, mocks = {}, globals: supplied = {}} = {}) {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const nodes = [], stack = [], globals = {};
  function native(type, ...args) {
    const parent = stack.at(-1), item = {type, args, parent, children: [], props: {}}; nodes.push(item);
    if (parent) parent.children.push(item);
    const children = args.at(-1);
    if (typeof children === 'function') {stack.push(item); children(); stack.pop();}
    let proxy;
    proxy = new Proxy({}, {get: (_target, key) => (...values) => {
      item.props[key] = values.length === 1 ? values[0] : values; return proxy;
    }});
    return proxy;
  }
  for (const type of ['Column', 'Row', 'Scroll', 'Text', 'Button', 'Image', 'Blank', 'LoadingProgress',
    'Slider', 'Toggle', 'Divider', 'Flex', 'List', 'ListItem', 'Stack']) globals[type] = (...args) => native(type, ...args);
  globals.ForEach = (items, render) => items.forEach(render);
  globals.$r = resource => resource;
  for (const type of ['FlexAlign', 'ItemAlign', 'HorizontalAlign', 'FontWeight', 'ButtonType', 'ImageFit',
    'BarState', 'ScrollDirection', 'TextAlign', 'ToggleType', 'SliderStyle', 'ImageRenderMode', 'FlexWrap',
    'FlexDirection', 'TextOverflow', 'Alignment', 'TransitionEffect', 'Curve']) {
    globals[type] = new Proxy({}, {get: (_target, key) => key});
  }
  Object.assign(globals, supplied);
  const className = name.split('/').at(-1);
  let source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8').replace(/\r\n/g, '\n');
  source = source.replace('export struct ' + className, 'export class ' + className)
    .replace(/@(?:Component|Prop|State|StorageProp|Builder)\b(?:\([^)]*\))?\s*/g, '');
  const code = ts.transpileModule(nativeBlocks(source), {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS},
  }).outputText;
  const module = {exports: {}}, load = createArktsLoader({mocks, globals});
  new Function('require', 'module', 'exports', ...Object.keys(globals), code)(specifier => load(
    path.posix.normalize(path.posix.join(path.posix.dirname(name), specifier))),
  module, module.exports, ...Object.values(globals));
  const component = new module.exports[className](); Object.assign(component, props);
  return {component, nodes, build() {nodes.length = 0; component.build();}};
}

module.exports = {createNativeComponent};
