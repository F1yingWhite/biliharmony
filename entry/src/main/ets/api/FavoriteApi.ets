/**
 * 收藏夹与合集 API：列表 / 增删改 / 移动 / 排序 / 收藏视频 / 合集视频。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { appSign } from '../common/AppSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asNumber, asBool, str, toHttps } from '../common/Utils';
import { FavoriteFolderItem, FavoriteFolderPageData, FavoriteVideoPageData, VideoItem } from '../model/Models';
import { ActionResult, getData, postVideoAction } from './internal/ApiCommon';

export class FavoriteApi {
  // ===== 收藏夹 =====
  static async getFavoriteFolders(mid: number, page: number): Promise<FavoriteFolderPageData> {
    const params: Record<string, string> = {
      'up_mid': String(mid), 'pn': String(page), 'ps': '20',
    };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteFolders + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteFolderPageData = new FavoriteFolderPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.folders.push(FavoriteFolderItem.from(list[i]));
    result.hasMore = asBool(data['has_more'], list.length >= 20);
    return result;
  }

  /** 当前视频可用的自建收藏夹，同时返回每个收藏夹是否已包含该视频（up_mid 必填，否则 -400）。 */
  static async getFavoriteFoldersForVideo(aid: number, mid: number): Promise<Array<FavoriteFolderItem>> {
    const params: Record<string, string> = { 'rid': String(aid), 'type': '2', 'up_mid': String(mid), 'platform': 'web' };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteFoldersForVideo + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: Array<FavoriteFolderItem> = [];
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.push(FavoriteFolderItem.from(list[i]));
    return result;
  }

  static async modifyVideoFavorite(aid: number, addIds: Array<number>, deleteIds: Array<number>): Promise<ActionResult> {
    const params: Record<string, string> = {
      'rid': String(aid),
      'type': '2',
      'add_media_ids': addIds.map((id: number) => String(id)).join(','),
      'del_media_ids': deleteIds.map((id: number) => String(id)).join(','),
      'platform': 'web',
    };
    return postVideoAction(Api.favoriteResourceDeal, params);
  }

  /** 收藏夹自定义排序：sort 为按新顺序排列的收藏夹 id（逗号分隔），需要 appSign + csrf。 */
  static async sortFavoriteFolders(folderIds: Array<number>): Promise<ActionResult> {
    if (folderIds.length === 0) return new ActionResult(false, '收藏夹为空');
    if (HttpClient.getCookie('SESSDATA').length === 0) {
      return new ActionResult(false, '登录状态已失效，请重新登录', -101);
    }
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new ActionResult(false, '登录状态缺少 CSRF，请重新登录', -111);
    const params: Record<string, string> = {
      'sort': folderIds.map((id: number) => String(id)).join(','),
      'csrf': csrf,
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.favoriteFolderSort + '?' + HttpClient.buildQuery(params),
      HttpClient.buildQuery({}), Constants.webHeaders);
    if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
    const json: Record<string, Object> = resp.json();
    const code: number = Number(json['code'] ?? -1);
    const ok: boolean = code === 0;
    return new ActionResult(ok, ok ? '收藏夹排序已保存' :
      (String(json['message'] ?? '排序失败') + ' (' + String(code) + ')'), code);
  }

  /** 收藏夹内视频自定义排序：mediaId + 按新顺序排列的视频资源 id（逗号分隔），需要 appSign + csrf。 */
  static async sortFavoriteVideos(mediaId: number, videoIds: Array<number>): Promise<ActionResult> {
    if (mediaId <= 0 || videoIds.length === 0) return new ActionResult(false, '参数无效');
    if (HttpClient.getCookie('SESSDATA').length === 0) {
      return new ActionResult(false, '登录状态已失效，请重新登录', -101);
    }
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new ActionResult(false, '登录状态缺少 CSRF，请重新登录', -111);
    const params: Record<string, string> = {
      'media_id': String(mediaId),
      'sort': videoIds.map((id: number) => String(id)).join(','),
      'csrf': csrf,
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.favoriteResourceSort + '?' + HttpClient.buildQuery(params),
      HttpClient.buildQuery({}), Constants.webHeaders);
    if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
    const json: Record<string, Object> = resp.json();
    const code: number = Number(json['code'] ?? -1);
    const ok: boolean = code === 0;
    return new ActionResult(ok, ok ? '视频排序已保存' :
      (String(json['message'] ?? '排序失败') + ' (' + String(code) + ')'), code);
  }

  static async getFavoriteVideos(mediaId: number, page: number): Promise<FavoriteVideoPageData> {
    const params: Record<string, string> = {
      'media_id': String(mediaId), 'pn': String(page), 'ps': '20', 'keyword': '',
      'order': 'mtime', 'type': '0', 'tid': '0', 'platform': 'web',
    };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteResources + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteVideoPageData = new FavoriteVideoPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['medias']);
    for (let i: number = 0; i < list.length; i++) {
      const j: Record<string, Object> = asObject(list[i]);
      const upper: Record<string, Object> = asObject(j['upper']);
      const cnt: Record<string, Object> = asObject(j['cnt_info']);
      const video: VideoItem = new VideoItem();
      video.aid = asNumber(j['id'], 0);
      video.bvid = str(j, 'bvid', str(j, 'bv_id', ''));
      video.title = str(j, 'title', '');
      video.cover = toHttps(str(j, 'cover', ''));
      video.duration = asNumber(j['duration'], 0);
      video.upName = str(upper, 'name', '');
      video.upMid = asNumber(upper['mid'], 0);
      video.play = asNumber(cnt['play'], 0);
      video.danmaku = asNumber(cnt['danmaku'], 0);
      result.videos.push(video);
    }
    result.hasMore = asBool(data['has_more'], list.length >= 20);
    return result;
  }

  // ===== 收藏夹管理（需登录 + CSRF，与 PiliPlus lib/http/fav.dart 对齐） =====
  /** 全部自建收藏夹（created/list-all 不分页，移动目标选择用）。 */
  static async getAllFavoriteFolders(mid: number): Promise<Array<FavoriteFolderItem>> {
    const params: Record<string, string> = { 'up_mid': String(mid) };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteFoldersForVideo + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: Array<FavoriteFolderItem> = [];
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.push(FavoriteFolderItem.from(list[i]));
    return result;
  }

  /** 新建收藏夹：privacy 0 公开 / 1 私密，这里固定公开，需要私密可后续加开关。 */
  static async addFavoriteFolder(title: string, intro: string = ''): Promise<ActionResult> {
    if (title.trim().length === 0) return new ActionResult(false, '收藏夹名称不能为空');
    return postVideoAction(Api.favFolderAdd, {
      'title': title.trim(),
      'intro': intro.trim(),
      'privacy': '0',
    });
  }

  /** 重命名/改简介；privacy 与 intro 透传当前值，避免重命名时被重置。 */
  static async editFavoriteFolder(mediaId: number, title: string, isPublic: boolean, intro: string = ''): Promise<ActionResult> {
    if (mediaId <= 0) return new ActionResult(false, '收藏夹信息无效');
    if (title.trim().length === 0) return new ActionResult(false, '收藏夹名称不能为空');
    return postVideoAction(Api.favFolderEdit, {
      'media_id': String(mediaId),
      'title': title.trim(),
      'intro': intro.trim(),
      'privacy': isPublic ? '0' : '1',
    });
  }

  static async delFavoriteFolder(mediaIds: Array<number>): Promise<ActionResult> {
    if (mediaIds.length === 0) return new ActionResult(false, '未选择要删除的收藏夹');
    return postVideoAction(Api.favFolderDel, {
      'media_ids': mediaIds.map((id: number) => String(id)).join(','),
      'platform': 'web',
    });
  }

  /** 夹内删除条目：逐条走 batch-deal 的 del_media_ids（/x/v3/fav/resource/del 端点不存在，会 404）。 */
  static async delFavoriteResources(mediaId: number, aids: Array<number>): Promise<ActionResult> {
    if (mediaId <= 0 || aids.length === 0) return new ActionResult(false, '未选择要删除的视频');
    for (let i = 0; i < aids.length; i++) {
      const result: ActionResult = await postVideoAction(Api.favoriteResourceDeal, {
        'rid': String(aids[i]),
        'type': '2',
        'add_media_ids': '',
        'del_media_ids': String(mediaId),
      });
      if (!result.ok) return result;
    }
    return new ActionResult(true, '已删除');
  }

  /** 批量移动条目到目标收藏夹（PiliPlus copyOrMoveFav isCopy=false 分支）。 */
  static async moveFavoriteResources(srcMediaId: number, tarMediaId: number, aids: Array<number>): Promise<ActionResult> {
    if (srcMediaId <= 0 || tarMediaId <= 0 || aids.length === 0) return new ActionResult(false, '未选择要移动的视频');
    return postVideoAction(Api.favResourceMove, {
      'src_media_id': String(srcMediaId),
      'tar_media_id': String(tarMediaId),
      'resources': aids.map((id: number) => String(id) + ':2').join(','),
      'platform': 'web',
    });
  }

  static async getCollectedFolders(mid: number, page: number): Promise<FavoriteFolderPageData> {
    const params: Record<string, string> = {
      'up_mid': String(mid), 'pn': String(page), 'ps': '20', 'platform': 'web',
    };
    const resp: HttpResponse = await HttpClient.get(Api.collectedFolders + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteFolderPageData = new FavoriteFolderPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.folders.push(FavoriteFolderItem.from(list[i]));
    result.hasMore = asBool(data['has_more'], list.length >= 20);
    return result;
  }

  static async getCollectionVideos(seasonId: number, page: number): Promise<FavoriteVideoPageData> {
    const params: Record<string, string> = {
      'season_id': String(seasonId), 'pn': String(page), 'ps': '20',
    };
    const resp: HttpResponse = await HttpClient.get(Api.collectionResources + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteVideoPageData = new FavoriteVideoPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['medias']);
    for (let i: number = 0; i < list.length; i++) {
      const j: Record<string, Object> = asObject(list[i]);
      const cnt: Record<string, Object> = asObject(j['cnt_info']);
      const video: VideoItem = new VideoItem();
      video.aid = asNumber(j['id'], 0);
      video.bvid = str(j, 'bvid', '');
      video.title = str(j, 'title', '');
      video.cover = toHttps(str(j, 'cover', ''));
      video.duration = asNumber(j['duration'], 0);
      video.pubdate = asNumber(j['pubtime'], 0);
      video.play = asNumber(cnt['play'], 0);
      video.danmaku = asNumber(cnt['danmaku'], 0);
      result.videos.push(video);
    }
    const info: Record<string, Object> = asObject(data['info']);
    const total: number = asNumber(info['media_count'], result.videos.length);
    result.hasMore = page * 20 < total;
    return result;
  }
}
