/**
 * 数据模型：视频、评论、用户、动态、搜索等
 * 字段映射移植自 PiliPlus lib/models
 */
import { asObject, asString, asNumber, asArray, asBool, str, num, formatCount, toHttps } from '../common/Utils';

// ===== 视频卡片项（统一 app 推荐 / 热门 / 搜索结果） =====
export class VideoItem {
  aid: number = 0;
  bvid: string = '';
  cid: number = 0;
  title: string = '';
  cover: string = '';
  upName: string = '';
  upMid: number = 0;
  upFace: string = '';
  play: number = 0;
  danmaku: number = 0;
  like: number = 0;
  reply: number = 0;
  favorite: number = 0;
  coin: number = 0;
  share: number = 0;
  duration: number = 0;
  tname: string = '';
  pubdate: number = 0;
  desc: string = '';
  rcmdReason: string = '';
  videos: number = 0;
  playText: string = '';
  danmakuText: string = '';

  static fromAppItem(o: Object): VideoItem {
    const item: Record<string, Object> = asObject(o);
    const args: Record<string, Object> = asObject(item['args']);
    const playerArgs: Record<string, Object> = asObject(item['player_args']);
    const v: VideoItem = new VideoItem();
    v.aid = asNumber(playerArgs['aid'], asNumber(item['param'], 0));
    v.bvid = str(item, 'bvid', '');
    v.cid = asNumber(playerArgs['cid'], 0);
    v.title = str(item, 'title', '');
    v.cover = toHttps(str(item, 'cover', ''));
    v.duration = asNumber(playerArgs['duration'], 0);
    v.upName = str(args, 'up_name', '');
    v.upMid = asNumber(args['up_id'], 0);
    v.tname = str(args, 'tname', '');
    v.rcmdReason = str(item, 'rcmd_reason', '');
    v.desc = str(item, 'desc', '');
    v.playText = str(item, 'cover_left_text_1', '');
    v.danmakuText = str(item, 'cover_left_text_2', '');
    v.play = parseCountString(v.playText);
    v.danmaku = parseCountString(v.danmakuText);
    // 注意：app 端推荐接口只返回 aid（无 bvid），详情页以 aid 查询
    return v;
  }

  static fromHotItem(o: Object): VideoItem {
    const item: Record<string, Object> = asObject(o);
    const owner: Record<string, Object> = asObject(item['owner']);
    const stat: Record<string, Object> = asObject(item['stat']);
    const v: VideoItem = new VideoItem();
    v.aid = asNumber(item['aid'], 0);
    v.bvid = str(item, 'bvid', '');
    v.cid = asNumber(item['cid'], 0);
    v.title = str(item, 'title', '');
    v.cover = toHttps(str(item, 'pic', ''));
    v.duration = asNumber(item['duration'], 0);
    v.pubdate = asNumber(item['pubdate'], 0);
    v.tname = str(item, 'tname', '');
    v.desc = str(item, 'desc', '');
    v.videos = asNumber(item['videos'], 0);
    v.upName = str(owner, 'name', '');
    v.upMid = asNumber(owner['mid'], 0);
    v.upFace = toHttps(str(owner, 'face', ''));
    v.play = asNumber(stat['view'], 0);
    v.danmaku = asNumber(stat['danmaku'], 0);
    v.like = asNumber(stat['like'], 0);
    v.reply = asNumber(stat['reply'], 0);
    v.favorite = asNumber(stat['favorite'], 0);
    v.coin = asNumber(stat['coin'], 0);
    v.share = asNumber(stat['share'], 0);
    v.playText = formatCount(v.play);
    v.danmakuText = formatCount(v.danmaku);
    return v;
  }

  /** Web 首页个性化推荐卡片（x/web-interface/wbi/index/top/feed/rcmd）。 */
  static fromWebRecommendItem(o: Object): VideoItem {
    const item: Record<string, Object> = asObject(o);
    const owner: Record<string, Object> = asObject(item['owner']);
    const stat: Record<string, Object> = asObject(item['stat']);
    const reason: Record<string, Object> = asObject(item['rcmd_reason']);
    const v: VideoItem = new VideoItem();
    v.aid = asNumber(item['id'], asNumber(item['aid'], 0));
    v.bvid = str(item, 'bvid', '');
    v.cid = asNumber(item['cid'], 0);
    v.title = str(item, 'title', '');
    v.cover = toHttps(str(item, 'pic', ''));
    v.duration = asNumber(item['duration'], 0);
    v.pubdate = asNumber(item['pubdate'], 0);
    v.tname = str(item, 'tname', '');
    v.upName = str(owner, 'name', '');
    v.upMid = asNumber(owner['mid'], 0);
    v.upFace = toHttps(str(owner, 'face', ''));
    v.play = asNumber(stat['view'], 0);
    v.danmaku = asNumber(stat['danmaku'], 0);
    v.like = asNumber(stat['like'], 0);
    v.reply = asNumber(stat['reply'], 0);
    v.rcmdReason = str(reason, 'content', '');
    v.playText = formatCount(v.play);
    v.danmakuText = formatCount(v.danmaku);
    return v;
  }

  static fromSearchItem(o: Object): VideoItem {
    const item: Record<string, Object> = asObject(o);
    const v: VideoItem = new VideoItem();
    v.aid = asNumber(item['aid'], 0);
    v.bvid = str(item, 'bvid', '');
    v.title = str(item, 'title', '');
    // 搜索结果的标题里可能包含高亮 <em> 标签，去除
    v.title = v.title.replace(/<[^>]*>/g, '');
    v.cover = toHttps(str(item, 'pic', ''));
    v.duration = parseDurationText(str(item, 'duration', ''));
    v.pubdate = asNumber(item['pubdate'], 0);
    v.desc = str(item, 'description', '');
    v.play = asNumber(item['play'], 0);
    v.danmaku = asNumber(item['video_review'], 0);
    v.upName = str(item, 'author', '');
    v.upMid = asNumber(item['mid'], 0);
    v.playText = formatCount(v.play);
    v.danmakuText = formatCount(v.danmaku);
    return v;
  }

  // 用户空间投稿（x/space/wbi/arc/search 的 vlist 项，duration 为 "mm:ss" 字符串 length 字段）
  static fromSpaceItem(o: Object): VideoItem {
    const item: Record<string, Object> = asObject(o);
    const v: VideoItem = new VideoItem();
    v.aid = asNumber(item['aid'], 0);
    v.bvid = str(item, 'bvid', '');
    v.title = str(item, 'title', '');
    v.cover = toHttps(str(item, 'pic', ''));
    v.duration = parseDurationText(str(item, 'length', ''));
    v.pubdate = asNumber(item['created'], 0);
    v.desc = str(item, 'description', '');
    v.play = asNumber(item['play'], 0);
    v.danmaku = asNumber(item['video_review'], 0);
    v.upName = str(item, 'author', '');
    v.upMid = asNumber(item['mid'], 0);
    v.playText = formatCount(v.play);
    v.danmakuText = formatCount(v.danmaku);
    return v;
  }
}

// 解析 "10.2万" / "1.3亿" / "1234" 为数字
function parseCountString(s: string): number {
  if (s.length === 0) {
    return 0;
  }
  if (s.indexOf('亿') >= 0) {
    const n: number = Number(s.substring(0, s.length - 1));
    return Number.isNaN(n) ? 0 : Math.floor(n * 100000000);
  }
  if (s.indexOf('万') >= 0) {
    const n: number = Number(s.substring(0, s.length - 1));
    return Number.isNaN(n) ? 0 : Math.floor(n * 10000);
  }
  const n: number = Number(s);
  return Number.isNaN(n) ? 0 : n;
}

// 解析 "12:34" / "1:02:03" 为秒数
function parseDurationText(s: string): number {
  if (s.length === 0) {
    return 0;
  }
  const parts: Array<string> = s.split(':');
  if (parts.length === 3) {
    return Number(parts[0]) * 3600 + Number(parts[1]) * 60 + Number(parts[2]);
  }
  if (parts.length === 2) {
    return Number(parts[0]) * 60 + Number(parts[1]);
  }
  return 0;
}

// ===== 视频详情 =====
export class VideoPage {
  cid: number = 0;
  page: number = 0;
  part: string = '';
  duration: number = 0;
  width: number = 0;
  height: number = 0;
  rotate: number = 0;

  static from(o: Object): VideoPage {
    const j: Record<string, Object> = asObject(o);
    const p: VideoPage = new VideoPage();
    p.cid = asNumber(j['cid'], 0);
    p.page = asNumber(j['page'], 0);
    p.part = str(j, 'part', '');
    p.duration = asNumber(j['duration'], 0);
    const dimension: Record<string, Object> = asObject(j['dimension']);
    p.width = asNumber(dimension['width'], 0);
    p.height = asNumber(dimension['height'], 0);
    p.rotate = asNumber(dimension['rotate'], 0);
    return p;
  }
}

// ===== UGC 合集（view 接口的 ugc_season 字段，与 PiliPlus UgcSeason 对齐） =====
export class UgcSeasonEpisode {
  id: number = 0;
  aid: number = 0;
  cid: number = 0;
  bvid: string = '';
  title: string = '';
  cover: string = '';
  badge: string = '';
  /** 由页面展开合集列表时填充，不在 API 返回中。 */
  sectionTitle: string = '';

  static from(o: Object): UgcSeasonEpisode {
    const j: Record<string, Object> = asObject(o);
    const e: UgcSeasonEpisode = new UgcSeasonEpisode();
    e.id = asNumber(j['id'], 0);
    e.aid = asNumber(j['aid'], 0);
    e.cid = asNumber(j['cid'], 0);
    e.bvid = str(j, 'bvid', '');
    e.title = str(j, 'title', '');
    e.cover = toHttps(str(j, 'cover', ''));
    const arc: Record<string, Object> = asObject(j['arc']);
    if (e.cover.length === 0) e.cover = toHttps(str(arc, 'pic', ''));
    if (e.aid <= 0) e.aid = asNumber(arc['aid'], 0);
    if (e.bvid.length === 0) e.bvid = str(arc, 'bvid', '');
    e.badge = str(j, 'badge', '');
    return e;
  }
}

export class UgcSeasonSection {
  seasonId: number = 0;
  id: number = 0;
  title: string = '';
  type: number = 0;
  episodes: Array<UgcSeasonEpisode> = [];

