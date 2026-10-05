const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');

// Run against isolated source copies. A passing mutant is a regression-test failure.
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const evidence = fs.mkdtempSync(path.join(os.tmpdir(), 'biliharmony-reply-vote-api-mutations-'));
const mutations = [
  ['array-position-instead-of-option-id', 'api/ReplyVoteApi.ets',
    'votes: selectedIds.slice(), voter_uid: voter', 'votes: selectedIds.map((id: number, index: number): number => index + 1), voter_uid: voter'],
  ['wrong-playback-vote-endpoint', 'api/ReplyVoteApi.ets',
    'postVideoAction(Api.replyVote,', 'postVideoAction(Api.commandVote,'],
  ['missing-legacy-header-enrichment', 'model/reply/ReplyModels.ets',
    "data.needsVoteCard = pageNumber === 1 && j['vote_card'] === undefined;", 'data.needsVoteCard = false;'],
  ['missing-account-result-guard', 'api/ReplyVoteApi.ets',
    "if (session !== AuthSession.version) throw new Error('账号已切换，请重新加载投票');", 'if (false) throw new Error("disabled guard");'],
];
function run(tree) {
  return spawnSync(process.execPath, ['--test', '--test-timeout=20000', '--test-reporter=spec',
    path.join(__dirname, 'reply-vote-api.test.cjs')],
    {encoding: 'utf8', timeout: 30000, env: {...process.env, ARKTS_TEST_SOURCE_ROOT: tree}});
}
const baseline = run(root);
assert.equal(baseline.status, 0, baseline.stdout + baseline.stderr);
console.log('Baseline: actual API tests pass');
let survived = false;
for (const [name, file, original, changed] of mutations) {
  const tree = path.join(evidence, name); fs.cpSync(root, tree, {recursive: true});
  const target = path.join(tree, file), text = fs.readFileSync(target, 'utf8');
  if (!text.includes(original)) throw Error('Mutation target missing: ' + name);
  fs.writeFileSync(target, text.replace(original, changed));
  const result = run(tree), output = result.stdout + result.stderr;
  fs.writeFileSync(path.join(evidence, name + '.log'), output);
  if (result.error) throw result.error;
  const caught = result.status > 0 && output.includes('AssertionError') &&
    !output.includes('SyntaxError') && !output.includes('Unmocked dependency');
  survived ||= !caught;
  console.log(name + ': ' + (caught ? 'CAUGHT' : 'SURVIVED'));
}
console.log('Evidence: ' + evidence);
process.exitCode = survived ? 1 : 0;
