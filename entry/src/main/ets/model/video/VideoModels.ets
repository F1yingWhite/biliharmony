/** video domain models. */
import { searchPlainText, asObject, asString, asNumber, asArray, asBool, str, formatCount, toHttps } from '../../common/Utils';

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
    v.title = searchPlainText(v.title);
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
  epId: number = 0;
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
  isPreview: boolean = false;
  url: string = '';
  urls: Array<string> = [];
  audioUrl: string = '';
  audioUrls: Array<string> = [];
  /** 下载专用的最高码率标准 DASH 音轨；播放切换为单文件 MP4 时仍保留。 */
  downloadAudioUrls: Array<string> = [];
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
    info.isPreview = asNumber(j['is_preview'], 0) === 1 || j['is_preview'] === true;
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
    // 本次响应的真实 DASH 轨集合（供菜单标记可用/不可用；MP4 分支同样需要）。
    const dashAvailable: Array<number> = [];
    for (let i: number = 0; i < dashVideo.length; i++) {
      const id: number = asNumber(asObject(dashVideo[i])['id'], 0);
      if (id > 0 && dashAvailable.indexOf(id) < 0) dashAvailable.push(id);
    }
    dashAvailable.sort((a: number, b: number) => b - a);
    // 先按用户偏好确定实际可用档位，再选择传输格式；普通 MP4 不能遮住更高档 DASH。
    let selectedQuality: number = dashAvailable.length > 0 ? dashAvailable[dashAvailable.length - 1] : info.quality;
    for (let i: number = 0; i < dashAvailable.length; i++) {
      if (dashAvailable[i] <= requestedQuality) {
        selectedQuality = dashAvailable[i];
        break;
      }
    }
    if (durl.length > 0 && info.quality <= 80 &&
      (dashAvailable.length === 0 || info.quality === selectedQuality)) {
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
      info.isDash = false;
      info.urls = candidates;
      info.url = candidates.length > 0 ? candidates[0] : '';
      // 菜单仍要展示 DASH 全量画质（fnval 4049 时 accept_quality 只含 MP4 协议档位，
      // 用它会导致 1080P60/1080P+/4K 从菜单消失）；选高画质会按新 qn 重新请求走 DASH。
      info.qualities = qualityListFrom(supportFormats, acceptQuality, acceptDescription, dashAvailable);
    } else if (dashVideo.length > 0) {
      info.isDash = true;
      info.format = 'dash';
      info.quality = selectedQuality;

      // 对齐 PiliPlus：support_formats 全部展示，未返回实际 DASH 轨的会员画质标灰并说明原因。
      info.qualities = qualityListFrom(supportFormats, acceptQuality, acceptDescription, dashAvailable);

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
      info.downloadAudioUrls = info.audioUrls.slice();
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

/** 清晰度菜单数据源：优先 support_formats（全量档位），退回 accept_quality；available= 真实 DASH 轨是否包含。 */
function qualityListFrom(supportFormats: Array<Object>, acceptQuality: Array<Object>, acceptDescription: Array<Object>,
  available: Array<number>): Array<VideoQualityOption> {
  const list: Array<VideoQualityOption> = [];
  if (supportFormats.length > 0) {
    for (let i: number = 0; i < supportFormats.length; i++) {
      const formatItem: Record<string, Object> = asObject(supportFormats[i]);
      const qn: number = asNumber(formatItem['quality'], 0);
      if (qn <= 0) continue;
      const description: string = str(formatItem, 'new_description', str(formatItem, 'display_desc', ''));
      list.push(new VideoQualityOption(qn, qualityShortName(qn, description), available.indexOf(qn) >= 0));
    }
  } else {
    for (let i: number = 0; i < acceptQuality.length; i++) {
      const qn: number = asNumber(acceptQuality[i], 0);
      if (qn <= 0) continue;
      const description: string = i < acceptDescription.length ? asString(acceptDescription[i], '') : '';
      list.push(new VideoQualityOption(qn, qualityShortName(qn, description), available.indexOf(qn) >= 0));
    }
  }
  return list;
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