  static from(o: Object): UgcSeasonSection {
    const j: Record<string, Object> = asObject(o);
    const s: UgcSeasonSection = new UgcSeasonSection();
    s.seasonId = asNumber(j['season_id'], 0);
    s.id = asNumber(j['id'], 0);
    s.title = str(j, 'title', '');
    s.type = asNumber(j['type'], 0);
    const eps: Array<Object> = asArray(j['episodes']);
    for (let i: number = 0; i < eps.length; i++) {
      const ep: UgcSeasonEpisode = UgcSeasonEpisode.from(eps[i]);
      if (ep.aid > 0 || ep.bvid.length > 0) s.episodes.push(ep);
    }
    return s;
  }
}

export class UgcSeason {
  id: number = 0;
  title: string = '';
  cover: string = '';
  mid: number = 0;
  sections: Array<UgcSeasonSection> = [];

  static from(o: Object): UgcSeason {
    const j: Record<string, Object> = asObject(o);
    const u: UgcSeason = new UgcSeason();
    u.id = asNumber(j['id'], 0);
    u.title = str(j, 'title', '');
    u.cover = toHttps(str(j, 'cover', ''));
    u.mid = asNumber(j['mid'], 0);
    const sections: Array<Object> = asArray(j['sections']);
    for (let i: number = 0; i < sections.length; i++) {
      u.sections.push(UgcSeasonSection.from(sections[i]));
    }
    return u;
  }
}

export class VideoDetail {
  aid: number = 0;
  bvid: string = '';
  cid: number = 0;
  title: string = '';
  desc: string = '';
  cover: string = '';
  tname: string = '';
  pubdate: number = 0;
  duration: number = 0;
  width: number = 0;
  height: number = 0;
  rotate: number = 0;
  upMid: number = 0;
  upName: string = '';
  upFace: string = '';
  upSign: string = '';
  view: number = 0;
  danmaku: number = 0;
  like: number = 0;
  coin: number = 0;
  favorite: number = 0;
  share: number = 0;
  reply: number = 0;
  pages: Array<VideoPage> = [];
  ugcSeason: UgcSeason | null = null;

  static from(o: Object): VideoDetail {
    const j: Record<string, Object> = asObject(o);
    const owner: Record<string, Object> = asObject(j['owner']);
    const stat: Record<string, Object> = asObject(j['stat']);
    const pagesArr: Array<Object> = asArray(j['pages']);
    const d: VideoDetail = new VideoDetail();
    d.aid = asNumber(j['aid'], 0);
    d.bvid = str(j, 'bvid', '');
    d.cid = asNumber(j['cid'], 0);
    d.title = str(j, 'title', '');
    d.desc = str(j, 'desc', '');
    d.cover = str(j, 'pic', '');
    d.tname = str(j, 'tname', '');
    d.pubdate = asNumber(j['pubdate'], 0);
    d.duration = asNumber(j['duration'], 0);
    const dimension: Record<string, Object> = asObject(j['dimension']);
    d.width = asNumber(dimension['width'], 0);
    d.height = asNumber(dimension['height'], 0);
    d.rotate = asNumber(dimension['rotate'], 0);
    d.upMid = asNumber(owner['mid'], 0);
    d.upName = str(owner, 'name', '');
    d.upFace = toHttps(str(owner, 'face', ''));
    d.upSign = str(j, 'sign', '');
    d.view = asNumber(stat['view'], 0);
    d.danmaku = asNumber(stat['danmaku'], 0);
    d.like = asNumber(stat['like'], 0);
    d.coin = asNumber(stat['coin'], 0);
    d.favorite = asNumber(stat['favorite'], 0);
    d.share = asNumber(stat['share'], 0);
    d.reply = asNumber(stat['reply'], 0);
    for (let i: number = 0; i < pagesArr.length; i++) {
      d.pages.push(VideoPage.from(pagesArr[i]));
    }
    const ugcSeasonObj: Record<string, Object> = asObject(j['ugc_season']);
    if (Object.keys(ugcSeasonObj).length > 0) {
      d.ugcSeason = UgcSeason.from(ugcSeasonObj);
    }
    // 少数稿件只在分 P 中返回画面尺寸，优先用当前 cid，否则取第一 P。
    if ((d.width <= 0 || d.height <= 0) && d.pages.length > 0) {
      let selected: VideoPage = d.pages[0];
      for (let i: number = 0; i < d.pages.length; i++) {
        if (d.pages[i].cid === d.cid) selected = d.pages[i];
      }
      d.width = selected.width;
      d.height = selected.height;
      d.rotate = selected.rotate;
    }
    return d;
  }
}

// ===== 播放地址 =====
/** CC 字幕轨（playurl 的 subtitle.subtitles 项） */
export class SubtitleTrack {
  lan: string = '';
  lanDoc: string = '';
  url: string = '';

  static from(o: Object): SubtitleTrack {
    const j: Record<string, Object> = asObject(o);
    const t: SubtitleTrack = new SubtitleTrack();
    t.lan = str(j, 'lan', '');
    t.lanDoc = str(j, 'lan_doc', '');
    t.url = toHttps(str(j, 'subtitle_url', ''));
    return t;
  }
}

/** CC 字幕单条内容（B 站 subtitle_url 返回 JSON 的 body 项） */
export class SubtitleCue {
  from: number = 0;
  to: number = 0;
  content: string = '';

  static from(o: Object): SubtitleCue {
    const j: Record<string, Object> = asObject(o);
    const c: SubtitleCue = new SubtitleCue();
    c.from = asNumber(j['from'], 0);
    c.to = asNumber(j['to'], 0);
    c.content = str(j, 'content', '');
    return c;
  }
}

export class PlayUrlInfo {
  url: string = '';
  urls: Array<string> = [];
  audioUrl: string = '';
  audioUrls: Array<string> = [];
  isDash: boolean = false;
  quality: number = 0;
  format: string = '';
  /** 上次观看到达的毫秒数（web 播放地址协议 last_play_time，0 表示无历史进度）。 */
  lastPlayTime: number = 0;
  /** 上次观看的分 P cid（0 表示无记录；用于多 P 视频续播定位）。 */
  lastPlayCid: number = 0;
  qualities: Array<VideoQualityOption> = [];
  subtitles: Array<SubtitleTrack> = [];

  static fromPlayUrl(o: Object, requestedQuality: number = 127): PlayUrlInfo {
    const j: Record<string, Object> = asObject(o);
    const durl: Array<Object> = asArray(j['durl']);
    const dash: Record<string, Object> = asObject(j['dash']);
    const dashVideo: Array<Object> = asArray(dash['video']);
    const dashAudio: Array<Object> = asArray(dash['audio']);
    const info: PlayUrlInfo = new PlayUrlInfo();
    info.quality = asNumber(j['quality'], 0);
    info.format = str(j, 'format', '');
    info.lastPlayTime = asNumber(j['last_play_time'], 0);
    info.lastPlayCid = asNumber(j['last_play_cid'], 0);
    const subtitleWrap: Record<string, Object> = asObject(j['subtitle']);
    const subtitleList: Array<Object> = asArray(subtitleWrap['subtitles']);
    for (let i: number = 0; i < subtitleList.length; i++) {
      const track: SubtitleTrack = SubtitleTrack.from(subtitleList[i]);
      if (track.url.length > 0 && info.subtitles.findIndex((s: SubtitleTrack) => s.lan === track.lan) < 0) {
        info.subtitles.push(track);
      }
    }
    const acceptQuality: Array<Object> = asArray(j['accept_quality']);
    const acceptDescription: Array<Object> = asArray(j['accept_description']);
    const supportFormats: Array<Object> = asArray(j['support_formats']);
    if (dashVideo.length > 0) {
      info.isDash = true;
      info.format = 'dash';
      const available: Array<number> = [];
      for (let i: number = 0; i < dashVideo.length; i++) {
        const item: Record<string, Object> = asObject(dashVideo[i]);
        const id: number = asNumber(item['id'], 0);
        if (id > 0 && available.indexOf(id) < 0) available.push(id);
      }
      available.sort((a: number, b: number) => b - a);
      let selectedQuality: number = available.length > 0 ? available[0] : info.quality;
      for (let i: number = 0; i < available.length; i++) {
        if (available[i] <= requestedQuality) {
          selectedQuality = available[i];
          break;
        }
      }
      info.quality = selectedQuality;

      // 对齐 PiliPlus：support_formats 全部展示，未返回实际 DASH 轨的会员画质标灰并说明原因。
      if (supportFormats.length > 0) {
        for (let i: number = 0; i < supportFormats.length; i++) {
          const formatItem: Record<string, Object> = asObject(supportFormats[i]);
          const qn: number = asNumber(formatItem['quality'], 0);
          if (qn <= 0) continue;
          const description: string = str(formatItem, 'new_description', str(formatItem, 'display_desc', ''));
          info.qualities.push(new VideoQualityOption(qn, qualityShortName(qn, description), available.indexOf(qn) >= 0));
        }
      } else {
        for (let i: number = 0; i < acceptQuality.length; i++) {
          const qn: number = asNumber(acceptQuality[i], 0);
          if (qn <= 0) continue;
          const description: string = i < acceptDescription.length ? asString(acceptDescription[i], '') : '';
          info.qualities.push(new VideoQualityOption(qn, qualityShortName(qn, description), available.indexOf(qn) >= 0));
        }
      }

      // 同画质优先 AVC（兼容最好），其次 HEVC，最后 AV1；CDN 仍按可用性排序并保留后备。
      let selectedVideo: Record<string, Object> = {};
      let selectedCodecScore: number = -1;
      for (let i: number = 0; i < dashVideo.length; i++) {
        const item: Record<string, Object> = asObject(dashVideo[i]);
        if (asNumber(item['id'], 0) !== selectedQuality) continue;
        const codec: string = str(item, 'codecs', '');
        const score: number = codec.startsWith('avc1') ? 3 :
          ((codec.startsWith('hev') || codec.startsWith('hvc')) ? 2 : 1);
        if (score > selectedCodecScore) {
          selectedVideo = item;
          selectedCodecScore = score;
        }
      }
      info.urls = dashItemUrls(selectedVideo);
      info.url = info.urls.length > 0 ? info.urls[0] : '';

      let selectedAudio: Record<string, Object> = {};
      let maxAudioBandwidth: number = -1;
      for (let i: number = 0; i < dashAudio.length; i++) {
        const item: Record<string, Object> = asObject(dashAudio[i]);
        const bandwidth: number = asNumber(item['bandwidth'], 0);
        if (bandwidth > maxAudioBandwidth) {
          selectedAudio = item;
          maxAudioBandwidth = bandwidth;
        }
      }
      info.audioUrls = dashItemUrls(selectedAudio);
      info.audioUrl = info.audioUrls.length > 0 ? info.audioUrls[0] : '';
    } else if (durl.length > 0) {
      const first: Record<string, Object> = asObject(durl[0]);
      const candidates: Array<string> = [];
      const primary: string = toHttps(str(first, 'url', ''));
      if (primary.length > 0) {
        candidates.push(primary);
      }
      const backups: Array<Object> = asArray(first['backup_url']);
      for (let i: number = 0; i < backups.length; i++) {
        const backup: string = toHttps(asString(backups[i], ''));
        if (backup.length > 0 && candidates.indexOf(backup) < 0) {
          candidates.push(backup);
        }
      }
      // 对齐 PiliPlus 的 CDN 选路思路：优先 upgcxcode 镜像，把 mcdn/akamaized 放到后备。
      candidates.sort((a: string, b: string) => cdnScore(b) - cdnScore(a));
      info.urls = candidates;
      info.url = candidates.length > 0 ? candidates[0] : '';
    }

    if (info.qualities.length === 0) {
      for (let i: number = 0; i < acceptQuality.length; i++) {
        const qn: number = asNumber(acceptQuality[i], 0);
        if (qn > 0) {
          const description: string = i < acceptDescription.length ? asString(acceptDescription[i], '') : '';
          info.qualities.push(new VideoQualityOption(qn, qualityShortName(qn, description)));
        }
      }
    }
    return info;
  }
}

