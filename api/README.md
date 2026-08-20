# Bilibili Web API inventory

Capture date: 2026-08-20 (Asia/Shanghai)

This directory records web endpoints that were present in Bilibili's first-party
web applications but did not have an exact path entry in
`entry/src/main/ets/common/Constants.ets` at capture time.

## Scope and evidence

Pages inspected:

- Home: `https://www.bilibili.com/`
- Popular and ranking: `https://www.bilibili.com/v/popular/all` and
  `https://www.bilibili.com/v/popular/rank/all`
- Anime and bangumi playback: `https://www.bilibili.com/anime/` and
  `https://www.bilibili.com/bangumi/play/ep3409896`
- Courses: `https://www.bilibili.com/cheese/play/ss24605`
- Channel: `https://www.bilibili.com/c/douga/`
- Video: `https://www.bilibili.com/video/BV1688E68ExC/`
- Search: `https://search.bilibili.com/all?keyword=%E9%B8%BF%E8%92%99`
- Dynamic feed: `https://t.bilibili.com/`
- User space: `https://space.bilibili.com/58463695`
- Live home and room: `https://live.bilibili.com/` and
  `https://live.bilibili.com/nepgear`
- Message center: `https://message.bilibili.com/`
- History and watch later: `https://www.bilibili.com/account/history` and
  `https://www.bilibili.com/watchlater/`

The curated catalog currently contains 109 reviewed endpoints. Of those, 26
returned business `code: 0` in a public, unauthenticated probe. Paths already
present in `Constants.ets` are intentionally excluded.

Evidence levels used in `bilibili-web-endpoints.json`:

- `runtime_public_200`: the first-party bundle supplied the method and parameters,
  and a separate request without account cookies returned HTTP JSON with business
  `code: 0` on the capture date.
- `runtime_public_business_error`: the endpoint returned JSON, but the public
  request produced an expected business error or content-specific empty result.
- `source_static`: method and parameters were recovered from the current
  first-party web bundle. It was not invoked because it needs login state, CSRF,
  WBI signing, a page cursor, or a destructive action.

Every curated endpoint also has a Chinese `function` field describing its
page-level purpose. This description does not relax the adjacent `auth` and
`evidence` constraints.

Chrome was connected, but claiming/navigating its tab timed out repeatedly. This
capture therefore does not claim to contain DevTools request headers, POST bodies
observed at runtime, or authenticated response samples. The endpoint catalog is
based on downloaded first-party HTML/JavaScript plus read-only public GET probes.

No Cookie, `SESSDATA`, `bili_jct`, access key, WBI key, browser fingerprint, or
account-specific response data is stored here.

## BFS discovery

`bilibili-web-bfs-discovery.json` is the raw discovery snapshot produced by
`bilibili_web_api_bfs.mjs`. The crawler performs bounded, delayed,
read-only GET requests. It traverses distinct page routes, their first-party
scripts, and one level of scripts imported by those assets.

The 2026-08-20 snapshot fetched 36 pages and 120 assets, found 533 distinct
endpoint-shaped paths, and recorded no fetch failures. After comparison with the
curated catalog and `Constants.ets`, 370 remain as unreviewed candidates.

Reproduce the snapshot from the repository root:

```sh
node api/bilibili_web_api_bfs.mjs \
  --out api/bilibili-web-bfs-discovery.json \
  --depth 1 --max-pages 36 --max-assets 120 --asset-depth 1 --delay-ms 180
```

The raw file is an investigation index, not an integration contract.
`host_hint` and `method_hint` are heuristic, and many strings can belong to
deprecated, experimental, or unrelated code paths. Only endpoints whose bundle
context and request shape were manually checked are copied into the curated
catalog.

## Source artifacts

The downloaded artifacts were kept only in `/tmp` during inspection. Their URLs
and SHA-256 hashes make the extraction reproducible while those deployments remain
available.

| Page | First-party asset | SHA-256 |
| --- | --- | --- |
| Home | `//s1.hdslb.com/bfs/static/shanks/laputa-home/assets/index-37875958.js` | `7ffefc5309f5572c2e13d08613d2be2d3e51c7ea1acba2fd47254d0df3a07a2b` |
| Video | `//s1.hdslb.com/bfs/static/jinkela/video/video.e29038f1bb50098abd67d1e2e8bd5615a04676e7.js` | `ef2872a568270837007dc640bf7852ef7e6242004d5f6dd8139bd9b629c06f3b` |
| Search | `//s1.hdslb.com/bfs/static/shanks/laputa-search/assets/index-27be0acf.js` | `875d912840e64b9610722bb52f6158948b2c9aef48d670c71cd6c3ef90eae6d4` |
| Dynamic | `//s1.hdslb.com/bfs/static/2233-monorepo/dyn-home/static/js/index.4aad8e90.js` | `d89e8f3278db73a710cf1f401d4228b3878a6c97ffaa8da1d464b68fdd87043d` |
| Space | `//s1.hdslb.com/bfs/static/shanks/fresh-space/assets/index-287f1be0.js` | `41360e31dfad1f103695de6e05dfb59f9dc709548498faef7ed680cc422d0f1b` |
| Live | `//s1.hdslb.com/bfs/static/fenice/home/client/home/assets/App.b149bcf2.js` | `f08ed5f3d702b233fe5af581ecaa38e20cabb70d7ccdc6267ee8e25fe1d11f61` |

## Integration guidance

Recommended first additions to BiliHaromny:

1. Video: `view/detail/part`, `note/is_forbid`, and `player/videoshot` are
   public, verified, and map cleanly to chapter, note-entry, and preview-frame UI.
2. Dynamic: `feed/hot`, `feed/all/update`, `detail/forward`, `detail/pic`, and
   `mention/search` fill visible gaps in the current dynamic experience.
3. Space: `space/setting`, `space/navnum`, `space/masterpiece`, reservation, and
   seasons/series endpoints are public and useful for feature-complete profiles.
4. Live: the current home API can be complemented by navigation, hot-rank, hover,
   pendant, and home-config endpoints.

Before adding a write endpoint, capture one real request in DevTools and verify
where CSRF is inserted (`query` versus form body), its `Content-Type`, required
`Origin`/`Referer`, and the full success/error contract. Do not implement writes
from the static catalog alone.
