const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const http = require('node:http');
const {spawn, spawnSync} = require('node:child_process');

const mpv = process.env.QA_MPV || 'mpv';
const ffmpeg = process.env.QA_FFMPEG || 'ffmpeg';
const available = process.platform !== 'win32' && [mpv, ffmpeg].every(command =>
  spawnSync(command, ['-version'], {stdio: 'ignore'}).status === 0);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function until(check, message, timeout = 2500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await delay(20);
  }
  throw new Error(message);
}

function ipcClient(socket, events) {
  let sequence = 0, input = '';
  const pending = new Map();
  socket.on('data', bytes => {
    input += bytes;
    for (let newline; (newline = input.indexOf('\n')) >= 0;) {
      const message = JSON.parse(input.slice(0, newline));
      input = input.slice(newline + 1);
      if (message.event) events.push(message);
      const request = pending.get(message.request_id);
      if (!request) continue;
      pending.delete(message.request_id);
      clearTimeout(request.timer);
      if (message.error === 'success') request.resolve(message.data);
      else request.reject(new Error(`mpv: ${message.error}`));
    }
  });
  socket.on('error', error => {
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    pending.clear();
  });
  return command => new Promise((resolve, reject) => {
    const request_id = ++sequence;
    const timer = setTimeout(() => {
      pending.delete(request_id);
      reject(new Error(`mpv IPC timed out: ${command[0]}`));
    }, 2000);
    pending.set(request_id, {resolve, reject, timer});
    socket.write(JSON.stringify({command, request_id}) + '\n');
  });
}

