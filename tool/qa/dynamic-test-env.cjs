// Execute complete dynamic-domain modules with only API/platform boundaries replaced.
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
function read(file) {
  const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, file + '.ets');
  return fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, file + '.ets'), 'utf8')
    .replace(/\r\n/g, '\n');
}
function environment(mocks = {}, globals = {}) {
  const cache = new Map();
  function load(name) {
    if (name in mocks) return mocks[name];
    if (cache.has(name)) return cache.get(name);
    const module = { exports: {} };
    cache.set(name, module.exports);
    const code = ts.transpileModule(read(name), { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
    } }).outputText;
    const requireLocal = dep => load(dep.startsWith('.') ?
      path.posix.normalize(path.posix.join(path.posix.dirname(name), dep)) : dep);
    new Function('require', 'module', 'exports', ...Object.keys(globals), code)(
      requireLocal, module, module.exports, ...Object.values(globals));
    cache.set(name, module.exports);
    return module.exports;
  }
  return { load };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
module.exports = { environment, read, deferred, tick: () => new Promise(resolve => setImmediate(resolve)) };
