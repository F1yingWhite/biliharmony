#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}

const outputPath = resolve(args.get('--out') || 'api/bilibili-web-bfs-discovery.json');
const maxDepth = Number(args.get('--depth') || 1);
const maxPages = Number(args.get('--max-pages') || 36);
const maxAssets = Number(args.get('--max-assets') || 90);
const maxAssetDepth = Number(args.get('--asset-depth') || 1);
const delayMs = Number(args.get('--delay-ms') || 180);
const maxHtmlBytes = 2 * 1024 * 1024;
const maxAssetBytes = 8 * 1024 * 1024;
const userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Safari/537.36';

const seeds = [
  'https://www.bilibili.com/',
  'https://www.bilibili.com/v/popular/all',
  'https://www.bilibili.com/v/popular/rank/all',
  'https://www.bilibili.com/anime/',
  'https://www.bilibili.com/bangumi/play/ep3409896',
  'https://www.bilibili.com/cheese/play/ss24605',
  'https://www.bilibili.com/c/douga/',
  'https://search.bilibili.com/all?keyword=%E9%B8%BF%E8%92%99',
  'https://t.bilibili.com/',
  'https://space.bilibili.com/58463695',
  'https://live.bilibili.com/',
  'https://live.bilibili.com/nepgear',
  'https://message.bilibili.com/',
  'https://www.bilibili.com/account/history',
  'https://www.bilibili.com/watchlater/'
];

const allowedPageHosts = new Set([
  'www.bilibili.com',
  'search.bilibili.com',
  'space.bilibili.com',
  't.bilibili.com',
  'live.bilibili.com',
  'message.bilibili.com'
]);

const endpointPrefixes = [
  'x', 'pgc', 'pugv', 'room', 'xlive', 'live_user', 'av', 'session_svr',
  'account', 'svr_sync', 'web_im', 'dynamic_draft', 'dynamic_svr',
  'link_setting', 'twirp'
];
const endpointPattern = new RegExp('/(?:' + endpointPrefixes.join('|') + ')/[A-Za-z0-9_./-]+', 'g');
const excludedAssetPattern = /(?:polyfill|log-reporter|bili-collect|fallback|biliMirror|Captcha|svga|minntaki|auto-append-spmid)/i;

const wait = ms => new Promise(resolvePromise => setTimeout(resolvePromise, ms));
const sha256 = value => createHash('sha256').update(value).digest('hex');

function normalizePageUrl(input, base) {
  try {
    const url = new URL(input.replaceAll('&amp;', '&'), base);
    if (!allowedPageHosts.has(url.hostname)) return null;
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    url.hash = '';
    for (const key of [...url.searchParams.keys()]) {
      if (/^(spm|spm_id_from|from_spmid|vd_source|track_id|timestamp)$/i.test(key)) {
        url.searchParams.delete(key);
      }
    }
    return url.href;
  } catch {
    return null;
  }
}

