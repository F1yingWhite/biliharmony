// Prove the regression suite fails when production header wiring is broken.
// Run with the same ARKTS_TEST_TYPESCRIPT used by the regular Node tests.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const source = path.resolve(__dirname, '../../entry/src/main/ets');
const suite = path.join(__dirname, 'reply-vote-header.test.cjs');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'biliharmony-header-mutations-'));
const mutations = [
  ['skip legacy metadata', 'components/reply/MainRepliesController.ets',
    'if (data.needsVoteCard === true)', 'if (false)'],
  ['pagination cancels header', 'components/reply/MainRepliesController.ets',
    'if (reset) { this.prefetchCount = 0; this.voteGeneration++; }',
    'if (reset) this.prefetchCount = 0; this.voteGeneration++;'],
  ['drop source/account ownership', 'components/reply/MainRepliesController.ets',
    'return !this.host.isDestroyed() && generation === this.voteGeneration && account === AuthSession.version &&\n      sameReplySubject(subject, this.host.getSubject());', 'return true;'],
  ['discard vote-only comment', 'components/reply/ReplyState.ets',
    'item.pictures.length === 0 && !item.vote', 'item.pictures.length === 0'],
  ['lose page header prop', 'pages/VideoDetail.ets', 'voteCard: this.replyVoteCard,', 'voteCard: null,'],
  ['hide header panel', 'components/video/VideoReplyTab.ets', 'if (this.voteCard !== null)', 'if (false)'],
];
function run(root) {
  return spawnSync(process.execPath, ['--test', '--test-reporter=spec', suite], {
    encoding: 'utf8', timeout: 30000, env: {...process.env, ARKTS_TEST_SOURCE_ROOT: root},
  });
}
try {
  const baseline = run(source);
  assert.equal(baseline.status, 0, baseline.stdout + baseline.stderr);
  console.log('Baseline: 16 tests pass');
  for (const [index, [name, file, before, after]] of mutations.entries()) {
    const root = path.join(temp, String(index)); fs.cpSync(source, root, {recursive: true});
    const target = path.join(root, file); const text = fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n');
    assert.equal(text.split(before).length, 2, 'mutation target must be unique: ' + name);
    fs.writeFileSync(target, text.replace(before, after));
    const result = run(root), output = result.stdout + result.stderr;
    assert.ok(result.status > 0 && output.includes('AssertionError'), 'mutation must fail a behavioral assertion: ' + name + '\n' + output);
    assert.ok(!output.includes('SyntaxError') && !output.includes('Unmocked dependency'), output);
    const failures = output.match(/(?:ℹ|#) fail (\d+)/)?.[1];
    console.log(name + ': caught (' + failures + ' test failures)');
  }
} finally {
  const resolved = fs.realpathSync(temp), parent = fs.realpathSync(os.tmpdir());
  assert.ok(path.relative(parent, resolved).startsWith('biliharmony-header-mutations-'));
  fs.rmSync(resolved, {recursive: true, force: true});
}