function dashItemUrls(item: Record<string, Object>): Array<string> {
  const candidates: Array<string> = [];
  const primary: string = toHttps(str(item, 'base_url', str(item, 'baseUrl', '')));
  if (primary.length > 0) candidates.push(primary);
  const backups: Array<Object> = asArray(item['backup_url'] ?? item['backupUrl']);
  for (let i: number = 0; i < backups.length; i++) {
    const backup: string = toHttps(asString(backups[i], ''));
    if (backup.length > 0 && candidates.indexOf(backup) < 0) candidates.push(backup);
  }
  candidates.sort((a: string, b: string) => cdnScore(b) - cdnScore(a));
  return candidates;
}

export class VideoQualityOption {
  qn: number = 0;
  label: string = '';
  available: boolean = true;

  constructor(qn: number, label: string, available: boolean = true) {
    this.qn = qn;
    this.label = label;
    this.available = available;
  }
}

function qualityShortName(qn: number, description: string): string {
  if (qn === 129) return 'HDR Vivid';
  if (qn === 127) return '8K';
  if (qn === 126) return '杜比视界';
  if (qn === 125) return 'HDR';
  if (qn === 120) return '4K';
  if (qn === 116) return '1080P60';
  if (qn === 112) return '1080P+';
  if (qn === 80) return '1080P';
  if (qn === 74) return '720P60';
  if (qn === 64) return '720P';
  if (qn === 32) return '480P';
  if (qn === 16) return '360P';
  if (qn === 6) return '240P';
  return description.length > 0 ? description : String(qn);
}

function cdnScore(url: string): number {
  let score: number = 0;
  if (url.startsWith('https://')) {
    score += 2;
  }
  if (url.indexOf('/upgcxcode/') >= 0) {
    score += 4;
  }
  if (url.indexOf('.bilivideo.com') >= 0) {
    score += 3;
  }
  if (url.indexOf('mcdn.') >= 0 || url.indexOf('akamaized.') >= 0) {
    score -= 6;
  }
  if (url.indexOf('szbdyd.com') >= 0) {
    score -= 3;
  }
  return score;
}

// ===== 视频互动状态 =====
export class VideoRelationState {
  liked: boolean = false;
  disliked: boolean = false;
  coin: number = 0;
  favorite: boolean = false;

  static from(o: Object): VideoRelationState {
    const j: Record<string, Object> = asObject(o);
    const state: VideoRelationState = new VideoRelationState();
    state.liked = asBool(j['like']);
    state.disliked = asBool(j['dislike']);
    state.coin = asNumber(j['coin'], 0);
    state.favorite = asBool(j['favorite']);
    return state;
  }
}

// ===== 历史记录 =====
export class HistoryVideoItem {
  video: VideoItem = new VideoItem();
  viewAt: number = 0;
  progress: number = 0;

  static from(o: Object): HistoryVideoItem {
    const j: Record<string, Object> = asObject(o);
    const history: Record<string, Object> = asObject(j['history']);
    const item: HistoryVideoItem = new HistoryVideoItem();
    item.video.aid = asNumber(history['oid'], 0);
    item.video.bvid = str(history, 'bvid', '');
    item.video.cid = asNumber(history['cid'], 0);
    item.video.title = str(j, 'title', '');
    item.video.cover = toHttps(str(j, 'cover', ''));
    item.video.upName = str(j, 'author_name', '');
    item.video.upMid = asNumber(j['author_mid'], 0);
    item.video.duration = asNumber(j['duration'], 0);
    item.progress = asNumber(j['progress'], 0);
    item.viewAt = asNumber(j['view_at'], 0);
    return item;
  }
}

export class HistoryPageData {
  items: Array<HistoryVideoItem> = [];
  max: number = 0;
  viewAt: number = 0;
  hasMore: boolean = false;
}

// ===== 稍后再看 =====
export class WatchLaterItem {
  video: VideoItem = new VideoItem();
  progress: number = 0;

  static from(o: Object): WatchLaterItem {
    const j: Record<string, Object> = asObject(o);
    const owner: Record<string, Object> = asObject(j['owner']);
    const stat: Record<string, Object> = asObject(j['stat']);
    const item: WatchLaterItem = new WatchLaterItem();
    item.video.aid = asNumber(j['aid'], 0);
    item.video.bvid = str(j, 'bvid', '');
    item.video.cid = asNumber(j['cid'], 0);
    item.video.title = str(j, 'title', '');
    item.video.cover = toHttps(str(j, 'pic', ''));
    item.video.upName = str(owner, 'name', '');
    item.video.upMid = asNumber(owner['mid'], 0);
    item.video.duration = asNumber(j['duration'], 0);
    item.video.pubdate = asNumber(j['pubdate'], 0);
    item.video.play = asNumber(stat['view'], 0);
    item.progress = asNumber(j['progress'], 0);
    return item;
  }
}

// ===== 收藏夹 =====
export class FavoriteFolderItem {
  id: number = 0;
  title: string = '';
  cover: string = '';
  count: number = 0;
  type: number = 0;          // 0 自建收藏夹 / 11 他人收藏夹 / 21 合集
  upperName: string = '';
  upperMid: number = 0;
  intro: string = '';
  viewCount: number = 0;
  isPublic: boolean = true;
  favorited: boolean = false;

  static from(o: Object): FavoriteFolderItem {
    const j: Record<string, Object> = asObject(o);
    const item: FavoriteFolderItem = new FavoriteFolderItem();
    item.id = asNumber(j['id'], 0);
    item.title = str(j, 'title', '');
    item.cover = toHttps(str(j, 'cover', ''));
    item.count = asNumber(j['media_count'], 0);
    item.type = asNumber(j['type'], 0);
    const upper: Record<string, Object> = asObject(j['upper']);
    item.upperName = str(upper, 'name', '');
    item.upperMid = asNumber(upper['mid'], 0);
    item.intro = str(j, 'intro', '');
    item.viewCount = asNumber(j['view_count'], 0);
    item.isPublic = asNumber(j['attr'], 0) !== 23 && asNumber(j['is_public'], 1) !== 0;
    item.favorited = asBool(j['fav_state']);
    return item;
  }
}

export class FavoriteFolderPageData {
  folders: Array<FavoriteFolderItem> = [];
  hasMore: boolean = false;
}

export class FavoriteVideoPageData {
  videos: Array<VideoItem> = [];
  hasMore: boolean = false;
}

// ===== B 站表情包 =====
export class BiliEmote {
  text: string = '';
  url: string = '';
  size: number = 1;

  static from(o: Object): BiliEmote {
    const j: Record<string, Object> = asObject(o);
    const item: BiliEmote = new BiliEmote();
    item.text = str(j, 'text', '');
    item.url = toHttps(str(j, 'url', str(j, 'webp_url', str(j, 'gif_url', str(j, 'icon_url', '')))));
    const meta: Record<string, Object> = asObject(j['meta']);
    item.size = Math.max(1, asNumber(meta['size'], asNumber(j['size'], 1)));
    return item;
  }
}

export class BiliEmotePackage {
  title: string = '';
  icon: string = '';
  emotes: Array<BiliEmote> = [];

  static from(o: Object): BiliEmotePackage {
    const j: Record<string, Object> = asObject(o);
    const pkg: BiliEmotePackage = new BiliEmotePackage();
    pkg.title = str(j, 'text', str(j, 'name', str(j, 'title', '表情')));
    pkg.icon = toHttps(str(j, 'url', ''));
    const list: Array<Object> = asArray(j['emote']);
    for (let i: number = 0; i < list.length; i++) {
      const emote: BiliEmote = BiliEmote.from(list[i]);
      if (emote.text.length > 0 && emote.url.length > 0) pkg.emotes.push(emote);
    }
    return pkg;
  }
}

// ===== 私信 =====
export class MessageSessionItem {
  talkerId: number = 0;
  name: string = '';
  avatar: string = '';
  preview: string = '';
  timestamp: number = 0;
  unread: number = 0;
  sessionTs: number = 0;

  static from(o: Object): MessageSessionItem {
    const j: Record<string, Object> = asObject(o);
    const account: Record<string, Object> = asObject(j['account_info']);
    const lastMsg: Record<string, Object> = asObject(j['last_msg']);
    const item: MessageSessionItem = new MessageSessionItem();
    item.talkerId = asNumber(j['talker_id'], 0);
    item.name = str(account, 'name', '');
    item.avatar = toHttps(str(account, 'pic_url', ''));
    item.preview = messageContentText(str(lastMsg, 'content', ''), asNumber(lastMsg['msg_type'], 1));
    item.timestamp = asNumber(lastMsg['timestamp'], 0);
    item.sessionTs = asNumber(j['session_ts'], 0);
    item.unread = asNumber(j['unread_count'], 0) + asNumber(j['biz_msg_unread_count'], 0);
    return item;
  }

