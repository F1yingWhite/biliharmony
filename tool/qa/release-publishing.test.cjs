const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');

const project = path.resolve(__dirname, '../..');
const skip = process.platform === 'win32' ? 'Release scripts require the POSIX shell used by GitHub Actions.' : false;

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'biliharmony-release-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  for (const folder of ['tool', 'AppScope', 'bin', 'entry/build/default/outputs/default']) {
    fs.mkdirSync(path.join(directory, folder), {recursive: true});
  }
  for (const filename of ['publish-release.cjs', 'release-notes.sh']) {
    fs.copyFileSync(path.join(project, 'tool', filename), path.join(directory, 'tool', filename));
  }
  fs.writeFileSync(path.join(directory, 'AppScope/app.json5'), '{"app":{"versionName":"1.4.0"}}');
  fs.writeFileSync(path.join(directory, 'CHANGELOG.md'), '# Changelog\n\n## [1.4.1] - future\nFuture-only change\n\n## [1.4.0] - today\n- Unified playback core\n- Fix surface output\n\n## [1.3.2] - old\nOld-only change\n');
  fs.writeFileSync(path.join(directory, 'entry/build/default/outputs/default/entry-default-unsigned.hap'), 'tested-hap-bytes');
  const stateFile = path.join(directory, 'remote.json');
  fs.writeFileSync(stateFile, JSON.stringify({releases: [], refs: [], objects: {}, calls: []}));
  // This executable mocks only the remote boundary. Real production scripts,
  // local Git history, SHA calculation and release-note generation execute.
  fs.writeFileSync(path.join(directory, 'bin', 'gh'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(process.env.QA_RELEASE_STATE, 'utf8'));
state.calls.push(args);
fs.writeFileSync(process.env.QA_RELEASE_STATE, JSON.stringify(state));
if (state.failEndpoint && args[1] === state.failEndpoint) { console.error('remote unavailable'); process.exit(1); }
if (args[0] === 'api' && args.includes('POST')) {
  if (state.tagRace) { console.error('Reference already exists'); process.exit(1); }
  console.log('{}');
} else if (args[0] === 'api' && args[1].includes('/releases?')) console.log(JSON.stringify([state.releases]));
else if (args[0] === 'api' && args[1].includes('/git/matching-refs/')) console.log(JSON.stringify(state.refs));
else if (args[0] === 'api' && args[1].includes('/git/tags/')) console.log(JSON.stringify({object: state.objects[args[1].split('/').pop()]}));
else if (args[0] === 'release' && args[1] === 'create') console.log('created');
else { console.error('Unexpected gh command'); process.exit(2); }
`, {mode: 0o755});
  const env = {...process.env, PATH: `${path.join(directory, 'bin')}${path.delimiter}${process.env.PATH}`,
    GITHUB_REPOSITORY: 'example/biliharmony', QA_RELEASE_STATE: stateFile,
    GITHUB_STEP_SUMMARY: path.join(directory, 'summary.md'), GITHUB_OUTPUT: path.join(directory, 'output.txt')};
  function execute(command, args, allowFailure = false) {
    const result = spawnSync(command, args, {cwd: directory, env, encoding: 'utf8', timeout: 10000});
    if (!allowFailure) assert.equal(result.status, 0, `${result.error?.message || ''}\n${result.stderr}`);
    return result;
  }
  execute('git', ['init', '-q']);
  execute('git', ['config', 'user.name', 'Release QA']);
  execute('git', ['config', 'user.email', 'release-qa@example.invalid']);
  execute('git', ['add', 'CHANGELOG.md', 'AppScope/app.json5']);
  execute('git', ['commit', '-qm', 'feat: previous-version-only-change']);
  const previous = execute('git', ['rev-parse', 'HEAD']).stdout.trim();
  execute('git', ['tag', 'v1.3.2']);
  function commit(subject) {
    execute('git', ['commit', '--allow-empty', '-qm', subject]);
    env.GITHUB_SHA = execute('git', ['rev-parse', 'HEAD']).stdout.trim();
    return env.GITHUB_SHA;
  }
  commit('fix(player): repaired-surface');
  function state(update) {
    const value = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (update) { Object.assign(value, update); fs.writeFileSync(stateFile, JSON.stringify(value)); }
    return value;
  }
  const release = (tag = 'v1.4.0', changes = {}) => ({tag_name: tag, draft: false, prerelease: false,
    assets: [{name: `biliharmony-${tag}-unsigned.hap`}, {name: 'hap.sha256'}], ...changes});
  const ref = (sha = env.GITHUB_SHA, type = 'commit') => ({ref: 'refs/tags/v1.4.0', object: {type, sha}});
  const publish = () => execute(process.execPath, ['tool/publish-release.cjs'], true);
  return {directory, env, execute, state, commit, previous, release, ref, publish};
}

test('new app version creates one exact tag and versioned Release with previous-release notes', {skip}, t => {
  const f = fixture(t);
  f.commit('build: toolchain-update'); f.commit('test: real-core-regression'); f.commit('chore: maintenance');
  f.state({releases: [f.release('latest'), f.release('v1.3.2')]});
  assert.equal(f.publish().status, 0);
  const calls = f.state().calls;
  const mutations = calls.filter(args => args.includes('POST') || args[0] === 'release');
  assert.equal(mutations.length, 2);
  assert.deepEqual(mutations[0], ['api', 'repos/example/biliharmony/git/refs', '-X', 'POST', '-f', 'ref=refs/tags/v1.4.0', '-f', `sha=${f.env.GITHUB_SHA}`]);
  const create = mutations[1];
  assert.deepEqual(create.slice(0, 3), ['release', 'create', 'v1.4.0']);
  assert.equal(create[create.indexOf('--target') + 1], f.env.GITHUB_SHA);
  assert.ok(create.includes('--latest') && create.includes('--verify-tag'));
  assert.equal(create[create.indexOf('--title') + 1], 'BiliHarmony v1.4.0');
  assert.equal(path.basename(create.at(-2)), 'biliharmony-v1.4.0-unsigned.hap');
  const notes = fs.readFileSync(path.join(f.directory, 'release_notes.md'), 'utf8');
  assert.match(notes, /^# BiliHarmony v1\.4\.0/);
  for (const text of ['Unified playback core', 'Fix surface output', 'repaired-surface', 'toolchain-update', 'real-core-regression', 'maintenance']) assert.ok(notes.includes(text), text);
  for (const text of ['Future-only change', 'Old-only change', 'previous-version-only-change']) assert.ok(!notes.includes(text), text);
  assert.match(notes, /compare\/v1\.3\.2\.\.\.v1\.4\.0/);
  assert.ok(notes.includes(`/blob/${f.env.GITHUB_SHA}/CHANGELOG.md`));
});

test('CI artifact uses the app version and a checksum of the same renamed HAP bytes', {skip}, t => {
  const f = fixture(t);
  f.execute(process.execPath, ['tool/publish-release.cjs', '--prepare-artifact']);
  const output = path.join(f.directory, 'entry/build/default/outputs/default/publish');
  const bytes = fs.readFileSync(path.join(output, 'biliharmony-v1.4.0-unsigned.hap'));
  assert.equal(bytes.toString(), 'tested-hap-bytes');
  assert.equal(fs.readFileSync(path.join(output, 'hap.sha256'), 'utf8'), `${crypto.createHash('sha256').update(bytes).digest('hex')}  biliharmony-v1.4.0-unsigned.hap\n`);
  assert.equal(fs.readFileSync(f.env.GITHUB_OUTPUT, 'utf8'), 'tag=v1.4.0\n');
  assert.deepEqual(f.state().calls, []);
});

test('same-commit completed Release rerun succeeds without modifying tags, notes or assets', {skip}, t => {
  const f = fixture(t); f.state({releases: [f.release()], refs: [f.ref()]});
  const result = f.publish(); assert.equal(result.status, 0); assert.match(result.stdout, /already published/);
  assert.ok(f.state().calls.every(args => args[0] === 'api' && !args.includes('POST')));
  assert.ok(!fs.existsSync(path.join(f.directory, 'release_notes.md')));
});

test('a new commit with an already published version keeps only its artifact and asks for a version bump', {skip}, t => {
  const f = fixture(t); f.state({releases: [f.release()], refs: [f.ref(f.previous)]});
  const result = f.publish(); assert.equal(result.status, 0);
  assert.match(result.stdout, /::warning::.*increase AppScope\/app\.json5 versionName/);
  assert.ok(f.state().calls.every(args => args[0] === 'api' && !args.includes('POST')));
  assert.ok(fs.existsSync(path.join(f.directory, 'entry/build/default/outputs/default/publish/biliharmony-v1.4.0-unsigned.hap')));
});

test('annotated version tags are resolved to their commit before completed-release checks', {skip}, t => {
  const f = fixture(t); const objectSha = 'a'.repeat(40);
  f.state({releases: [f.release()], refs: [f.ref(objectSha, 'tag')], objects: {[objectSha]: {type: 'commit', sha: f.env.GITHUB_SHA}}});
  assert.equal(f.publish().status, 0);
  assert.ok(f.state().calls.some(args => args[1] === `repos/example/biliharmony/git/tags/${objectSha}`));
  assert.ok(f.state().calls.every(args => !args.includes('POST') && args[0] !== 'release'));
});

for (const sameCommit of [true, false]) {
  test(`dangling version tag ${sameCommit ? 'at this commit' : 'at another commit'} is never reused`, {skip}, t => {
    const f = fixture(t); f.state({refs: [f.ref(sameCommit ? f.env.GITHUB_SHA : f.previous)]});
    const result = f.publish(); assert.notEqual(result.status, 0); assert.match(result.stderr, /never reused or moved/);
    assert.ok(f.state().calls.every(args => !args.includes('POST') && args[0] !== 'release'));
  });
}

test('remote query failure cannot be mistaken for an absent release', {skip}, t => {
  const f = fixture(t); f.state({failEndpoint: 'repos/example/biliharmony/releases?per_page=100'});
  const result = f.publish(); assert.notEqual(result.status, 0); assert.match(result.stderr, /remote unavailable/);
  assert.equal(f.state().calls.length, 1);
});

test('tag creation rejects a racing existing tag before any Release is created', {skip}, t => {
  const f = fixture(t); f.state({tagRace: true});
  const result = f.publish(); assert.notEqual(result.status, 0); assert.match(result.stderr, /Reference already exists/);
  assert.ok(!f.state().calls.some(args => args[0] === 'release'));
});

test('incomplete published assets are reported without uploading or replacing anything', {skip}, t => {
  const f = fixture(t); f.state({releases: [f.release('v1.4.0', {assets: []})], refs: [f.ref()]});
  const result = f.publish(); assert.notEqual(result.status, 0); assert.match(result.stderr, /missing release assets/);
  assert.ok(f.state().calls.every(args => !args.includes('POST') && args[0] !== 'release'));
});

test('previous-release selection uses numbered semver releases rather than moving or unpublished tags', {skip}, t => {
  const f = fixture(t); f.execute('git', ['tag', 'v1.3.10']);
  f.commit('feat!: semver-order-test');
  f.execute('git', ['tag', 'v1.3.99']); // A tag without a Release cannot delimit notes.
  f.state({releases: [f.release('latest'), f.release('v1.3.2'), f.release('v1.3.10'), f.release('v9.0.0', {prerelease: true}), f.release('v1.3.20-beta')]});
  assert.equal(f.publish().status, 0);
  const notes = fs.readFileSync(path.join(f.directory, 'release_notes.md'), 'utf8');
  assert.match(notes, /compare\/v1\.3\.10\.\.\.v1\.4\.0/);
  assert.match(notes, /semver-order-test/); assert.ok(!notes.includes('repaired-surface'));
});

test('a lower app version cannot publish a new Release or downgrade the latest version', {skip}, t => {
  const f = fixture(t); f.state({releases: [f.release('v1.4.1')]});
  const result = f.publish(); assert.notEqual(result.status, 0); assert.match(result.stderr, /must advance beyond published stable v1\.4\.1/);
  assert.ok(f.state().calls.every(args => !args.includes('POST') && args[0] !== 'release'));
});

test('build commit mismatch and non-semver app versions fail before any remote call', {skip}, t => {
  const f = fixture(t); f.env.GITHUB_SHA = f.previous;
  assert.notEqual(f.publish().status, 0); assert.deepEqual(f.state().calls, []);
  fs.writeFileSync(path.join(f.directory, 'AppScope/app.json5'), '{"app":{"versionName":"latest"}}');
  const result = f.publish(); assert.notEqual(result.status, 0); assert.match(result.stderr, /stable X.Y.Z/);
  assert.deepEqual(f.state().calls, []);
});
