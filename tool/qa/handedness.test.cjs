// Exercise real service code across grip-only changes, pinning and foreground lifecycles.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/common/Handedness.ets'), 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
function setup({ unsupported = false, failHolding = false, pinned = false } = {}) {
  const storage = new Map([['dockSearchSidePinned', pinned]]);
  const listeners = new Map();
  let subscriptions = 0;
  const motion = {
    HoldingHandStatus: { NOT_HELD: 0, LEFT_HAND_HELD: 1, RIGHT_HAND_HELD: 2, BOTH_HANDS_HELD: 3, UNKNOWN_STATUS: 16 },
    OperatingHandStatus: { UNKNOWN_STATUS: 0, LEFT_HAND_OPERATED: 1, RIGHT_HAND_OPERATED: 2 },
    on(name, callback) {
      if (name === 'holdingHandChanged' && failHolding) throw { code: 801 };
      subscriptions++;
      listeners.set(name, callback);
    },
    off(name, callback) { if (listeners.get(name) === callback) listeners.delete(name); }
  };
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', 'canIUse', code)(
    name => name === '@kit.MultimodalAwarenessKit' ? { motion } : { hilog: { info() {} } },
    module, module.exports,
    { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    { persistProp: (key, value) => { if (!storage.has(key)) storage.set(key, value); } },
    () => !unsupported
  );
  const service = module.exports.Handedness;
  service.init();
  return { service, listeners, subscriptions: () => subscriptions,
    grip: status => listeners.get('holdingHandChanged')?.(status),
    operate: status => listeners.get('operatingHandChanged')?.(status) };
}
test('switching grip alone moves left then right without any touch event', () => {
  const e = setup();
  e.grip(1); assert.equal(e.service.side(), 'left');
  e.grip(2); assert.equal(e.service.side(), 'right');
  e.grip(1); assert.equal(e.service.side(), 'left');
});
test('unknown, not held and both hands do not move the entry', () => {
  const e = setup(); e.grip(1);
  for (const status of [0, 3, 16]) { e.grip(status); assert.equal(e.service.side(), 'left'); }
});
test('a single holding hand wins over touches from the other hand', () => {
  const e = setup(); e.grip(1); e.operate(2);
  assert.equal(e.service.side(), 'left');
  e.grip(3); e.operate(2); assert.equal(e.service.side(), 'right');
});
test('pinning stops subscriptions and ignores queued events; automatic restores both', () => {
  const e = setup(); const old = e.listeners.get('holdingHandChanged');
  e.service.pin('right'); old(1);
  assert.equal(e.service.side(), 'right'); assert.equal(e.listeners.size, 0);
  e.service.useAutomatic(); e.grip(1);
  assert.equal(e.listeners.size, 2); assert.equal(e.service.side(), 'left');
  old(2); assert.equal(e.service.side(), 'left');
});
test('foreground resubscribes once and rejects callbacks from the previous subscription', () => {
  const e = setup(); const old = e.listeners.get('holdingHandChanged');
  e.service.init(); e.service.setActive(true); assert.equal(e.subscriptions(), 2);
  e.service.setActive(false); old(1);
  assert.equal(e.service.side(), 'right'); assert.equal(e.listeners.size, 0);
  e.service.setActive(true); e.grip(1); old(2);
  assert.equal(e.subscriptions(), 4); assert.equal(e.service.side(), 'left');
});
test('unavailable holding detection preserves operating-hand fallback', () => {
  const e = setup({ failHolding: true }); e.operate(1);
  assert.equal(e.service.side(), 'left'); assert.equal(e.listeners.size, 1);
});
test('unsupported devices and persisted pin stay usable without subscriptions', () => {
  const unsupported = setup({ unsupported: true });
  assert.equal(unsupported.listeners.size, 0); unsupported.service.pin('left');
  assert.equal(unsupported.service.side(), 'left');
  const pinned = setup({ pinned: true }); assert.equal(pinned.listeners.size, 0);
  pinned.service.useAutomatic(); pinned.grip(1); assert.equal(pinned.service.side(), 'left');
});