  clone(): MessageSessionItem {
    const next: MessageSessionItem = new MessageSessionItem();
    next.talkerId = this.talkerId;
    next.name = this.name;
    next.avatar = this.avatar;
    next.preview = this.preview;
    next.timestamp = this.timestamp;
    next.unread = this.unread;
    next.sessionTs = this.sessionTs;
    return next;
  }
}

export class MessageSessionPageData {
  sessions: Array<MessageSessionItem> = [];
  hasMore: boolean = false;
  /** 加载失败原因（空串表示成功；用于 UI 呈现与区分"真的没私信"） */
  error: string = '';
}

export class PrivateMessageItem {
  senderId: number = 0;
  receiverId: number = 0;
  text: string = '';
  timestamp: number = 0;
  seqno: number = 0;
  type: number = 1;
  /** 富文本/视频推荐卡片字段；普通文本消息为空。 */
  richTitle: string = '';
  richCover: string = '';
  richUrl: string = '';
  richBvid: string = '';
  richAid: number = 0;
  richDesc: string = '';

  static from(o: Object): PrivateMessageItem {
    const j: Record<string, Object> = asObject(o);
    const item: PrivateMessageItem = new PrivateMessageItem();
    item.senderId = asNumber(j['sender_uid'], 0);
    item.receiverId = asNumber(j['receiver_id'], 0);
    item.type = asNumber(j['msg_type'], 1);
    const raw: string = str(j, 'content', '');
    item.text = messageContentText(raw, item.type);
    try {
      const content: Record<string, Object> = asObject(JSON.parse(raw) as Object);
      item.richTitle = str(content, 'title', str(content, 'content', ''));
      item.richCover = toHttps(str(content, 'cover', str(content, 'pic', '')));
      item.richUrl = str(content, 'url', '');
      item.richBvid = str(content, 'bvid', '');
      item.richAid = asNumber(content['aid'], 0);
      item.richDesc = str(content, 'description', str(content, 'desc', ''));
    } catch (e) {
      // 普通文本消息没有 JSON 富文本字段。
    }
    item.timestamp = asNumber(j['timestamp'], 0);
    item.seqno = asNumber(j['msg_seqno'], 0);
    return item;
  }
}

export class PrivateMessagePageData {
  messages: Array<PrivateMessageItem> = [];
  hasMore: boolean = false;
  minSeqno: number = 0;
  /** 加载失败原因；空串表示请求成功，避免失败被 UI 误判成空会话。 */
  error: string = '';
}

// ===== 消息通知（回复我的 / @我 / 收到的赞 / 系统通知），字段对齐 PiliPlus lib/models_new/msg =====
export class MsgNotifyItem {
  id: number = 0;
  /** 触发用户 mid；系统通知为 0 */
  mid: number = 0;
  nickname: string = '';
  avatar: string = '';
  /** 动作描述（如「 赞了我的视频」「 在评论中@了我」），紧跟昵称展示 */
  action: string = '';
  /** 通知正文：回复内容 / @ 内容 / 被赞内容标题 / 系统通知正文 */
  text: string = '';
  /** 来源内容摘要（被回复的评论 / 系统通知标题），列表中以引用样式展示 */
  source: string = '';
  timestamp: number = 0;
  /** 系统通知接口直接返回格式化时间文本，优先于 timestamp 展示 */
  timeText: string = '';
  /** 右侧缩略图（@我 / 收到的赞） */
  image: string = '';
  nativeUri: string = '';
  /** 从 nativeUri 解析出的视频目标；aid 与 bvid 均为空时点击不跳转 */
  aid: number = 0;
  bvid: string = '';
  /** 系统通知分页游标：纳秒级 int64，超出 number 精度按字符串保存 */
  sysCursor: string = '';

  static fromReply(o: Object): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const user: Record<string, Object> = asObject(j['user']);
    const item: Record<string, Object> = asObject(j['item']);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    out.mid = asNumber(user['mid'], 0);
    out.nickname = str(user, 'nickname', '');
    out.avatar = toHttps(str(user, 'avatar', ''));
    const counts: number = asNumber(j['counts'], 1);
    const multi: string = asNumber(j['is_multi'], 0) === 1 ? ' 等人' : '';
    out.action = multi + ' 对我的' + str(item, 'business', '内容') + '发布了' + String(counts) + '条评论';
    out.text = str(item, 'source_content', '');
    const target: string = str(item, 'target_reply_content', '');
    const root: string = str(item, 'root_reply_content', '');
    out.source = target.length > 0 ? target : root;
    out.timestamp = asNumber(j['reply_time'], 0);
    out.nativeUri = str(item, 'native_uri', '');
    fillNotifyVideoTarget(out);
    return out;
  }

  static fromAt(o: Object): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const user: Record<string, Object> = asObject(j['user']);
    const item: Record<string, Object> = asObject(j['item']);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    out.mid = asNumber(user['mid'], 0);
    out.nickname = str(user, 'nickname', '');
    out.avatar = toHttps(str(user, 'avatar', ''));
    out.action = ' 在' + str(item, 'business', '内容') + '中@了我';
    out.text = str(item, 'source_content', '');
    out.image = toHttps(str(item, 'image', ''));
    out.timestamp = asNumber(j['at_time'], 0);
    out.nativeUri = str(item, 'native_uri', '');
    fillNotifyVideoTarget(out);
    return out;
  }

  static fromLike(o: Object): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const item: Record<string, Object> = asObject(j['item']);
    const users: Array<Object> = asArray(j['users']);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    if (users.length > 0) {
      const first: Record<string, Object> = asObject(users[0]);
      out.mid = asNumber(first['mid'], 0);
      out.nickname = str(first, 'nickname', '');
      out.avatar = toHttps(str(first, 'avatar', ''));
    }
    const counts: number = asNumber(j['counts'], users.length);
    out.action = (counts > 1 ? ' 等' + String(counts) + '人' : '') + ' 赞了我的' + str(item, 'business', '内容');
    out.text = str(item, 'title', '');
    out.image = toHttps(str(item, 'image', ''));
    out.timestamp = asNumber(j['like_time'], 0);
    out.nativeUri = str(item, 'native_uri', '');
    fillNotifyVideoTarget(out);
    return out;
  }

  static fromSys(o: Object, cursor: string): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    out.nickname = '系统通知';
    out.source = str(j, 'title', '');
    let content: string = str(j, 'content', '');
    // content 可能是 JSON（{"web":"..."}），对齐 PiliPlus 取 web 字段。
    if (content.startsWith('{')) {
      try {
        content = str(asObject(JSON.parse(content) as Object), 'web', content);
      } catch (e) {
      }
    }
    out.text = content;
    out.timeText = str(j, 'time_at', '');
    out.sysCursor = cursor;
    return out;
  }
}

/** 从通知的 bilibili:// 原生链接解析视频目标，用于点击跳详情；解析不出则不跳。 */
function fillNotifyVideoTarget(item: MsgNotifyItem): void {
  if (item.nativeUri.length === 0) return;
  const bv: RegExpMatchArray | null = item.nativeUri.match(/BV[0-9A-Za-z]{10}/);
  if (bv !== null) {
    item.bvid = bv[0];
    return;
  }
  const av: RegExpMatchArray | null = item.nativeUri.match(/(?:video|av)\/(\d{3,})/);
  if (av !== null) item.aid = Number(av[1]);
}

export class MsgNotifyPageData {
  items: Array<MsgNotifyItem> = [];
  hasMore: boolean = false;
  /** cursor.id / time 为 int64，按字符串透传避免 JSON.parse 丢失精度 */
  cursorId: string = '';
  cursorTime: string = '';
  /** 系统通知下一页游标（纳秒字符串） */
  sysCursor: string = '';
  /** 加载失败原因；空串表示请求成功 */
  error: string = '';
}

/** 消息中心各分类未读数（/x/msgfeed/unread）。 */
export class MsgFeedUnread {
  reply: number = 0;
  at: number = 0;
  like: number = 0;
  sysMsg: number = 0;

  total(): number {
    return this.reply + this.at + this.like + this.sysMsg;
  }
}

function messageContentText(raw: string, type: number): string {
  if (raw.length === 0) return '';
  try {
    const content: Record<string, Object> = asObject(JSON.parse(raw) as Object);
    if (type === 1) return str(content, 'content', raw);
    if (type === 2) return '[图片]';
    if (type === 5) return '撤回了一条消息';
    return str(content, 'text', str(content, 'title', '[消息]'));
  } catch (e) {
    return raw;
  }
}

// ===== 评论 =====
export class ReplyJump {
  label: string = '';
  url: string = '';
}

/** 评论正文中的可跳转 @ 用户。 */
export class ReplyMention {
  label: string = '';
  mid: number = 0;
}

export class ReplyItem {
  rpid: number = 0;
  /** 评论所属对象 id（视频=aid，动态=comment_id） */
  oid: number = 0;
  /** 评论所属对象类型（视频=1，动态见 comment_type） */
  type: number = 1;
  rootRpid: number = 0;
  parentRpid: number = 0;
  dialogRpid: number = 0;
  mid: number = 0;
  uname: string = '';
  avatar: string = '';
  content: string = '';
  like: number = 0;
  liked: boolean = false;
  disliked: boolean = false;
  ctime: number = 0;
  count: number = 0;
  level: number = 0;
  location: string = '';
  pendant: string = '';
  nameplate: string = '';
  nameColor: string = '';
  cardBackground: string = '';
  cardNumberPrefix: string = 'NO.';
  cardNumber: string = '';
  cardNumberColor: string = '';
  emotes: Array<BiliEmote> = [];
  jumps: Array<ReplyJump> = [];
  mentions: Array<ReplyMention> = [];
  pictures: Array<string> = [];
  replies: Array<ReplyItem> = [];
  /** 本地修订号：乐观更新克隆时 +1，LazyForEach 键包含它才能让同 rpid 的卡片真正重渲染。 */
  rev: number = 0;

