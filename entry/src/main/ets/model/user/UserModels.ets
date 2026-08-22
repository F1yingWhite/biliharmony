/** user domain models. */
import { asObject, asNumber, str, toHttps } from '../../common/Utils';

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
/** 关注分组（关注标签）。 */
export class FollowTagItem {
  tagid: number = 0;
  name: string = '';
  count: number = 0;
}

export class UserStat {
  following: number = 0;
  follower: number = 0;
  likeNum: number = 0;

  static from(o: Object): UserStat {
    const j: Record<string, Object> = asObject(o);
    const data: Record<string, Object> = asObject(j['data']);
    // card 根的 following 是布尔（是否关注了他），数值型关注数在 card.attention。
    const card: Record<string, Object> = asObject(data['card']);
    const s: UserStat = new UserStat();
    s.following = asNumber(card['attention'], 0);
    s.follower = asNumber(data['follower'], asNumber(card['fans'], 0));
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
