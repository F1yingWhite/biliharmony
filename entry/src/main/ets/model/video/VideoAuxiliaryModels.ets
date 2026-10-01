/**
 * 视频辅助数据模型：弹幕、标签、章节、热度与拖动预览。
 * 独立于请求层，BiliApi 保留兼容导出。
 */
import { asObject, asNumber, str } from '../../common/Utils';

// 弹幕屏蔽规则（x/dm/filter/user 的 rule 项；type 0 关键词 / 1 正则 / 2 用户）
export class DmFilterRule {
  id: number = 0;
  type: number = 0;
  filter: string = '';

  static from(o: Object): DmFilterRule {
    const j: Record<string, Object> = asObject(o);
    const r: DmFilterRule = new DmFilterRule();
    r.id = asNumber(j['id'], 0);
    r.type = asNumber(j['type'], 0);
    r.filter = str(j, 'filter', '');
    return r;
  }
}

// 弹幕数据
export class DanmakuItem {
  time: number = 0;    // 出现时间（秒）
  mode: number = 1;    // 1-3 滚动, 4 底部, 5 顶部, 6 逆向滚动, 7 高级弹幕
  color: number = 0xFFFFFF;
  text: string = '';
  /** 弹幕 id（dmid），protobuf 分段来源有值；超过 2^53 有精度损失，仅作是否存在判断 */
  id: number = 0;
  /** dmid 十进制原串：弹幕点赞/举报必须传它；XML 兜底为空串 */
  idStr: string = '';
  /** 发送字号档位：18 小 / 25 标准 / 36 大；渲染时按 25 为基准缩放。 */
  fontsize: number = 25;
  /** 智能云屏蔽权重 0-10（越大越优质）；低于用户设定屏蔽等级的弹幕不喷出。 */
  weight: number = 10;
  /** 重复弹幕合并后的簇计数（1 = 未合并）。 */
  mergeCount: number = 1;

  constructor(time: number, mode: number, color: number, text: string, id: number = 0,
    fontsize: number = 25, weight: number = 10, idStr: string = '') {
    this.time = time;
    this.mode = mode;
    this.color = color;
    this.text = text;
    this.id = id;
    this.idStr = idStr;
    this.fontsize = fontsize;
    this.weight = weight;
  }
}

export class VideoChapter {
  from: number = 0;
  to: number = 0;
  title: string = '';
  image: string = '';
}

/** 视频拖动预览：每张 image 是 xLen * yLen 的雪碧图，index 为每格对应的秒数。 */
/** 视频标签（x/tag/archive/tags）。 */
export class VideoTagInfo {
  tagId: number = 0;
  name: string = '';
}

/** 高能进度条：player/wbi/v2 view_points 的热度分段（detail 为弹幕密度值）。 */
export class HotPoint {
  from: number = 0;
  to: number = 0;
  detail: number = 0;

  /** 归一化不透明度：以集合内最大热度为基准，落到 0.25-0.9。 */
  alphaOf(all: Array<HotPoint>): number {
    let max: number = 0;
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].detail > max) max = all[i].detail;
    }
    if (max <= 0) return 0.5;
    return 0.25 + 0.65 * Math.min(1, this.detail / max);
  }
}

export class VideoShotData {
  images: Array<string> = [];
  index: Array<number> = [];
  xLen: number = 10;
  yLen: number = 10;
}