  /** 浅克隆：乐观更新后换对象引用，驱动 @Prop 子组件重新同步（同引用不会触发更新）。 */
  clone(): ReplyItem {
    const r: ReplyItem = new ReplyItem();
    r.rpid = this.rpid;
    r.oid = this.oid;
    r.type = this.type;
    r.rootRpid = this.rootRpid;
    r.parentRpid = this.parentRpid;
    r.dialogRpid = this.dialogRpid;
    r.mid = this.mid;
    r.uname = this.uname;
    r.avatar = this.avatar;
    r.content = this.content;
    r.like = this.like;
    r.liked = this.liked;
    r.disliked = this.disliked;
    r.ctime = this.ctime;
    r.count = this.count;
    r.level = this.level;
    r.location = this.location;
    r.pendant = this.pendant;
    r.nameplate = this.nameplate;
    r.nameColor = this.nameColor;
    r.cardBackground = this.cardBackground;
    r.cardNumberPrefix = this.cardNumberPrefix;
    r.cardNumber = this.cardNumber;
    r.cardNumberColor = this.cardNumberColor;
    r.emotes = this.emotes;
    r.jumps = this.jumps;
    r.mentions = this.mentions;
    r.pictures = this.pictures;
    r.replies = this.replies;
    r.rev = this.rev;
    return r;
  }

  static from(o: Object): ReplyItem {
    const j: Record<string, Object> = asObject(o);
    const member: Record<string, Object> = asObject(j['member']);
    const content: Record<string, Object> = asObject(j['content']);
    const r: ReplyItem = new ReplyItem();
    r.rpid = asNumber(j['rpid'], 0);
    r.oid = asNumber(j['oid'], 0);
    r.type = asNumber(j['type'], 1);
    r.rootRpid = asNumber(j['root'], 0);
    r.parentRpid = asNumber(j['parent'], 0);
    r.dialogRpid = asNumber(j['dialog'], 0);
    r.mid = asNumber(member['mid'], 0);
    r.uname = str(member, 'uname', '');
    r.avatar = toHttps(str(member, 'avatar', ''));
    r.content = str(content, 'message', '');
    r.like = asNumber(j['like'], 0);
    r.liked = asNumber(j['action'], 0) === 1;
    r.disliked = asNumber(j['action'], 0) === 2;
    r.ctime = asNumber(j['ctime'], 0);
    r.count = asNumber(j['count'], 0);
    const levelInfo: Record<string, Object> = asObject(member['level_info']);
    r.level = asNumber(levelInfo['current_level'], 0);
    const replyControl: Record<string, Object> = asObject(j['reply_control']);
    r.location = str(replyControl, 'location', '');
    const pendant: Record<string, Object> = asObject(member['pendant']);
    const sailingForPendant: Record<string, Object> = asObject(member['user_sailing']);
    const sailingPendant: Record<string, Object> = asObject(sailingForPendant['pendant']);
    r.pendant = toHttps(str(pendant, 'image_enhance', str(pendant, 'image',
      str(pendant, 'image_enhance_frame', str(sailingPendant, 'image_enhance', str(sailingPendant, 'image', ''))))));
    const nameplate: Record<string, Object> = asObject(member['nameplate']);
    r.nameplate = toHttps(str(nameplate, 'image_small', str(nameplate, 'image', '')));
    const vip: Record<string, Object> = asObject(member['vip']);
    r.nameColor = str(vip, 'nickname_color', '');
    // Web 新旧评论协议兼容：content.emote 是以“[表情名]”为 key 的对象。
    const emoteMap: Record<string, Object> = asObject(content['emote']);
    const emoteKeys: Array<string> = Object.keys(emoteMap);
    for (let i: number = 0; i < emoteKeys.length; i++) {
      const emote: BiliEmote = BiliEmote.from(emoteMap[emoteKeys[i]]);
      if (emote.text.length === 0) emote.text = emoteKeys[i];
      if (emote.url.length > 0) r.emotes.push(emote);
    }
    const jumpMap: Record<string, Object> = asObject(content['jump_url']);
    const jumpKeys: Array<string> = Object.keys(jumpMap);
    for (let i: number = 0; i < jumpKeys.length; i++) {
      const jumpObj: Record<string, Object> = asObject(jumpMap[jumpKeys[i]]);
      const jump: ReplyJump = new ReplyJump();
      jump.label = jumpKeys[i];
      jump.url = str(jumpObj, 'pc_url', str(jumpObj, 'app_url_schema', ''));
      if (jump.label.length > 0 && jump.url.length > 0) r.jumps.push(jump);
    }
    // 新旧评论接口分别可能返回 members 数组或 at_name_to_mid 映射；统一成
    // 带 UID 的文本片段，渲染层只让真实可解析的 @ 用户具有点击行为。
    const mentionMids: Set<number> = new Set<number>();
    const atNameMap: Record<string, Object> = asObject(content['at_name_to_mid']);
    const atNames: Array<string> = Object.keys(atNameMap);
    for (let i: number = 0; i < atNames.length; i++) {
      const mid: number = asNumber(atNameMap[atNames[i]], 0);
      if (mid <= 0 || mentionMids.has(mid)) continue;
      const mention: ReplyMention = new ReplyMention();
      mention.label = atNames[i].startsWith('@') ? atNames[i] : '@' + atNames[i];
      mention.mid = mid;
      r.mentions.push(mention);
      mentionMids.add(mid);
    }
    const members: Array<Object> = asArray(content['members']);
    for (let i: number = 0; i < members.length; i++) {
      const mentionMember: Record<string, Object> = asObject(members[i]);
      const mid: number = asNumber(mentionMember['mid'], 0);
      const uname: string = str(mentionMember, 'uname', '');
      if (mid <= 0 || uname.length === 0 || mentionMids.has(mid)) continue;
      const mention: ReplyMention = new ReplyMention();
      mention.label = '@' + uname;
      mention.mid = mid;
      r.mentions.push(mention);
      mentionMids.add(mid);
    }
    const pictures: Array<Object> = asArray(content['pictures']);
    for (let i: number = 0; i < pictures.length; i++) {
      const picture: Record<string, Object> = asObject(pictures[i]);
      const src: string = toHttps(str(picture, 'img_src', str(picture, 'url', '')));
      if (src.length > 0) r.pictures.push(src);
    }
    // 当前评论协议把装扮放在 member.user_sailing(_v2)；兼容早期字段。
    const memberV2: Record<string, Object> = asObject(j['member_v2']);
    const garb: Record<string, Object> = asObject(memberV2['garb']);
    const decoration: Record<string, Object> = asObject(member['decoration_card']);
    const sailing: Record<string, Object> = asObject(member['user_sailing']);
    const sailingV2: Record<string, Object> = asObject(member['user_sailing_v2']);
    const sailingCard: Record<string, Object> = asObject(sailing['cardbg']);
    const sailingCardWithFocus: Record<string, Object> = asObject(sailing['cardbg_with_focus']);
    const sailingCardV2: Record<string, Object> = asObject(sailingV2['card_bg']);
    const activeCard: Record<string, Object> = Object.keys(sailingCardV2).length > 0 ? sailingCardV2 :
      (Object.keys(sailingCardWithFocus).length > 0 ? sailingCardWithFocus : sailingCard);
    r.cardBackground = toHttps(str(activeCard, 'image',
      str(garb, 'card_image', str(decoration, 'card_url', ''))));
    const fan: Record<string, Object> = asObject(activeCard['fan']);
    r.cardNumberPrefix = str(fan, 'num_prefix', str(garb, 'card_number_prefix', 'NO.'));
    r.cardNumber = str(fan, 'num_desc', str(fan, 'num_str', str(garb, 'card_number', '')));
    r.cardNumberColor = str(fan, 'color', str(garb, 'card_fan_color', ''));
    const sub: Array<Object> = asArray(j['replies']);
    for (let i: number = 0; i < sub.length; i++) {
      r.replies.push(ReplyItem.from(sub[i]));
    }
    return r;
  }
}

export class ReplyPageData {
  replies: Array<ReplyItem> = [];
  hasMore: boolean = false;

  static from(o: Object): ReplyPageData {
    const j: Record<string, Object> = asObject(o);
    const result: ReplyPageData = new ReplyPageData();
    const replies: Array<Object> = asArray(j['replies']);
    for (let i: number = 0; i < replies.length; i++) {
      result.replies.push(ReplyItem.from(replies[i]));
    }
    const page: Record<string, Object> = asObject(j['page']);
    const count: number = asNumber(page['count'], result.replies.length);
    const num: number = asNumber(page['num'], 1);
    const size: number = asNumber(page['size'], 20);
    result.hasMore = num * size < count;
    return result;
  }
}

export class ReplyData {
  replies: Array<ReplyItem> = [];
  cursor: string = '';
  hasMore: boolean = true;

  static from(o: Object): ReplyData {
    const j: Record<string, Object> = asObject(o);
    const data: ReplyData = new ReplyData();
    const topArr: Array<Object> = asArray(j['top_replies']);
    const repliesArr: Array<Object> = asArray(j['replies']);
    for (let i: number = 0; i < topArr.length; i++) {
      data.replies.push(ReplyItem.from(topArr[i]));
    }
    for (let i: number = 0; i < repliesArr.length; i++) {
      data.replies.push(ReplyItem.from(repliesArr[i]));
    }
    const cursorObj: Record<string, Object> = asObject(j['cursor']);
    // 当前 /main 响应把 pagination_reply 放在 cursor 内；兼容少数旧响应的顶层位置。
    let paginationObj: Record<string, Object> = asObject(cursorObj['pagination_reply']);
    if (Object.keys(paginationObj).length === 0) {
      paginationObj = asObject(j['pagination_reply']);
    }
    // next_offset 是下一页必须原样回传的完整令牌，不能用 cursor.next 页码替代。
    const nextOffset: Object | undefined = paginationObj['next_offset'];
    if (typeof nextOffset === 'string') {
      data.cursor = nextOffset as string;
    } else if (nextOffset !== null && nextOffset !== undefined) {
      data.cursor = JSON.stringify(nextOffset);
    }
    if (data.cursor.length === 0) {
      const legacyNext: number = asNumber(cursorObj['next'], 0);
      data.cursor = legacyNext > 0 ? String(legacyNext) : '';
    }
    const isEnd: boolean = asBool(cursorObj['is_end'], false);
    data.hasMore = !isEnd && data.cursor.length > 0;
    return data;
  }

  static fromLegacy(o: Object, pageNumber: number): ReplyData {
    const data: ReplyData = ReplyData.from(o);
    const j: Record<string, Object> = asObject(o);
    const page: Record<string, Object> = asObject(j['page']);
    const count: number = asNumber(page['count'], data.replies.length);
    const size: number = Math.max(1, asNumber(page['size'], 20));
    data.hasMore = pageNumber * size < count;
    data.cursor = data.hasMore ? String(pageNumber + 1) : '';
    return data;
  }
}