function routeKey(input) {
  const url = new URL(input);
  const path = url.pathname.replace(/\/+$/, '') || '/';
  if (url.hostname === 'space.bilibili.com') return 'space:profile';
  if (url.hostname === 'search.bilibili.com') return 'search:' + path.split('/').slice(0, 2).join('/');
  if (url.hostname === 'message.bilibili.com') return 'message:' + path.split('/').slice(0, 2).join('/');
  if (url.hostname === 'live.bilibili.com') return path === '/' ? 'live:home' : 'live:room';
  if (/^\/video\//.test(path)) return 'www:video';
  if (/^\/bangumi\/play\//.test(path)) return 'www:bangumi-play';
  if (/^\/cheese\/play\//.test(path)) return 'www:cheese-play';
  if (/^\/opus\//.test(path)) return 'www:opus';
  if (/^\/read\//.test(path)) return 'www:read';
  return url.hostname + ':' + path.split('/').slice(0, 3).join('/');
}

function extractLinks(html, base) {
  const links = [];
  const pattern = /\bhref\s*=\s*["']([^"']+)["']/gi;
  for (const match of html.matchAll(pattern)) {
    const normalized = normalizePageUrl(match[1], base);
    if (normalized) links.push(normalized);
  }
  return [...new Set(links)];
}

function extractAssets(html, base) {
  const assets = [];
  const pattern = /<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>/gi;
  for (const match of html.matchAll(pattern)) {
    try {
      const url = new URL(match[1].replaceAll('&amp;', '&'), base);
      const firstParty = url.hostname.endsWith('.hdslb.com') || url.hostname.endsWith('.bilibili.com');
      if (!firstParty || !/\.m?js(?:$|\?)/i.test(url.href) || excludedAssetPattern.test(url.href)) continue;
      assets.push(url.href);
    } catch {
      // Ignore malformed script URLs emitted by template placeholders.
    }
  }
  return [...new Set(assets)];
}

function extractImportedAssets(source, base) {
  const assets = [];
  const pattern = /(?:(?:https?:)?\/\/[^"'`\s]+\.m?js(?:\?[^"'`\s]*)?|(?:\.{0,2}\/|\/)[A-Za-z0-9_./%~-]+\.m?js(?:\?[^"'`\s]*)?)/gi;
  for (const match of source.matchAll(pattern)) {
    try {
      const url = new URL(match[0], base);
      const firstParty = url.hostname.endsWith('.hdslb.com') || url.hostname.endsWith('.bilibili.com');
      if (!firstParty || excludedAssetPattern.test(url.href)) continue;
      assets.push(url.href);
    } catch {
      // Ignore runtime templates and incomplete chunk names.
    }
  }
  return [...new Set(assets)];
}

function endpointHost(source, path, context) {
  const nearby = context.match(/(?:https?:)?\/\/([a-z0-9.-]*bilibili\.com)[^"']*$/i);
  if (nearby) return nearby[1];
  if (/^\/(?:room|xlive|live_user|av)\//.test(path) || source.includes('live.bilibili.com')) {
    return 'api.live.bilibili.com';
  }
  if (/^\/(?:session_svr|account|svr_sync|web_im|link_setting)\//.test(path)) {
    return 'api.vc.bilibili.com';
  }
  return 'api.bilibili.com';
}

function endpointMethod(text, start, end) {
  const before = text.slice(Math.max(0, start - 220), start);
  const after = text.slice(end, Math.min(text.length, end + 260));
  const context = before + after;
  const explicit = context.match(/method\s*:\s*["'](GET|POST|PUT|DELETE)["']/i);
  if (explicit) return explicit[1].toUpperCase();
  if (/\.post\s*\([^)]*$/i.test(before)) return 'POST';
  if (/\.get\s*\([^)]*$/i.test(before)) return 'GET';
  return 'UNKNOWN';
}

function extractEndpoints(text, source) {
  const endpoints = [];
  for (const match of text.matchAll(endpointPattern)) {
    const path = match[0].replace(/\/+$/, '');
    if (!path || path.length > 180 || path.split('/').some(part => part.length > 64)) continue;
    const context = text.slice(Math.max(0, match.index - 260), match.index);
    endpoints.push({
      host: endpointHost(source, path, context),
      path,
      method: endpointMethod(text, match.index, match.index + match[0].length)
    });
  }
  return endpoints;
}

async function fetchText(url, maxBytes) {
  await wait(delayMs);
  const response = await fetch(url, {
    redirect: 'follow',
    headers: { 'User-Agent': userAgent, 'Accept': 'text/html,application/javascript,*/*' },
    signal: AbortSignal.timeout(30000)
  });
  const length = Number(response.headers.get('content-length') || 0);
  if (length > maxBytes) throw new Error('content-length exceeds limit: ' + length);
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > maxBytes) throw new Error('body exceeds limit: ' + buffer.length);
  return {
    finalUrl: response.url,
    status: response.status,
    contentType: response.headers.get('content-type') || '',
    buffer,
    text: buffer.toString('utf8')
  };
}

async function loadKnownPaths() {
  const known = new Set();
  try {
    const catalog = JSON.parse(await readFile('api/bilibili-web-endpoints.json', 'utf8'));
    for (const endpoint of catalog.endpoints || []) known.add(endpoint.path);
  } catch {
    // The initial catalog is optional when the crawler is reused elsewhere.
  }
  try {
    const constants = await readFile('entry/src/main/ets/common/Constants.ets', 'utf8');
    for (const match of constants.matchAll(/['"](\/(?:x|pgc|room|xlive)\/[^'"]+)['"]/g)) {
      known.add(match[1]);
    }
  } catch {
    // The project constants are optional when the crawler is reused elsewhere.
  }
  return known;
}

const knownPaths = await loadKnownPaths();
const queue = seeds.map(url => ({ url, depth: 0, seeded: true }));
const seenUrls = new Set();
const seenRoutes = new Set();
const seenAssets = new Set();
const assetQueue = [];
const pages = [];
const assets = [];
const failures = [];
const endpointMap = new Map();

while (queue.length > 0 && pages.length < maxPages) {
  const item = queue.shift();
  const normalized = normalizePageUrl(item.url, item.url);
  if (!normalized || seenUrls.has(normalized)) continue;
  const key = routeKey(normalized);
  if (!item.seeded && seenRoutes.has(key)) continue;
  seenUrls.add(normalized);
  seenRoutes.add(key);

  try {
    const result = await fetchText(normalized, maxHtmlBytes);
    const page = {
      requested_url: normalized,
      final_url: result.finalUrl,
      depth: item.depth,
      status: result.status,
      content_type: result.contentType,
      bytes: result.buffer.length,
      sha256: sha256(result.buffer),
      route_key: key
    };
    pages.push(page);
    if (!result.contentType.includes('text/html')) continue;

    for (const endpoint of extractEndpoints(result.text, result.finalUrl)) {
      const endpointKey = endpoint.host + endpoint.path;
      if (!endpointMap.has(endpointKey)) endpointMap.set(endpointKey, { ...endpoint, sources: new Set() });
      endpointMap.get(endpointKey).sources.add(result.finalUrl);
    }

    for (const asset of extractAssets(result.text, result.finalUrl)) {
      if (!seenAssets.has(asset) && seenAssets.size < maxAssets) {
        seenAssets.add(asset);
        assetQueue.push({ url: asset, depth: 0 });
      }
    }

    if (item.depth < maxDepth) {
      for (const link of extractLinks(result.text, result.finalUrl)) {
        if (!seenUrls.has(link)) queue.push({ url: link, depth: item.depth + 1, seeded: false });
      }
    }
  } catch (error) {
    failures.push({ type: 'page', url: normalized, error: String(error.message || error) });
  }
}

while (assetQueue.length > 0 && assets.length < maxAssets) {
  const item = assetQueue.shift();
  const url = item.url;
  try {
    const result = await fetchText(url, maxAssetBytes);
    const asset = {
      requested_url: url,
      final_url: result.finalUrl,
      status: result.status,
      content_type: result.contentType,
      bytes: result.buffer.length,
      sha256: sha256(result.buffer),
      depth: item.depth
    };
    assets.push(asset);
    if (!result.contentType.includes('javascript') && !/\.m?js(?:$|\?)/i.test(result.finalUrl)) continue;
    for (const endpoint of extractEndpoints(result.text, result.finalUrl)) {
      const endpointKey = endpoint.host + endpoint.path;
      if (!endpointMap.has(endpointKey)) endpointMap.set(endpointKey, { ...endpoint, sources: new Set() });
      const stored = endpointMap.get(endpointKey);
      stored.sources.add(result.finalUrl);
      if (stored.method === 'UNKNOWN' && endpoint.method !== 'UNKNOWN') stored.method = endpoint.method;
    }
    if (item.depth < maxAssetDepth) {
      for (const imported of extractImportedAssets(result.text, result.finalUrl)) {
        if (!seenAssets.has(imported) && seenAssets.size < maxAssets) {
          seenAssets.add(imported);
          assetQueue.push({ url: imported, depth: item.depth + 1 });
        }
      }
    }
  } catch (error) {
    failures.push({ type: 'asset', url, error: String(error.message || error) });
  }
}

const discovered = [...endpointMap.values()]
  .map(endpoint => ({
    host_hint: endpoint.host,
    path: endpoint.path,
    method_hint: endpoint.method,
    already_known: knownPaths.has(endpoint.path),
    sources: [...endpoint.sources].sort()
  }))
  .sort((left, right) =>
    (left.host_hint + left.path).localeCompare(right.host_hint + right.path));

const output = {
  generated_at: new Date().toISOString(),
  policy: {
    max_depth: maxDepth,
    max_pages: maxPages,
    max_assets: maxAssets,
    max_asset_depth: maxAssetDepth,
    delay_ms: delayMs,
    authenticated: false,
    request_methods_sent: ['GET']
  },
  summary: {
    pages_fetched: pages.length,
    assets_fetched: assets.length,
    endpoints_seen: discovered.length,
    endpoints_new: discovered.filter(endpoint => !endpoint.already_known).length,
    failures: failures.length
  },
  caveat: 'host_hint and method_hint are heuristic extraction results; inspect source context before integration.',
  pages,
  assets,
  endpoints: discovered,
  failures
};

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, JSON.stringify(output, null, 2) + '\n', 'utf8');
process.stdout.write(JSON.stringify(output.summary) + '\n');
