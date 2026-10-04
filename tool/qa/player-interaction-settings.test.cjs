const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createArktsLoader, deferred} = require('./arkts-module.cjs');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file + '.ets'), 'utf8').replace(/\r\n/g, '\n');

function diskFixture() {
  const disk = new Map(), pending = [];
  return {disk, pending, open() {
    const memory = new Map(disk);
    return {getSync: (key, fallback) => memory.has(key) ? memory.get(key) : fallback,
      putSync: (key, value) => memory.set(key, value),
      flush() {const gate = deferred(), snapshot = new Map(memory); pending.push({gate, snapshot}); return gate.promise;},
    };
  }, async finishFlushes() {
    for (const {gate, snapshot} of pending.splice(0)) {for (const [key, value] of snapshot) disk.set(key, value); gate.resolve();}
    await Promise.resolve();
  }};
}

function environment(disk, legacy = {}) {
  const storage = new Map(Object.entries(legacy));
  const AppStorage = {get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)};
  const load = createArktsLoader({mocks: {
    '@kit.ArkUI': {}, '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {deviceInfo: {}},
    '@kit.ArkData': {preferences: {getPreferencesSync: () => disk.open()}},
    '@kit.PerformanceAnalysisKit': {hilog: {info() {}, warn() {}, error() {}}}, 'BuildProfile': {DEBUG: false},
  }, globals: {AppStorage, PersistentStorage: {persistProp(key, value) {if (!storage.has(key)) storage.set(key, value);}}}});
  return {storage, load, theme: load('common/AppTheme').AppTheme};
}

function methodHarness(file, start, end, bindings = {}) {
  const source = read(file), begin = source.indexOf(start), finish = source.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin, 'production builder boundaries must be present: ' + file);
  const code = ts.transpileModule('export class Harness {\n' + source.slice(begin, finish) + '\n}', {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS},
  }).outputText;
  const module = {exports: {}};
  new Function('module', 'exports', ...Object.keys(bindings), code)(module, module.exports, ...Object.values(bindings));
  return module.exports.Harness;
}

test('UP interaction preference defaults on and survives fresh module/storage graphs after an actual flush', async () => {
  const disk = diskFixture(), first = environment(disk);
  first.theme.init({}); await first.theme.initThemeStore({});
  assert.equal(first.storage.get('playerInteractionEnabled'), true);
  first.theme.persistPlayerInteractionEnabled(false);
  assert.equal(first.storage.get('playerInteractionEnabled'), false);
  assert.equal(disk.disk.has('playerInteractionEnabled'), false, 'putSync is not durable by itself');
  assert.ok(disk.pending.length > 0, 'production must request flush'); await disk.finishFlushes();
  assert.equal(disk.disk.get('playerInteractionEnabled'), 'false');
  const fresh = environment(disk, {playerInteractionEnabled: true}); fresh.theme.init({});
  await fresh.theme.initThemeStore({}); assert.equal(fresh.storage.get('playerInteractionEnabled'), false);
  fresh.theme.persistPlayerInteractionEnabled(true); await disk.finishFlushes();
  const third = environment(disk); third.theme.init({}); await third.theme.initThemeStore({});
  assert.equal(third.storage.get('playerInteractionEnabled'), true);
});

test('UP interaction preference is independent of scrolling danmaku settings and their reset defaults', async () => {
  const disk = diskFixture(), env = environment(disk); env.theme.init({}); await env.theme.initThemeStore({});
  env.theme.persistPlayerInteractionEnabled(false);
  const settings = new (env.load('common/AppTheme').DanmakuSettings)();
  settings.enabled = false; env.theme.persistDanmakuSettings(settings);
  assert.equal(env.theme.loadDanmakuSettings().enabled, false);
  env.theme.persistPlayerInteractionEnabled(true);
  assert.equal(env.theme.loadDanmakuSettings().enabled, false, 'enabling interaction must not enable scrolling comments');
  env.theme.persistPlayerInteractionEnabled(false);
  env.theme.persistDanmakuSettings(new (env.load('common/AppTheme').DanmakuSettings)());
  assert.equal(env.storage.get('playerInteractionEnabled'), false, 'resetting danmaku must not reset UP interactions');
  assert.equal(env.theme.loadDanmakuSettings().enabled, true);
});

test('the real settings forwarding builder and UP interaction switch pass the selected value to persistence', async () => {
  const disk = diskFixture(), env = environment(disk); env.theme.init({}); await env.theme.initThemeStore({});
  let panelProps;
  const Content = methodHarness('components/player/PlayerSettingsContent', '  EmbeddedPanel(which:', '  build()', {
    PlayerSettingsPanel: props => panelProps = props,
  });
  const content = new Content(); Object.assign(content, {interactionEnabled: true,
    onInteractionEnabledChange: next => env.theme.persistPlayerInteractionEnabled(next)});
  content.EmbeddedPanel(0); assert.equal(panelProps.interactionEnabled, true);
  const ui = createNativeComponent('components/player/PlayerSettingsPanel', {props: panelProps});
  ui.build();
  const label = ui.nodes.find(node => node.type === 'Text' && node.args[0] === 'UP主互动');
  assert.ok(label, 'real settings build must show the switch');
  const toggle = label.parent.parent.children.find(node => node.type === 'Toggle');
  assert.equal(toggle.args[0].isOn, true); assert.equal(typeof toggle.props.onChange, 'function');
  toggle.props.onChange(false);
  assert.equal(env.storage.get('playerInteractionEnabled'), false); await disk.finishFlushes();
  assert.equal(disk.disk.get('playerInteractionEnabled'), 'false');
  ui.component.interactionEnabled = false; ui.build();
  const updated = ui.nodes.find(node => node.type === 'Text' && node.args[0] === 'UP主互动');
  assert.equal(updated.parent.parent.children.find(node => node.type === 'Toggle').args[0].isOn, false);
  ui.component.basicDanmakuOnly = true; ui.build();
  assert.equal(ui.nodes.some(node => node.type === 'Text' && node.args[0] === 'UP主互动'), false,
    'live settings must not expose an unsupported video-only interaction switch');
});