// ===== 用户 =====
export class UserInfo {
  isLogin: boolean = false;
  mid: number = 0;
  uname: string = '';
  face: string = '';
  pendant: string = '';
  sign: string = '';
  level: number = 0;
  coins: number = 0;

  static fromNav(o: Object): UserInfo {
    const j: Record<string, Object> = asObject(o);
    const data: Record<string, Object> = asObject(j['data']);
    const u: UserInfo = new UserInfo();
    u.isLogin = asNumber(data['isLogin'], 0) === 1;
    u.mid = asNumber(data['mid'], 0);
    u.uname = str(data, 'uname', '');
    u.face = toHttps(str(data, 'face', ''));
    const navPendant: Record<string, Object> = asObject(data['pendant']);
    u.pendant = toHttps(str(navPendant, 'image_enhance', str(navPendant, 'image', '')));
    u.sign = str(data, 'sign', '');
    const levelInfo: Record<string, Object> = asObject(data['level_info']);
    u.level = asNumber(levelInfo['current_level'], 0);
    u.coins = asNumber(data['money'], 0);
    return u;
  }
}

export class UserStat {
  following: number = 0;
  follower: number = 0;
  likeNum: number = 0;

  static from(o: Object): UserStat {
    const j: Record<string, Object> = asObject(o);
    const data: Record<string, Object> = asObject(j['data']);
    const s: UserStat = new UserStat();
    s.following = asNumber(data['following'], 0);
    s.follower = asNumber(data['follower'], 0);
    s.likeNum = asNumber(data['like_num'], 0);
    return s;
  }
}

export class RelationUserItem {
  mid: number = 0;
  uname: string = '';
  face: string = '';
  sign: string = '';
  attribute: number = 0;
  special: boolean = false;

  static from(o: Object): RelationUserItem {
    const j: Record<string, Object> = asObject(o);
    const item: RelationUserItem = new RelationUserItem();
    item.mid = asNumber(j['mid'], 0);
    item.uname = str(j, 'uname', '');
    item.face = toHttps(str(j, 'face', ''));
    item.sign = str(j, 'sign', '');
    item.attribute = asNumber(j['attribute'], 0);
    item.special = asNumber(j['special'], 0) === 1;
    return item;
  }
}

export class RelationUserPageData {
  users: Array<RelationUserItem> = [];
  total: number = 0;
}

// ===== 动态 =====
export class DynamicItem {
  dynId: string = '';
  type: string = '';
  mid: number = 0;
  uname: string = '';
  face: string = '';
  content: string = '';
  title: string = '';
  cover: string = '';
  bvid: string = '';
  aid: number = 0;
  cid: number = 0;
  like: number = 0;
  liked: boolean = false;
  comment: number = 0;
  forward: number = 0;
  pubtime: number = 0;
  pendant: string = '';
  decorationCard: string = '';
  decorationNumber: string = '';
  decorationColor: string = '';
  majorType: string = '';
  badge: string = '';
  subtitle: string = '';
  images: Array<string> = [];
  emotes: Array<BiliEmote> = [];
  commentId: number = 0;
  commentType: number = 0;
  liveRoomId: number = 0;
  liveUid: number = 0;
  liveStatus: number = 0;
  /** PGC（番剧/影视）卡片的季 ID 与单集 ID；UGC 合集卡没有这两个字段，保持 0。 */
  seasonId: number = 0;
  epId: number = 0;
  original: DynamicItem | null = null;

  static from(o: Object): DynamicItem {
    const j: Record<string, Object> = asObject(o);
    const modules: Record<string, Object> = asObject(j['modules']);
    const author: Record<string, Object> = asObject(modules['module_author']);
    const stat: Record<string, Object> = asObject(modules['module_stat']);
    const dynamic: Record<string, Object> = asObject(modules['module_dynamic']);
    const d: DynamicItem = new DynamicItem();
    // 动态 ID 已超过 JS 安全整数范围，必须保留字符串，否则分页/去重会串卡。
    d.dynId = str(j, 'id_str', '');
    if (d.dynId.length === 0) d.dynId = String(asNumber(j['id'], 0));
    d.type = str(j, 'type', '');
    const basic: Record<string, Object> = asObject(j['basic']);
    d.commentId = Number(str(basic, 'comment_id_str', '0'));
    if (Number.isNaN(d.commentId)) d.commentId = 0;
    d.commentType = asNumber(basic['comment_type'], 0);
    d.mid = asNumber(author['mid'], 0);
    d.uname = str(author, 'name', '');
    d.face = toHttps(str(author, 'face', ''));
    const pendant: Record<string, Object> = asObject(author['pendant']);
    d.pendant = toHttps(str(pendant, 'image', ''));
    const decorate: Record<string, Object> = asObject(author['decorate']);
    const decorationCard: Record<string, Object> = Object.keys(decorate).length > 0 ? decorate : asObject(author['decoration_card']);
    d.decorationCard = toHttps(str(decorationCard, 'card_url', ''));
    const fan: Record<string, Object> = asObject(decorationCard['fan']);
    d.decorationNumber = str(fan, 'num_str', str(fan, 'num_desc', ''));
    d.decorationColor = str(fan, 'color', '');
    d.pubtime = asNumber(author['pub_ts'], 0);
    const likeStat: Record<string, Object> = asObject(stat['like']);
    const commentStat: Record<string, Object> = asObject(stat['comment']);
    const forwardStat: Record<string, Object> = asObject(stat['forward']);
    d.like = asNumber(likeStat['count'], asNumber(stat['like'], 0));
    d.liked = asBool(likeStat['status'], false);
    d.comment = asNumber(commentStat['count'], asNumber(stat['comment'], 0));
    d.forward = asNumber(forwardStat['count'], asNumber(stat['forward'], 0));
    // 图文动态内容
    const descObj: Record<string, Object> = asObject(dynamic['desc']);
    d.content = str(descObj, 'text', '');
    const descNodes: Array<Object> = asArray(descObj['rich_text_nodes']);
    for (let i: number = 0; i < descNodes.length; i++) {
      const node: Record<string, Object> = asObject(descNodes[i]);
      const emoji: Record<string, Object> = asObject(node['emoji']);
      if (Object.keys(emoji).length > 0) {
        const emote: BiliEmote = BiliEmote.from(emoji);
        emote.text = str(node, 'orig_text', str(node, 'text', emote.text));
        if (emote.text.length > 0 && emote.url.length > 0) d.emotes.push(emote);
      }
    }
    // 视频动态卡片
    const major: Record<string, Object> = asObject(dynamic['major']);
    d.majorType = str(major, 'type', '');
    let card: Record<string, Object> = asObject(major['archive']);
    if (Object.keys(card).length === 0) card = asObject(major['ugc_season']);
    if (Object.keys(card).length === 0) card = asObject(major['pgc']);
    if (Object.keys(card).length === 0) card = asObject(major['courses']);
    if (Object.keys(card).length === 0) card = asObject(major['medialist']);
    if (Object.keys(card).length === 0) card = asObject(major['common']);
    if (Object.keys(card).length === 0) card = asObject(major['upower_common']);
    if (Object.keys(card).length === 0) card = asObject(major['music']);
    if (Object.keys(card).length === 0) card = asObject(major['live']);
    d.title = str(card, 'title', '');
    d.cover = toHttps(str(card, 'cover', ''));
    d.bvid = str(card, 'bvid', '');
    d.aid = asNumber(card['aid'], asNumber(card['id'], 0));
    d.cid = asNumber(card['cid'], 0);
    // PGC 卡片带 season_id/epid（参考 PiliPlus DynamicArchiveModel），用于跳番剧详情页。
    d.seasonId = asNumber(card['season_id'], 0);
    d.epId = asNumber(card['epid'], asNumber(card['ep_id'], 0));
    d.subtitle = str(card, 'sub_title', str(card, 'desc', str(card, 'label', str(card, 'desc_first', ''))));
    d.liveRoomId = asNumber(card['room_id'], asNumber(card['roomid'], 0));
    d.liveUid = asNumber(card['uid'], 0);
    d.liveStatus = asNumber(card['live_status'], asNumber(card['live_state'], 0));
    // MAJOR_TYPE_LIVE 的房间号字段名就是 id，不是 room_id。
    if (d.liveRoomId <= 0 && d.type === 'DYNAMIC_TYPE_LIVE') {
      d.liveRoomId = asNumber(card['id'], 0);
    }
    const badge: Record<string, Object> = asObject(card['badge']);
    d.badge = str(badge, 'text', '');
    // 图文/专栏卡片使用 opus 图片；普通图文也可能放在 major.draw.items。
    const opus: Record<string, Object> = asObject(major['opus']);
    if (d.title.length === 0) d.title = str(opus, 'title', '');
    const summary: Record<string, Object> = asObject(opus['summary']);
    if (d.content.length === 0) d.content = str(summary, 'text', '');
    const summaryNodes: Array<Object> = asArray(summary['rich_text_nodes']);
    for (let i: number = 0; i < summaryNodes.length; i++) {
      const node: Record<string, Object> = asObject(summaryNodes[i]);
      const emoji: Record<string, Object> = asObject(node['emoji']);
      if (Object.keys(emoji).length > 0) {
        const emote: BiliEmote = BiliEmote.from(emoji);
        emote.text = str(node, 'orig_text', str(node, 'text', emote.text));
        if (emote.text.length > 0 && emote.url.length > 0) d.emotes.push(emote);
      }
    }
    let pics: Array<Object> = asArray(opus['pics']);
    const draw: Record<string, Object> = asObject(major['draw']);
    if (pics.length === 0) pics = asArray(draw['items']);
    for (let i: number = 0; i < pics.length; i++) {
      const pic: Record<string, Object> = asObject(pics[i]);
      const src: string = toHttps(str(pic, 'url', str(pic, 'src', '')));
      if (src.length > 0) d.images.push(src);
    }
    // 直播推荐卡把实际信息封装在 content JSON 字符串中。
    const liveRcmd: Record<string, Object> = asObject(major['live_rcmd']);
    const liveContent: string = str(liveRcmd, 'content', '');
    if (liveContent.length > 0) {
      try {
        const liveJson: Record<string, Object> = asObject(JSON.parse(liveContent) as Object);
        const liveInfo: Record<string, Object> = asObject(liveJson['live_play_info']);
        d.title = str(liveInfo, 'title', d.title);
        d.cover = toHttps(str(liveInfo, 'cover', d.cover));
        d.subtitle = str(liveInfo, 'area_name', d.subtitle);
        d.badge = '直播';
        d.liveRoomId = asNumber(liveInfo['room_id'], asNumber(liveInfo['roomid'], d.liveRoomId));
        d.liveUid = asNumber(liveInfo['uid'], d.liveUid);
        d.liveStatus = asNumber(liveInfo['live_status'], 1);
      } catch (e) {
        // 无效直播卡不阻断整个动态 feed。
      }
    }
    // 预约开播动态使用 subscription_new.live_rcmd，content 结构与 live_rcmd 一致。
    const subscriptionNew: Record<string, Object> = asObject(major['subscription_new']);
    const subscriptionLive: Record<string, Object> = asObject(subscriptionNew['live_rcmd']);
    const subscriptionContent: string = str(subscriptionLive, 'content', '');
    if (subscriptionContent.length > 0) {
      try {
        const subscriptionJson: Record<string, Object> = asObject(JSON.parse(subscriptionContent) as Object);
        const subscriptionInfo: Record<string, Object> = asObject(subscriptionJson['live_play_info']);
        d.title = str(subscriptionInfo, 'title', d.title);
        d.cover = toHttps(str(subscriptionInfo, 'cover', d.cover));
        d.subtitle = str(subscriptionInfo, 'area_name', d.subtitle);
        d.badge = '直播';
        d.liveRoomId = asNumber(subscriptionInfo['room_id'], asNumber(subscriptionInfo['roomid'], d.liveRoomId));
        d.liveUid = asNumber(subscriptionInfo['uid'], d.liveUid);
        d.liveStatus = asNumber(subscriptionInfo['live_status'], d.liveStatus);
      } catch (e) {
        // 无效预约卡不阻断整个动态 feed。
      }
    }
    // 转发动态的原始卡片与当前动态同构，保留完整媒体与跳转信息。
    const original: Record<string, Object> = asObject(j['orig']);
    if (Object.keys(original).length > 0) d.original = DynamicItem.from(original);
    return d;
  }
}