test('host mpv decodes separate HTTP audio/video with seek, pause, speed, EOF and audio fallback',
  {skip: available ? false : 'macOS/Linux host mpv and ffmpeg are required; set QA_MPV/QA_FFMPEG', timeout: 16000}, async t => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'bili-mpv-'));
    const videoFile = path.join(directory, 'video.mp4');
    const audioFile = path.join(directory, 'audio.m4a');
    const generated = spawnSync(ffmpeg, ['-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=30',
      '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000',
      '-map', '0:v', '-t', '3', '-c:v', 'libx264', '-preset', 'ultrafast',
      '-pix_fmt', 'yuv420p', '-bf', '0', '-g', '30', '-movflags', '+faststart', videoFile,
      '-map', '1:a', '-t', '3', '-c:a', 'aac', '-b:a', '64000', '-movflags', '+faststart', audioFile],
    {encoding: 'utf8', timeout: 5000});
    assert.equal(generated.status, 0, generated.stderr);
    const fixtures = new Map([['/video.mp4', fs.readFileSync(videoFile)],
      ['/audio.m4a', fs.readFileSync(audioFile)]]);
    const requests = [], events = [];
    const userAgent = 'BiliHarmony-mpv-integration/1.0';
    const referer = 'https://www.bilibili.com/';
    const upstream = http.createServer((request, response) => {
      const route = new URL(request.url, 'http://127.0.0.1').pathname;
      const bytes = fixtures.get(route);
      const observed = {route, url: request.url, method: request.method, headers: request.headers};
      requests.push(observed);
      response.on('finish', () => {observed.status = response.statusCode;});
      if (!bytes) {response.writeHead(404); response.end(); return;}
      if (request.headers['user-agent'] !== userAgent || request.headers.referer !== referer) {
        response.writeHead(403); response.end(); return;
      }
      const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range || '');
      const start = range ? Number(range[1]) : 0;
      const end = range && range[2] ? Math.min(Number(range[2]), bytes.length - 1) : bytes.length - 1;
      if (start >= bytes.length || end < start) {
        response.writeHead(416, {'Content-Range': `bytes */${bytes.length}`}); response.end(); return;
      }
      const headers = {'Content-Length': String(end - start + 1), 'Accept-Ranges': 'bytes',
        'Content-Type': route === '/video.mp4' ? 'video/mp4' : 'audio/mp4'};
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${bytes.length}`;
      response.writeHead(range ? 206 : 200, headers);
      if (request.method === 'HEAD') response.end(); else response.end(bytes.subarray(start, end + 1));
    });
    let child, socket, command;
    t.after(async () => {
      if (child && child.exitCode === null && command) await command(['quit']).catch(() => {});
      socket?.destroy();
      if (child && child.exitCode === null) {
        child.kill();
        await Promise.race([new Promise(resolve => child.once('close', resolve)), delay(500)]);
        if (child.exitCode === null) child.kill('SIGKILL');
      }
      upstream.closeAllConnections();
      await new Promise(resolve => upstream.close(resolve));
      fs.rmSync(directory, {recursive: true, force: true});
    });
    await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${upstream.address().port}`;
    const socketPath = path.join(directory, 'mpv.sock');
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/proxy/i.test(key)));
    let stderr = '', processError;
    child = spawn(mpv, ['--no-config', '--no-terminal', '--idle=yes', '--pause=yes', '--keep-open=yes',
      '--vo=null', '--ao=null', '--hwdec=no', '--cache=yes', '--demuxer-readahead-secs=1',
      `--input-ipc-server=${socketPath}`],
    {env, stdio: ['ignore', 'ignore', 'pipe']});
    child.stderr.on('data', bytes => {stderr += bytes;});
    child.on('error', error => {processError = error;});
    await until(() => {
      if (processError) throw processError;
      if (child.exitCode !== null) throw new Error(`mpv exit ${child.exitCode}: ${stderr}`);
      return fs.existsSync(socketPath);
    }, 'mpv did not create an IPC socket');
    socket = net.createConnection(socketPath);
    await new Promise((resolve, reject) => {socket.once('connect', resolve); socket.once('error', reject);});
    command = ipcClient(socket, events);
    const property = name => command(['get_property', name]);
    // Node arrays match the production NAPI bridge's MPV_FORMAT_NODE_ARRAY values.
    // They preserve URL commas/colons without mpv option-list string escaping.
    await command(['set_property', 'user-agent', userAgent]);
    await command(['set_property', 'http-header-fields', [`Referer: ${referer}`]]);
    const signedQuery = '?token=fixture,colon:value';
    await command(['set_property', 'audio-files', [`${base}/audio.m4a${signedQuery}`]]);
    await command(['loadfile', `${base}/video.mp4${signedQuery}`, 'replace', -1]);
    await until(() => events.some(event => event.event === 'file-loaded'), `media did not load: ${stderr}`);
    const tracks = await property('track-list');
    assert.equal(tracks.length, 2, 'one mpv session must contain exactly two tracks');
    assert.deepEqual(tracks.map(track => track.type).sort(), ['audio', 'video']);
    assert.equal(tracks.find(track => track.type === 'audio').external, true);
    assert.ok(tracks.every(track => track.selected), 'both tracks are selected in the same session');
    assert.match(await property('video-codec'), /h\.?264/i);
    assert.match(await property('audio-codec'), /aac/i);
    assert.ok(Math.abs((await property('duration')) - 3) < 0.05);
    assert.equal(await property('pause'), true);

    await command(['seek', 1.2, 'absolute+exact']);
    await until(async () => !(await property('seeking')) &&
      Math.abs((await property('time-pos')) - 1.2) < 0.08, 'exact paused seek did not settle at 1.2 s');
    const paused = await property('time-pos');
    await delay(120);
    assert.ok(Math.abs((await property('time-pos')) - paused) < 0.03, 'paused core clock must remain still');
    await command(['set_property', 'pause', false]);
    await until(async () => (await property('time-pos')) > paused + 0.15, 'shared playback clock did not advance');
    await command(['set_property', 'pause', true]);
    await command(['set_property', 'speed', 1.5]);
    assert.equal(await property('speed'), 1.5);
    await command(['seek', 0.3, 'absolute+exact']);
    await until(async () => !(await property('seeking')) &&
      Math.abs((await property('time-pos')) - 0.3) < 0.08, 'second exact seek did not settle');
    const speedStart = await property('time-pos');
    await command(['set_property', 'pause', false]);
    await delay(240);
    assert.ok((await property('time-pos')) > speedStart + 0.27, '1.5x playback must advance faster than wall time');
    assert.ok(Math.abs(await property('avsync')) < 0.15, 'the host core must keep its decoded tracks aligned');
    await until(async () => await property('eof-reached'), 'mpv did not reach EOF', 4000);
    await until(async () => await property('pause'), 'keep-open did not pause the same core at EOF');
    for (const route of fixtures.keys()) {
      const trackRequests = requests.filter(request => request.route === route);
      assert.ok(trackRequests.length > 0, `${route} must be fetched by the core`);
      assert.ok(trackRequests.some(request => /^bytes=\d+-\d*$/.test(request.headers.range || '')),
        `${route} must use native HTTP byte-range access`);
      assert.ok(trackRequests.every(request => request.headers['user-agent'] === userAgent &&
        request.headers.referer === referer), 'headers must reach both media tracks directly');
      assert.ok(trackRequests.every(request => request.url === route + signedQuery),
        'signed URL punctuation must survive native array options unchanged');
    }
    t.diagnostic(`Host mpv: two selected tracks, native HTTP requests=${requests.length}; headless software decode only.`);

    // A failed external audio URL is optional to mpv: FILE_LOADED can still succeed
    // with only the video selected. The production bridge must inspect track-list
    // before accepting this load so the session can retry its next audio CDN.
    const sameProcess = child.pid;
    const failedAudioURL = `${base}/missing-audio.m4a${signedQuery}`;
    let loadEventsStart = events.length;
    await command(['set_property', 'audio-files', [failedAudioURL]]);
    await command(['loadfile', `${base}/video.mp4${signedQuery}`, 'replace', -1]);
    await until(() => events.slice(loadEventsStart).some(event => event.event === 'file-loaded'),
      'main video did not load when its external audio returned 404');
    const silentTracks = await property('track-list');
    assert.deepEqual(silentTracks.map(track => track.type), ['video']);
    assert.equal(silentTracks[0].selected, true, 'main video remains selected despite failed audio');
    assert.equal(silentTracks.some(track => track.type === 'audio' && track.external && track.selected), false,
      'FILE_LOADED alone must not acknowledge a required external audio track');
    assert.ok(requests.some(request => request.route === '/missing-audio.m4a' && request.status === 404),
      'the missing audio must really fail over HTTP');
    await command(['set_property', 'pause', false]);
    await until(async () => (await property('time-pos')) > 0.2,
      'mpv did not demonstrate video-only playback after its external audio failed');
    await command(['set_property', 'pause', true]);
    assert.equal(events.slice(loadEventsStart).some(event => event.event === 'end-file' && event.reason === 'error'),
      false, 'missing external audio does not produce a main-file error');
    assert.match(await property('video-codec'), /h\.?264/i);

    fixtures.set('/audio-backup.m4a', fixtures.get('/audio.m4a'));
    loadEventsStart = events.length;
    await command(['set_property', 'audio-files', [`${base}/audio-backup.m4a${signedQuery}`]]);
    await command(['loadfile', `${base}/video.mp4${signedQuery}`, 'replace', -1]);
    await until(() => events.slice(loadEventsStart).some(event => event.event === 'file-loaded'),
      'backup audio did not load with the main video');
    const recoveredTracks = await property('track-list');
    assert.equal(child.pid, sameProcess, 'audio fallback reuses the same native mpv process');
    assert.equal(recoveredTracks.length, 2);
    assert.ok(recoveredTracks.some(track => track.type === 'video' && track.selected));
    assert.ok(recoveredTracks.some(track => track.type === 'audio' && track.external && track.selected),
      'the replacement external audio must be selected before playback is accepted');
    assert.match(await property('audio-codec'), /aac/i);
    const backupRequests = requests.filter(request => request.route === '/audio-backup.m4a');
    assert.ok(backupRequests.some(request => request.status === 206), 'backup audio uses native HTTP Range access');
    assert.ok(backupRequests.every(request => request.url === '/audio-backup.m4a' + signedQuery &&
      request.headers['user-agent'] === userAgent && request.headers.referer === referer));
    await command(['set_property', 'pause', false]);
    await until(async () => (await property('time-pos')) > 0.2, 'recovered video/audio clock did not advance');
    assert.ok(Math.abs(await property('avsync')) < 0.15, 'recovered decoded tracks must share the native clock');
    t.diagnostic('Host mpv: HTTP 404 external audio still emits FILE_LOADED without a main-file error; selected external track validation detects it, and a backup URL restores both decoded tracks in the same core.');
    t.diagnostic('This proves the host mpv core and split-stream protocol; OHOS NAPI, surfaces, hardware decode and device A/V alignment remain device acceptance items.');
  });
