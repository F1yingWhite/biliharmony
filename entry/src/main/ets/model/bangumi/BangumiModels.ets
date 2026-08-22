/** bangumi domain models. */
import { asObject, asNumber, asArray, str, toHttps } from '../../common/Utils';

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
