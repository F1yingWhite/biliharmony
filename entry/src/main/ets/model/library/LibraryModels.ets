/** library domain models. */
import { asObject, asNumber, asArray, asBool, str, toHttps } from '../../common/Utils';
import { VideoItem } from '../video/VideoModels';

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
  /** 动态表情地址（GIF/APNG，可为空）；有值时展示用它，Image 自动播放。 */
  gifUrl: string = '';
  /** 1 = 单行高，2 = 双行高。 */
  size: number = 1;

  static from(o: Object): BiliEmote {
    const j: Record<string, Object> = asObject(o);
    const item: BiliEmote = new BiliEmote();
    item.text = str(j, 'text', '');
    // url 回退链：静态图优先；gif_url 兜底 —— 接口里纯动图表情只有 gif_url，
    // 不兜底的包会因 url 为空整包被丢弃，单行动图包因此消失。
    item.url = toHttps(str(j, 'url', str(j, 'webp_url', str(j, 'icon_url', str(j, 'gif_url', '')))));
    item.gifUrl = toHttps(str(j, 'gif_url', str(j, 'gif', '')));
    const meta: Record<string, Object> = asObject(j['meta']);
    item.size = Math.max(1, asNumber(meta['size'], asNumber(j['size'], 1)));
    return item;
  }

  /** 实际展示地址：有动态图用动态图，否则用静态图。 */
  displayUrl(): string {
    return this.gifUrl.length > 0 ? this.gifUrl : this.url;
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
    pkg.icon = toHttps(str(j, 'url', str(j, 'icon', str(j, 'icon_url', ''))));
    // 接口不同版本的表情数组字段名不一（emote / emotes / list），取最长的那个。
    let list: Array<Object> = asArray(j['emote']);
    if (list.length === 0) list = asArray(j['emotes']);
    if (list.length === 0) list = asArray(j['list']);
    for (let i: number = 0; i < list.length; i++) {
      const emote: BiliEmote = BiliEmote.from(list[i]);
      if (emote.text.length > 0 && emote.url.length > 0) pkg.emotes.push(emote);
    }
    return pkg;
  }
}
