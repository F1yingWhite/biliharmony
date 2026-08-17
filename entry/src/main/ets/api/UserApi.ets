/**
 * 用户域 API：当前登录用户 / 用户统计 / 关系 / 用户空间信息 / 投稿列表。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { appSign } from '../common/AppSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asNumber, asString, str, toHttps } from '../common/Utils';
import { RelationUserItem, RelationUserPageData, SpaceArcData, UserInfo, UserSpaceHeaderItem, UserSpaceInfo,
  UserStat, VideoItem } from '../model/Models';
import { getData, webGet } from './internal/ApiCommon';

class SpaceDecorationInfo {
  light: string = '';
  dark: string = '';
  pendant: string = '';
  collectionHeaders: Array<UserSpaceHeaderItem> = [];
}

export class UserApi {
  // ===== 当前登录用户（nav） =====
  static async getNav(): Promise<UserInfo> {
    const resp: HttpResponse = await webGet(Api.userInfo);
    if (!resp.ok) {
      return new UserInfo();
    }
    return UserInfo.fromNav(resp.json());
  }

  // ===== 用户统计 =====
  static async getUserStat(mid: number): Promise<UserStat> {
    // acc/info 已移除 stat 字段；/x/web-interface/card 的 data 根直接带 follower/following/like_num。
    try {
      const params: Record<string, string> = { 'mid': String(mid), 'photo': 'false' };
      const resp: HttpResponse = await webGet(Api.memberCardInfo, params);
      if (!resp.ok) {
        return new UserStat();
      }
      const data: Record<string, Object> | null = getData(resp);
      if (data === null) {
        return new UserStat();
      }
      // card 根字段：follower=粉丝、like_num=获赞；注意根上还有一个布尔型 following
      // （表示“当前登录用户是否关注了他”），数值型关注数在 card.attention。
      const card: Record<string, Object> = asObject(data['card']);
      const s: UserStat = new UserStat();
      s.follower = asNumber(data['follower'], asNumber(card['fans'], 0));
      s.following = asNumber(card['attention'], 0);
      s.likeNum = asNumber(data['like_num'], 0);
      return s;
    } catch (e) {
      return new UserStat();
    }
  }

  static async getRelationUsers(mid: number, mode: string, page: number): Promise<RelationUserPageData> {
    const result: RelationUserPageData = new RelationUserPageData();
    if (mid <= 0) return result;
    const params: Record<string, string> = {
      'vmid': String(mid),
      'pn': String(Math.max(1, page)),
      'ps': '30',
      'order': 'desc',
    };
    if (mode === 'following') params['order_type'] = 'attention';
    const endpoint: string = mode === 'follower' ? Api.userFollowers : Api.userFollowings;
    const resp: HttpResponse = await webGet(endpoint, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return result;
    result.total = asNumber(data['total'], 0);
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) {
      const item: RelationUserItem = RelationUserItem.from(list[i]);
      if (item.mid > 0) result.users.push(item);
    }
    return result;
  }

  // ===== 用户空间：用户信息（WBI 签名） =====
  static async getUserSpaceInfo(mid: number): Promise<UserSpaceInfo | null> {
    const decorationPromise: Promise<SpaceDecorationInfo> = UserApi.getUserSpaceDecoration(mid);
    const params: Record<string, string> = { 'mid': String(mid) };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.memberInfo, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return null;
    }
    const result: UserSpaceInfo = UserSpaceInfo.from(data);
    const decoration: SpaceDecorationInfo = await decorationPromise;
    if (decoration.light.length > 0) result.topPhoto = decoration.light;
    result.topPhotoDark = decoration.dark;
    result.collectionHeaders = decoration.collectionHeaders;
    if (result.pendant.length === 0 && decoration.pendant.length > 0) result.pendant = decoration.pendant;
    return result;
  }

  /** App 空间接口才会返回当前生效的日/夜间空间装扮，Web top_photo 仅作回退。 */
  private static async getUserSpaceDecoration(mid: number): Promise<SpaceDecorationInfo> {
    const result: SpaceDecorationInfo = new SpaceDecorationInfo();
    const params: Record<string, string> = {
      'build': '8430300',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
      'vmid': String(mid),
    };
    await appSign(params);
    const url: string = Api.memberSpaceApp + '?' + HttpClient.buildQuery(params);
    const headers: Record<string, string> = HttpClient.merge(Constants.appHeaders, {
      'User-Agent': Constants.userAgentApp,
      'app-key': 'android64',
    });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return result;
    const images: Record<string, Object> = asObject(data['images']);
    result.light = toHttps(str(images, 'imgUrl', str(images, 'img_url', '')));
    result.dark = toHttps(str(images, 'night_imgurl', ''));
    const collection: Record<string, Object> = asObject(images['collection_top_simple']);
    const top: Record<string, Object> = asObject(collection['top']);
    // PiliPlus 当前模型读取的是 top.result，而不是旧实现误写的 img_urls。
    // 典藏卡每页的展示图位于 item.image.default_image；cover 是查看原图时
    // 使用的完整封面，同时也是动画典藏卡没有静态图时的回退。
    const collectionItems: Array<Object> = asArray(top['result']);
    for (let i: number = 0; i < collectionItems.length; i++) {
      const entry: Record<string, Object> = asObject(collectionItems[i]);
      const item: Record<string, Object> = asObject(entry['item']);
      const image: Record<string, Object> = asObject(item['image']);
      const animation: Record<string, Object> = asObject(item['animation']);
      const cover: string = toHttps(str(entry, 'cover', ''));
      const firstFrame: string = toHttps(str(animation, 'animation_first_frame', ''));
      const backup: string = toHttps(str(animation, 'animation_backup_image', ''));
      const header: string = toHttps(str(image, 'default_image',
        firstFrame.length > 0 ? firstFrame : (backup.length > 0 ? backup : cover)));
      const animationUrls: Array<Object> = asArray(animation['animation_video_urls']);
      const headerItem: UserSpaceHeaderItem = new UserSpaceHeaderItem();
      headerItem.preview = header;
      headerItem.fullCover = cover.length > 0 ? cover : header;
      // width/height 是竖版原画画布，location 才是官方指定的取景区域。
      // 静态与动画元数据必须整组读取，避免 image 宽度和 animation 高度混用。
      const mediaMeta: Record<string, Object> = Object.keys(animation).length > 0 ? animation : image;
      headerItem.sourceWidth = asNumber(mediaMeta['width'], 0);
      headerItem.sourceHeight = asNumber(mediaMeta['height'], 0);
      const locationParts: Array<string> = str(mediaMeta, 'location', '').split('-');
      if (locationParts.length === 4 && headerItem.sourceWidth > 0 && headerItem.sourceHeight > 0) {
        const cropX: number = Number(locationParts[0]);
        const cropY: number = Number(locationParts[1]);
        const cropWidth: number = Number(locationParts[2]);
        const cropHeight: number = Number(locationParts[3]);
        if (!Number.isNaN(cropX) && !Number.isNaN(cropY) && !Number.isNaN(cropWidth) &&
          !Number.isNaN(cropHeight) && cropWidth > 0 && cropHeight > 0) {
          headerItem.focusX = Math.max(0, Math.min(1, (cropX + cropWidth / 2) / headerItem.sourceWidth));
          headerItem.focusY = Math.max(0, Math.min(1, (cropY + cropHeight / 2) / headerItem.sourceHeight));
        }
      } else if (headerItem.sourceHeight > headerItem.sourceWidth && headerItem.sourceWidth > 0) {
        // 旧典藏没有 location 时优先展示原画上半部，避免人物面部被居中裁掉。
        headerItem.focusY = 0.36;
      }
      if (animationUrls.length > 0) headerItem.animationUrl = toHttps(asString(animationUrls[0], ''));
      if (headerItem.preview.length === 0 && headerItem.animationUrl.length === 0) continue;
      result.collectionHeaders.push(headerItem);
    }
    if (result.collectionHeaders.length > 0) {
      result.light = result.collectionHeaders[0].preview;
    }
    const card: Record<string, Object> = asObject(data['card']);
    const pendant: Record<string, Object> = asObject(card['pendant']);
    result.pendant = toHttps(str(pendant, 'image_enhance', str(pendant, 'image', '')));
    return result;
  }

  // ===== 用户空间：投稿列表（WBI 签名，order: pubdate 最新 / click 最多播放 / stow 最多收藏） =====
  static async getUserSpaceArcs(mid: number, pn: number, order: string): Promise<SpaceArcData> {
    const params: Record<string, string> = {
      'mid': String(mid),
      'pn': String(pn),
      'ps': '30',
      'order': order,
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.memberArcSearch, params);
    const result: SpaceArcData = new SpaceArcData();
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return result;
    }
    const page: Record<string, Object> = asObject(data['page']);
    result.total = asNumber(page['count'], 0);
    const list: Record<string, Object> = asObject(data['list']);
    const vlist: Array<Object> = asArray(list['vlist']);
    for (let i: number = 0; i < vlist.length; i++) {
      result.videos.push(VideoItem.fromSpaceItem(vlist[i]));
    }
    return result;
  }
}