export class DynamicPageData {
  items: Array<DynamicItem> = [];
  offset: string = '';
  hasMore: boolean = false;
}

// ===== 番剧/影视（PGC）详情，移植自 PiliPlus models_new/pgc/pgc_info_model =====
/** PGC 单集（pgc/view/web/season 的 episodes 项） */
export class BangumiEpisode {
  epId: number = 0;
  aid: number = 0;
  bvid: string = '';
  cid: number = 0;
  /** 集数标签（"1"、"PV1" 等） */
  title: string = '';
  /** 单集标题 */
  longTitle: string = '';
  cover: string = '';
  /** PGC 接口时长单位为毫秒，入库统一转成秒 */
  duration: number = 0;
  /** 会员/付费等角标，空串表示免费 */
  badge: string = '';

  static from(o: Object): BangumiEpisode {
    const j: Record<string, Object> = asObject(o);
    const e: BangumiEpisode = new BangumiEpisode();
    e.epId = asNumber(j['ep_id'], asNumber(j['id'], 0));
    e.aid = asNumber(j['aid'], 0);
    e.bvid = str(j, 'bvid', '');
    e.cid = asNumber(j['cid'], 0);
    e.title = str(j, 'title', '');
    e.longTitle = str(j, 'long_title', '');
    e.cover = toHttps(str(j, 'cover', ''));
    e.duration = Math.floor(asNumber(j['duration'], 0) / 1000);
    e.badge = str(j, 'badge', '');
    return e;
  }
}

/** PGC 季详情；注意 pgc/view/web/season 的数据主体在 result 而非 data。 */
export class BangumiSeason {
  seasonId: number = 0;
  title: string = '';
  /** 副标题（"更新至第x话" 等） */
  subtitle: string = '';
  /** 横版封面，用于顶部氛围背景 */
  cover: string = '';
  /** 竖版海报，缺 square_cover 时回退横版封面 */
  poster: string = '';
  /** 简介 */
  evaluate: string = '';
  actors: string = '';
  areas: string = '';
  styles: string = '';
  pubTimeShow: string = '';
  /** 最新一集更新状态（new_ep.desc） */
  newEpDesc: string = '';
  ratingScore: number = 0;
  ratingCount: number = 0;
  views: number = 0;
  /** 追番数 */
  favorites: number = 0;
  danmakus: number = 0;
  reply: number = 0;
  total: number = 0;
  /** 登录用户追番状态（user_status.follow） */
  followed: boolean = false;
  episodes: Array<BangumiEpisode> = [];
  /** 相关番剧推荐（season 接口返回的 related_seasons） */
  relatedSeasons: Array<BangumiSeason> = [];

  static from(o: Object): BangumiSeason {
    const j: Record<string, Object> = asObject(o);
    const s: BangumiSeason = new BangumiSeason();
    s.seasonId = asNumber(j['season_id'], 0);
    s.title = str(j, 'title', '');
    s.subtitle = str(j, 'subtitle', '');
    s.cover = toHttps(str(j, 'cover', ''));
    s.poster = toHttps(str(j, 'square_cover', ''));
    if (s.poster.length === 0) {
      s.poster = s.cover;
    }
    s.evaluate = str(j, 'evaluate', '');
    s.actors = str(j, 'actors', '');
    const areas: Array<Object> = asArray(j['areas']);
    const areaNames: Array<string> = [];
    for (let i: number = 0; i < areas.length; i++) {
      const name: string = str(areas[i], 'name', '');
      if (name.length > 0) {
        areaNames.push(name);
      }
    }
    s.areas = areaNames.join(' · ');
    // styles 新老接口分别是字符串数组与 {id,name} 对象数组，两种都要兼容。
    const stylesArr: Array<Object> = asArray(j['styles']);
    const styleNames: Array<string> = [];
    for (let i: number = 0; i < stylesArr.length; i++) {
      const item: Object = stylesArr[i];
      const name: string = typeof item === 'string' ? item as string : str(item, 'name', '');
      if (name.length > 0) {
        styleNames.push(name);
      }
    }
    s.styles = styleNames.join(' · ');
    const publish: Record<string, Object> = asObject(j['publish']);
    s.pubTimeShow = str(publish, 'pub_time_show', '');
    const newEp: Record<string, Object> = asObject(j['new_ep']);
    s.newEpDesc = str(newEp, 'desc', '');
    const rating: Record<string, Object> = asObject(j['rating']);
    s.ratingScore = asNumber(rating['score'], 0);
    s.ratingCount = asNumber(rating['count'], 0);
    const stat: Record<string, Object> = asObject(j['stat']);
    s.views = asNumber(stat['views'], 0);
    s.favorites = asNumber(stat['favorites'], 0);
    s.danmakus = asNumber(stat['danmakus'], 0);
    s.reply = asNumber(stat['reply'], 0);
    s.total = asNumber(j['total'], 0);
    const userStatus: Record<string, Object> = asObject(j['user_status']);
    s.followed = asNumber(userStatus['follow'], 0) === 1;
    let episodes: Array<Object> = asArray(j['episodes']);
    if (episodes.length === 0) {
      // 部分接口把选集放在 ep_list 或 episodes 的兼容字段里。
      episodes = asArray(j['ep_list']);
    }
    for (let i: number = 0; i < episodes.length; i++) {
      const ep: BangumiEpisode = BangumiEpisode.from(episodes[i]);
      if (ep.epId > 0) {
        s.episodes.push(ep);
      }
    }
    const related: Array<Object> = asArray(j['related_seasons']);
    for (let i: number = 0; i < related.length; i++) {
      const raw: Record<string, Object> = asObject(related[i]);
      const item: BangumiSeason = new BangumiSeason();
      item.seasonId = asNumber(raw['season_id'], 0);
      item.title = str(raw, 'title', '');
      item.cover = toHttps(str(raw, 'cover', ''));
      item.subtitle = str(asObject(raw['new_ep']), 'desc', '');
      item.total = asNumber(raw['total'], 0);
      if (item.seasonId > 0) {
        s.relatedSeasons.push(item);
      }
    }
    return s;
  }
}

// ===== 热搜 =====
export class HotSearchItem {
  keyword: string = '';
  showName: string = '';
  icon: string = '';
  heatScore: number = 0;

  static from(o: Object): HotSearchItem {
    const j: Record<string, Object> = asObject(o);
    const h: HotSearchItem = new HotSearchItem();
    h.keyword = str(j, 'keyword', '');
    h.showName = str(j, 'show_name', '');
    h.icon = str(j, 'icon', '');
    h.heatScore = asNumber(j['heat_score'], 0);
    return h;
  }
}

// ===== 搜索类型常量（v1 实现 video/bili_user，其余预留，参考 PiliPlus search_type.dart） =====
export class SearchTypes {
  static readonly video: string = 'video';
  static readonly biliUser: string = 'bili_user';
  static readonly mediaBangumi: string = 'media_bangumi';
  static readonly mediaFt: string = 'media_ft';
  static readonly article: string = 'article';
  static readonly liveRoom: string = 'live_room';
}

// 字符串型搜索选项（label 展示文案 / value 请求参数值）
export interface SearchOption {
  label: string;
  value: string;
}

// 数值型搜索选项（时长 / 发布时间 / 分区）
export interface SearchNumOption {
  label: string;
  value: number;
}

// 视频排序（order 参数，参考 PiliPlus ArchiveFilterType）
export const VIDEO_ORDER_OPTIONS: Array<SearchOption> = [
  { label: '综合', value: 'totalrank' },
  { label: '最多点击', value: 'click' },
  { label: '最新发布', value: 'pubdate' },
  { label: '最多弹幕', value: 'dm' },
  { label: '最多收藏', value: 'stow' },
];

// 用户排序（order 参数，v1 只做降序 order_sort=0，参考 PiliPlus UserOrderType）
export const USER_ORDER_OPTIONS: Array<SearchOption> = [
  { label: '默认', value: '' },
  { label: '粉丝数', value: 'fans' },
  { label: '等级', value: 'level' },
];

// 直播间排序（order 参数，参考 PiliPlus LiveOrderType）
export const LIVE_ORDER_OPTIONS: Array<SearchOption> = [
  { label: '人气', value: 'online' },
  { label: '最新开播', value: 'live_time' },
];

