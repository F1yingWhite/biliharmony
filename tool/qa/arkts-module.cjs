const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

// Each fixture gets an isolated module cache. Tests supply only platform/IO boundaries;
// production modules are loaded whole, with relative imports resolved as in the app.
function createArktsLoader({ mocks = {}, globals = {}, sourceRoot } = {}) {
  const root = sourceRoot || process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const cache = new Map();
  const scope = { Sendable: value => value, Concurrent: value => value, ...globals };
  function load(name) {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    if (cache.has(name)) return cache.get(name).exports;
    const mod = { exports: {} };
    cache.set(name, mod);
    try {
      const source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8');
      const code = ts.transpileModule(source, {
        compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
      }).outputText;
      new Function('require', 'module', 'exports', ...Object.keys(scope), code)(specifier => {
        if (specifier.startsWith('.')) {
          return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), specifier)));
        }
        if (Object.hasOwn(mocks, specifier)) return mocks[specifier];
        throw Error('Unmocked dependency ' + specifier + ' imported by ' + name);
      }, mod, mod.exports, ...Object.values(scope));
      return mod.exports;
    } catch (error) {
      cache.delete(name);
      throw error;
    }
  }
  return load;
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
module.exports = { createArktsLoader, deferred, tick };
