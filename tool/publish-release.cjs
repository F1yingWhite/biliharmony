#!/usr/bin/env node
// Publish one immutable app version after CI has uploaded its build artifact.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');

const root = path.resolve(__dirname, '..');
const out = path.join(root, 'entry/build/default/outputs/default');
const publishDirectory = path.join(out, 'publish');
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

function run(command, args, allowFailure = false) {
  const result = spawnSync(command, args, {cwd: root, encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024});
  if (!allowFailure && (result.error || result.status !== 0)) {
    throw new Error(`${command} ${args[0]} failed: ${result.error?.message || result.stderr.trim() || result.status}`);
  }
  return result;
}

function api(endpoint, paginate = false) {
  const args = ['api', endpoint];
  if (paginate) args.push('--paginate', '--slurp');
  const data = JSON.parse(run('gh', args).stdout);
  return paginate ? data.flat() : data;
}

function report(message, warning = false) {
  console.log(`${warning ? '::warning::' : ''}${message}`);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${message}\n\n`);
}

function versionOf(tag) {
  if (typeof tag !== 'string' || !tag.startsWith('v')) return null;
  return semver.test(tag.slice(1)) ? tag.slice(1).split('.').map(part => BigInt(part)) : null;
}

function compareVersions(left, right) {
  for (let i = 0; i < 3; i++) {
    if (left[i] !== right[i]) return left[i] > right[i] ? 1 : -1;
  }
  return 0;
}

function appVersion() {
  const manifest = fs.readFileSync(path.join(root, 'AppScope/app.json5'), 'utf8');
  // Accept JSON5 comments while retaining quoted strings; versionName must be
  // a single explicit stable semver, never a branch, moving tag or shell input.
  const withoutComments = manifest.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
    token => token.startsWith('//') || token.startsWith('/*') ? '' : token);
  const versions = [...withoutComments.matchAll(/["']versionName["']\s*:\s*["']([^"']+)["']/g)];
  if (versions.length !== 1 || !semver.test(versions[0][1])) throw new Error('AppScope/app.json5 versionName must be one stable X.Y.Z version.');
  return versions[0][1];
}

function prepareArtifact(version) {
  fs.mkdirSync(publishDirectory, {recursive: true});
  const filename = `biliharmony-v${version}-unsigned.hap`;
  const bytes = fs.readFileSync(path.join(out, 'entry-default-unsigned.hap'));
  fs.writeFileSync(path.join(publishDirectory, filename), bytes);
  const hash = crypto.createHash('sha256').update(bytes).digest('hex');
  fs.writeFileSync(path.join(publishDirectory, 'hap.sha256'), `${hash}  ${filename}\n`);
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `tag=v${version}\n`);
  return [filename, 'hap.sha256'];
}

function publish() {
  const version = appVersion();
  const filenames = prepareArtifact(version);
  const tag = `v${version}`;
  const repository = process.env.GITHUB_REPOSITORY;
  const requestedCommit = process.env.GITHUB_SHA;
  if (!repository || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) throw new Error('GITHUB_REPOSITORY is required.');
  if (!requestedCommit || !/^[0-9a-f]{40}$/.test(requestedCommit)) throw new Error('GITHUB_SHA must be the exact build commit.');
  const commit = run('git', ['rev-parse', '--verify', 'HEAD^{commit}']).stdout.trim();
  if (commit !== requestedCommit) throw new Error('The checked-out commit differs from the built GITHUB_SHA.');

  const releases = api(`repos/${repository}/releases?per_page=100`, true);
  const refs = api(`repos/${repository}/git/matching-refs/tags/${tag}`);
  const ref = refs.find(item => item.ref === `refs/tags/${tag}`);
  let taggedCommit;
  if (ref) {
    let object = ref.object;
    // Annotated tags must be resolved to the commit, not their tag-object SHA.
    for (let depth = 0; object.type === 'tag' && depth < 8; depth++) {
      object = api(`repos/${repository}/git/tags/${object.sha}`).object;
    }
    if (object.type !== 'commit' || !/^[0-9a-f]{40}$/.test(object.sha)) throw new Error(`${tag} does not resolve to a commit.`);
    taggedCommit = object.sha;
  }
  const existing = releases.find(item => item.tag_name === tag);
  if (existing) {
    if (!taggedCommit || existing.draft) throw new Error(`${tag} has an incomplete Release; inspect it without overwriting history.`);
    const assets = new Set((existing.assets || []).map(asset => asset.name));
    if (!filenames.every(filename => assets.has(filename))) {
      throw new Error(`${tag} is missing release assets; this run keeps its CI artifact and will not overwrite the Release.`);
    }
    if (taggedCommit === commit) report(`${tag} at ${commit.slice(0, 7)} is already published; this rerun leaves its tag, notes and assets unchanged.`);
    else report(`${tag} is already published at ${taggedCommit.slice(0, 7)}. This commit is available as a CI artifact; increase AppScope/app.json5 versionName for a new Release.`, true);
    return;
  }
  if (taggedCommit) {
    const detail = taggedCommit === commit ? 'already exists without a Release' : `points to ${taggedCommit.slice(0, 7)}, not this build ${commit.slice(0, 7)}`;
    throw new Error(`${tag} ${detail}; an existing tag is never reused or moved. Inspect it or increase versionName.`);
  }
  const newer = releases.find(item => !item.draft && !item.prerelease && versionOf(item.tag_name) &&
    compareVersions(versionOf(item.tag_name), versionOf(tag)) >= 0);
  if (newer) throw new Error(`versionName ${version} must advance beyond published stable ${newer.tag_name}; latest cannot be downgraded.`);

  let previous = '';
  const candidates = releases.filter(item => !item.draft && !item.prerelease && versionOf(item.tag_name) &&
    compareVersions(versionOf(item.tag_name), versionOf(tag)) < 0)
    .sort((left, right) => compareVersions(versionOf(right.tag_name), versionOf(left.tag_name)));
  for (const candidate of candidates) {
    const resolved = run('git', ['rev-parse', '--verify', `refs/tags/${candidate.tag_name}^{commit}`], true);
    if (resolved.status !== 0) throw new Error(`Published release ${candidate.tag_name} has no local tag; fetch complete history before publishing.`);
    const ancestor = run('git', ['merge-base', '--is-ancestor', resolved.stdout.trim(), commit], true);
    if (ancestor.status === 0) { previous = candidate.tag_name; break; }
    if (ancestor.status !== 1) throw new Error(`Cannot verify the history of ${candidate.tag_name}.`);
  }
  const notesFile = path.join(root, 'release_notes.md');
  const notes = run('bash', ['tool/release-notes.sh', previous, commit, version]).stdout;
  fs.writeFileSync(notesFile, notes);
  // Create the exact tag first: gh release create --target alone would silently
  // use a tag created by another actor between our check and publication.
  // POST rejects an existing ref instead of moving it or reusing different code.
  run('gh', ['api', `repos/${repository}/git/refs`, '-X', 'POST',
    '-f', `ref=refs/tags/${tag}`, '-f', `sha=${commit}`]);
  // No edit, upload --clobber, tag PATCH or forced Git push is permitted here.
  // The workflow serializes main runs; GitHub rejects duplicate creation.
  run('gh', ['release', 'create', tag, '--repo', repository, '--target', commit,
    '--verify-tag', '--title', `BiliHarmony ${tag}`, '--latest', '--notes-file', notesFile,
    ...filenames.map(filename => path.join(publishDirectory, filename))]);
  report(`Published BiliHarmony ${tag} at ${commit.slice(0, 7)}. Previous numbered release: ${previous || 'first release'}.`);
}

try {
  if (process.argv[2] === '--prepare-artifact') {
    const version = appVersion();
    prepareArtifact(version);
    console.log(`Prepared biliharmony-v${version}-unsigned.hap and hap.sha256.`);
  } else if (process.argv.length === 2) publish();
  else throw new Error('Usage: node tool/publish-release.cjs [--prepare-artifact]');
} catch (error) { console.error(`::error::${error.message}`); process.exitCode = 1; }