// 视频时长筛选（duration 参数）
export const VIDEO_DURATION_OPTIONS: Array<SearchNumOption> = [
  { label: '不限', value: 0 },
  { label: '10分钟以下', value: 1 },
  { label: '10-30分钟', value: 2 },
  { label: '30-60分钟', value: 3 },
  { label: '60分钟以上', value: 4 },
];

// 视频发布时间筛选（value 为秒数偏移，客户端换算 pubtime_begin_s/pubtime_end_s）
export const VIDEO_PUBTIME_OPTIONS: Array<SearchNumOption> = [
  { label: '不限', value: 0 },
  { label: '一天内', value: 86400 },
  { label: '一周内', value: 604800 },
  { label: '半年内', value: 15724800 },
];

// 视频分区筛选（tids 参数，取 PiliPlus VideoZoneType 主要分区）
export const VIDEO_ZONE_OPTIONS: Array<SearchNumOption> = [
  { label: '不限', value: 0 },
  { label: '动画', value: 1 },
  { label: '音乐', value: 3 },
  { label: '游戏', value: 4 },
  { label: '知识', value: 36 },
  { label: '科技', value: 188 },
  { label: '生活', value: 160 },
  { label: '舞蹈', value: 129 },
  { label: '鬼畜', value: 119 },
  { label: '影视', value: 181 },
  { label: '美食', value: 221 },
];

// ===== 用户空间：用户信息（x/space/wbi/acc/info） =====
/** 用户空间普通/典藏头图。动画典藏仅让当前页加载 video，preview 用于相邻页预览。 */
export class UserSpaceHeaderItem {
  preview: string = '';
  fullCover: string = '';
  animationUrl: string = '';
  sourceWidth: number = 0;
  sourceHeight: number = 0;
  focusX: number = 0.5;
  focusY: number = 0.5;
}

export class UserSpaceInfo {
  mid: number = 0;
  name: string = '';
  face: string = '';
  sex: string = '';
  sign: string = '';
  level: number = 0;
  officialType: number = -1;   // 0 个人认证 1 机构认证 -1 无认证
  officialDesc: string = '';
  topPhoto: string = '';       // 空间头图，可能没有
  topPhotoDark: string = '';   // App 空间装扮提供的深色头图
  collectionHeaders: Array<UserSpaceHeaderItem> = []; // 典藏卡头图（静态或 MP4 动画）
  pendant: string = '';        // 头像框/头像挂件
  liveStatus: number = 0;
  liveRoomId: number = 0;
  liveTitle: string = '';
  liveCover: string = '';

  static from(o: Object): UserSpaceInfo {
    const j: Record<string, Object> = asObject(o);
    const u: UserSpaceInfo = new UserSpaceInfo();
    u.mid = asNumber(j['mid'], 0);
    u.name = str(j, 'name', '');
    // search/type 的 bili_user 结果使用 upic；部分旧接口才返回 face。
    u.face = toHttps(str(j, 'upic', str(j, 'face', '')));
    u.sex = str(j, 'sex', '');
    u.sign = str(j, 'sign', '');
    u.level = asNumber(j['level'], 0);
    const official: Record<string, Object> = asObject(j['official']);
    u.officialType = asNumber(official['type'], -1);
    u.officialDesc = str(official, 'title', str(official, 'desc', ''));
    u.topPhoto = toHttps(str(j, 'top_photo', ''));
    const pendant: Record<string, Object> = asObject(j['pendant']);
    u.pendant = toHttps(str(pendant, 'image', ''));
    // x/space/wbi/acc/info 的直播字段使用 live_room.liveStatus / roomid。
    // 同时兼容少量代理接口返回的 snake_case 字段。
    const liveRoom: Record<string, Object> = asObject(j['live_room']);
    u.liveStatus = asNumber(liveRoom['liveStatus'], asNumber(liveRoom['live_status'], 0));
    u.liveRoomId = asNumber(liveRoom['roomid'], asNumber(liveRoom['room_id'], 0));
    u.liveTitle = str(liveRoom, 'title', '');
    u.liveCover = toHttps(str(liveRoom, 'cover', str(liveRoom, 'keyframe', '')));
    return u;
  }
}

// ===== 用户空间：投稿分页结果 =====
export class SpaceArcData {
  videos: Array<VideoItem> = [];
  total: number = 0;
}

// ===== 分类搜索结果（携带 numResults 总数，用于结果页 Tab 徽标） =====
export class VideoSearchResult {
  videos: Array<VideoItem> = [];
  numResults: number = 0;
}

export class UserSearchResult {
  users: Array<UserSearchItem> = [];
  numResults: number = 0;
}
export class UserSearchItem {
  mid: number = 0;
  uname: string = '';
  face: string = '';
  fans: number = 0;
  videos: number = 0;
  usign: string = '';
  level: number = 0;
  verifyType: number = -1;   // 0 个人认证 1 机构认证 -1 无认证
  verifyDesc: string = '';
  liveStatus: number = 0;
  liveRoomId: number = 0;

  static from(o: Object): UserSearchItem {
    const j: Record<string, Object> = asObject(o);
    const u: UserSearchItem = new UserSearchItem();
    u.mid = asNumber(j['mid'], 0);
    // 昵称里可能包含高亮 <em> 标签，去除
    u.uname = str(j, 'uname', '').replace(/<[^>]*>/g, '');
    // search/type 的 bili_user 返回 upic；face/pic/avatar 仅用于兼容旧版和代理接口。
    u.face = toHttps(str(j, 'upic', str(j, 'face', str(j, 'pic', str(j, 'avatar', '')))));
    u.fans = asNumber(j['fans'], 0);
    u.videos = asNumber(j['videos'], 0);
    u.usign = str(j, 'usign', '');
    u.level = asNumber(j['level'], 0);
    const verify: Record<string, Object> = asObject(j['official_verify']);
    u.verifyType = asNumber(verify['type'], -1);
    u.verifyDesc = str(verify, 'desc', '');
    u.liveStatus = asNumber(j['is_live'], asNumber(j['live_status'], 0));
    u.liveRoomId = asNumber(j['room_id'], asNumber(j['roomid'], 0));
    return u;
  }
}

// ===== 番剧/影视搜索（media_bangumi / media_ft，参考 PiliPlus SearchPgcItemModel） =====
export class PgcSearchItem {
  seasonId: number = 0;
  title: string = '';
  cover: string = '';
  areas: string = '';
  styles: string = '';
  desc: string = '';
  score: number = 0;
  /** 连载状态，如「已完结」「更新至第12话」 */
  indexShow: string = '';
  /** 类型角标，如「番剧」「电影」 */
  seasonTypeName: string = '';

  static from(o: Object): PgcSearchItem {
    const j: Record<string, Object> = asObject(o);
    const item: PgcSearchItem = new PgcSearchItem();
    item.seasonId = asNumber(j['season_id'], 0);
    // 搜索标题可能带高亮 <em> 标签，去除
    item.title = str(j, 'title', '').replace(/<[^>]*>/g, '');
    item.cover = toHttps(str(j, 'cover', ''));
    item.areas = str(j, 'areas', '');
    item.styles = str(j, 'styles', '');
    item.desc = str(j, 'desc', '').replace(/<[^>]*>/g, '');
    item.indexShow = str(j, 'index_show', '');
    item.seasonTypeName = str(j, 'season_type_name', '');
    const mediaScore: Record<string, Object> = asObject(j['media_score']);
    item.score = asNumber(mediaScore['score'], 0);
    return item;
  }

  /** 评分文案，无评分时为空串 */
  scoreText(): string {
    return this.score > 0 ? this.score.toFixed(1) + '分' : '';
  }
}

export class PgcSearchResult {
  items: Array<PgcSearchItem> = [];
  numResults: number = 0;
}

// ===== 直播搜索（live_room）结果包装，条目解析见 LiveModels.LiveRoomItem.fromSearch =====
// ===== 专栏搜索（article，参考 PiliPlus SearchArticleItemModel） =====
export class ArticleSearchItem {
  id: number = 0;
  title: string = '';
  desc: string = '';
  cover: string = '';
  mid: number = 0;
  upName: string = '';
  view: number = 0;
  reply: number = 0;
  like: number = 0;
  categoryName: string = '';

  static from(o: Object): ArticleSearchItem {
    const j: Record<string, Object> = asObject(o);
    const item: ArticleSearchItem = new ArticleSearchItem();
    item.id = asNumber(j['id'], 0);
    item.title = str(j, 'title', '').replace(/<[^>]*>/g, '');
    item.desc = str(j, 'desc', '').replace(/<[^>]*>/g, '');
    const imageUrls: Array<Object> = asArray(j['image_urls']);
    if (imageUrls.length > 0) {
      item.cover = toHttps(asString(imageUrls[0], ''));
    }
    item.mid = asNumber(j['mid'], 0);
    // 文章搜索多数时候不返回昵称，保留 author/uname 兜底
    item.upName = str(j, 'author', str(j, 'uname', '')).replace(/<[^>]*>/g, '');
    item.view = asNumber(j['view'], 0);
    item.reply = asNumber(j['reply'], 0);
    item.like = asNumber(j['like'], 0);
    item.categoryName = str(j, 'category_name', '');
    return item;
  }
}

export class ArticleSearchResult {
  articles: Array<ArticleSearchItem> = [];
  numResults: number = 0;
}

// ===== 综合搜索（all/v2）聚合结果：按 result_type 分区，仅第一页包含番剧/用户分区 =====
export class SearchAllSection {
  /** video / bili_user / media_bangumi / media_ft */
  type: string = '';
  videos: Array<VideoItem> = [];
  users: Array<UserSearchItem> = [];
  pgc: Array<PgcSearchItem> = [];
}

export class SearchAllResult {
  sections: Array<SearchAllSection> = [];
  /** 各分类结果总数徽标（data.pageinfo），key 为 result_type */
  totals: Map<string, number> = new Map<string, number>();
}

// ===== 排行榜 / 必看榜单 =====
/** popular/series/list 项：每周必看期号 */
export class PopularSeriesItem {
  number: number = 0;
  name: string = '';

  static from(o: Object): PopularSeriesItem {
    const j: Record<string, Object> = asObject(o);
    const item: PopularSeriesItem = new PopularSeriesItem();
    item.number = asNumber(j['number'], 0);
    item.name = str(j, 'name', '');
    return item;
  }
}

/** popular/series/one 结果：期次信息 + 视频列表 */
export class PopularSeriesData {
  label: string = '';
  name: string = '';
  reminder: string = '';
  videos: Array<VideoItem> = [];
}
