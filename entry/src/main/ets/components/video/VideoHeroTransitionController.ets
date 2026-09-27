/**
 * 视频详情页 hero 转场控制器：卡片封面飞入播放区（入场）与镜面收回（退出）。
 *
 * 三段式与 DynamicDetail / ImageViewer 同构：
 * 1. prepare：把独立封面 / 整卡快照摆到源卡片矩形上（prepareCardEntrance / prepareWholeCardEntrance）；
 * 2. 等下一次 VSync（HeroFrameCallback）确认源矩形已提交，再开始 animateTo 飞行；
 * 3. 入场期详情数据挂在闸门上（armEntranceGate / waitEntranceGate），动画结束或兜底超时后放行，
 *    避免动画中途整页重排。
 *
 * 从 VideoDetail 抽出，按可复用形态设计：转场 AppStorage 键（VideoHeroTransitionKeys）、
 * 动画时长/圆角（VideoHeroMotionParams）、目标矩形测量等均由页面注入；
 * @State 全部留在页面（经 VideoHeroTransitionAccess 闭包读写），本文件不 import 任何页面 struct。
 * 后续接线 DynamicDetail / ImageViewer 时，各自传入键名、测量函数与动画参数即可。
 */
import { FrameCallback, UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { AppNavStack, ImageViewerSrcRect, releasePixelMap } from '../../common/AppRouter';

/** 等下一次 VSync 已提交源矩形后再开始 hero，避免用固定延时猜首帧时机。 */
export class HeroFrameCallback extends FrameCallback {
  private task: () => void;

  constructor(task: () => void) {
    super();
    this.task = task;
  }

  onFrame(_frameTimeInNano: number): void {
    this.task();
  }
}

/** 转场经 AppStorage 与导航层握手；键名由页面注入，值保持与 AppRouter 导出常量字面量一致。 */
export interface VideoHeroTransitionKeys {
  /** 整卡快照的中转键（HERO_BG_SNAPSHOT_KEY）。 */
  snapshotKey: string;
  /** 转场进行中标记键（HERO_NAV_TRANSITION_ACTIVE_KEY）。 */
  activeKey: string;
  /** 转场时长键（HERO_NAV_TRANSITION_DURATION_KEY）。 */
  durationKey: string;
  /** 转场结束请求键（HERO_NAV_TRANSITION_FINISH_REQUEST_KEY）。 */
  finishRequestKey: string;
}

/** 动画参数：同构三段式在不同页面的时长/延时/圆角，全部注入以备复用。 */
export interface VideoHeroMotionParams {
  /** 入场闸门兜底放行超时（动画 onFinish 缺失——被返回打断等——时内容不停在骨架）。 */
  gateFallbackMs: number;
  /** 整卡展开：主动画时长（onFinish 里关闸门）/ 正文淡入时长 / 快照淡出时长与延时。 */
  wholeCardExpandMs: number;
  wholeCardContentMs: number;
  wholeCardSnapshotFadeMs: number;
  wholeCardSnapshotFadeDelayMs: number;
  /** 卡片封面飞入：主动画时长 / 正文淡入时长与延时 / 封面目标圆角。 */
  cardFlightMs: number;
  cardContentMs: number;
  cardContentDelayMs: number;
  cardCoverRadius: number;
  /** pop 时写入 AppStorage 的转场时长。 */
  popDurationMs: number;
  /** 整卡收合（退出）：主动画时长 / 快照淡入时长与延时 / 正文淡出时长与延时。 */
  wholeCardCollapseMs: number;
  exitSnapshotInMs: number;
  exitSnapshotInDelayMs: number;
  exitContentOutMs: number;
  exitContentOutDelayMs: number;
  /** 卡片封面收回（退出）：正文淡出时长 / 主动画时长。 */
  cardExitContentMs: number;
  cardExitFlightMs: number;
  /** 卡片原始圆角 vp（整卡缩放期按 scale 还原为起始 6vp 观感）。 */
  cardCornerVp: number;
}

/**
 * 页面 hero 状态的读写面：@State 留在页面，控制器经闭包读写，
 * 保证 ArkUI 响应式（页面字段直接赋值触发刷新）与抽取前完全一致。
 */
/**
 * 页面入场/退场动画状态的读写面：@State 留在页面，控制器经闭包读写。
 * 成员统一用「属性 + 箭头函数」声明：ArkTS 的对象字面量检查只按属性语法匹配。
 */
export interface VideoHeroTransitionAccess {
  /** 详情正文/整卡内容的透明度（entryContentOpacity）。 */
  setContentOpacity: (value: number) => void;
  /** 独立封面层（heroVisible/heroSource/heroX/Y/Width/Height/Radius/Opacity）。 */
  setHeroVisible: (value: boolean) => void;
  setHeroSource: (value: string) => void;
  setHeroX: (value: number) => void;
  setHeroY: (value: number) => void;
  setHeroWidth: (value: number) => void;
  setHeroHeight: (value: number) => void;
  setHeroRadius: (value: number) => void;
  setHeroOpacity: (value: number) => void;
  /** 整卡一镜到底层（wholeCard* 系列）。 */
  setWholeCardAnimating: (value: boolean) => void;
  getWholeCardSnapshot: () => image.PixelMap | null;
  setWholeCardSnapshot: (value: image.PixelMap | null) => void;
  setWholeCardSnapshotOpacity: (value: number) => void;
  setWholeCardScale: (value: number) => void;
  setWholeCardTranslateX: (value: number) => void;
  setWholeCardTranslateY: (value: number) => void;
  setWholeCardClipHeight: (value: number) => void;
  setWholeCardRadius: (value: number) => void;
  setWholeCardSnapshotHeight: (value: number) => void;
  /** 入场路径标记与闸门武装标记（页面持有字段，控制器经闭包读写）。 */
  setFromWholeCard: (value: boolean) => void;
  isFromWholeCard: () => boolean;
  setFromRect: (value: boolean) => void;
  isFromRect: () => boolean;
  isEntranceArmed: () => boolean;
  setEntranceArmed: (value: boolean) => void;
}

export class VideoHeroTransitionController {
  private readonly keys: VideoHeroTransitionKeys;
  private readonly motion: VideoHeroMotionParams;
  private readonly access: VideoHeroTransitionAccess;
  private readonly measureHeroRect: () => ImageViewerSrcRect | undefined;
  private readonly getCoverUrl: () => string;
  private readonly getScreenWidthVp: () => number;
  private readonly getScreenHeightVp: () => number;
  private readonly getCardRect: () => ImageViewerSrcRect | undefined;
  private readonly getSrcRect: () => ImageViewerSrcRect | undefined;
  private readonly isMirrorReturnDisabled: () => boolean;
  private readonly isDestroyed: () => boolean;
  private readonly isClosing: () => boolean;
  private readonly uiContext: () => UIContext;
  private readonly scheduleTimeout: (callback: () => void, delayMs: number) => void;

  /** 入场闸门：网络请求立即发出，详情结果等动画结束再落状态。 */
  private gate: Promise<void> = Promise.resolve();
  private gateResolve: (() => void) | null = null;

  constructor(
    keys: VideoHeroTransitionKeys,
    motion: VideoHeroMotionParams,
    access: VideoHeroTransitionAccess,
    measureHeroRect: () => ImageViewerSrcRect | undefined,
    getCoverUrl: () => string,
    getScreenWidthVp: () => number,
    getScreenHeightVp: () => number,
    getCardRect: () => ImageViewerSrcRect | undefined,
    getSrcRect: () => ImageViewerSrcRect | undefined,
    isMirrorReturnDisabled: () => boolean,
    isDestroyed: () => boolean,
    isClosing: () => boolean,
    uiContext: () => UIContext,
    scheduleTimeout: (callback: () => void, delayMs: number) => void,
  ) {
    this.keys = keys;
    this.motion = motion;
    this.access = access;
    this.measureHeroRect = measureHeroRect;
    this.getCoverUrl = getCoverUrl;
    this.getScreenWidthVp = getScreenWidthVp;
    this.getScreenHeightVp = getScreenHeightVp;
    this.getCardRect = getCardRect;
    this.getSrcRect = getSrcRect;
    this.isMirrorReturnDisabled = isMirrorReturnDisabled;
    this.isDestroyed = isDestroyed;
    this.isClosing = isClosing;
    this.uiContext = uiContext;
    this.scheduleTimeout = scheduleTimeout;
  }

  /** 页面复用（返回再进）时复位 hero 状态；快照先释放再置空，避免全屏 PixelMap 泄漏。 */
  resetForReuse(): void {
    this.access.setWholeCardAnimating(false);
    releasePixelMap(this.access.getWholeCardSnapshot());
    this.access.setWholeCardSnapshot(null);
    this.access.setWholeCardSnapshotOpacity(0);
    this.access.setWholeCardScale(1);
    this.access.setWholeCardTranslateX(0);
    this.access.setWholeCardTranslateY(0);
    this.access.setWholeCardClipHeight(0);
    this.access.setWholeCardRadius(0);
    this.access.setWholeCardSnapshotHeight(0);
    this.access.setEntranceArmed(false);
    this.access.setContentOpacity(1);
    this.access.setHeroVisible(false);
    this.access.setHeroOpacity(1);
  }

  /**
   * 华为官方 CardLongTakeTransition 的核心做法：目标页保持整屏布局，只缩放并裁剪外层容器；
   * 这样动画期间不会因为宽高连续变化而让播放器、标题和工具栏反复重排。
   */
  prepareWholeCardEntrance(): boolean {
    const rect: ImageViewerSrcRect | undefined = this.getCardRect();
    const snapshot: image.PixelMap | null = AppStorage.get<image.PixelMap>(this.keys.snapshotKey) ?? null;
    AppStorage.delete(this.keys.snapshotKey);
    if (rect === undefined || rect.w <= 0 || rect.h <= 0 ||
      this.getScreenWidthVp() <= 0 || this.getScreenHeightVp() <= 0) {
      // 快照已从 AppStorage 摘出，入场校验失败必须就地释放，否则全屏 PixelMap 泄漏。
      releasePixelMap(snapshot);
      return false;
    }
    if (snapshot === null) return false;
    const scale: number = rect.w / this.getScreenWidthVp();
    if (!Number.isFinite(scale) || scale <= 0 || scale >= 1) {
      releasePixelMap(snapshot);
      return false;
    }
    const clipHeight: number = rect.h / scale;
    this.access.setFromWholeCard(true);
    this.access.setWholeCardAnimating(true);
    this.access.setWholeCardSnapshot(snapshot);
    this.access.setWholeCardSnapshotOpacity(1);
    this.access.setWholeCardScale(scale);
    this.access.setWholeCardClipHeight(clipHeight);
    this.access.setWholeCardSnapshotHeight(clipHeight);
    this.access.setWholeCardTranslateX(rect.x - (this.getScreenWidthVp() - rect.w) / 2);
    this.access.setWholeCardTranslateY(rect.y - (clipHeight - rect.h) / 2);
    // 圆角会随容器一起缩放，除以 scale 后起始画面恰好保持卡片原有的 6vp 圆角。
    this.access.setWholeCardRadius(this.motion.cardCornerVp / scale);
    this.access.setContentOpacity(0);
    return true;
  }

  /** 关闭闸门：详情结果会一直等到入场动画结束（或兜底超时）。 */
  armEntranceGate(): void {
    if (this.gateResolve !== null) return;
    this.gate = new Promise<void>((resolve: () => void) => {
      this.gateResolve = resolve;
    });
    // 动画 onFinish 缺失（被返回打断等）时兜底放行，内容不会永远停在骨架。
    this.scheduleTimeout(() => {
      if (!this.isDestroyed() && !this.isClosing()) this.completeEntranceVisuals();
      this.openEntranceGate();
    }, this.motion.gateFallbackMs);
  }

  /** init 等待入场动画结束：动画 onFinish 或兜底超时先到者放行。 */
  waitEntranceGate(): Promise<void> {
    return this.gate;
  }

  openEntranceGate(): void {
    const resolve: (() => void) | null = this.gateResolve;
    this.gateResolve = null;
    if (resolve !== null) resolve();
  }

  private completeEntranceVisuals(): void {
    this.access.setWholeCardScale(1);
    this.access.setWholeCardTranslateX(0);
    this.access.setWholeCardTranslateY(0);
    this.access.setWholeCardRadius(0);
    this.access.setWholeCardSnapshotOpacity(0);
    this.access.setWholeCardAnimating(false);
    this.access.setHeroOpacity(0);
    this.access.setContentOpacity(1);
  }

  triggerWholeCardExpansion(): void {
    if (!this.access.isFromWholeCard() || this.isDestroyed() || this.isClosing()) return;
    this.uiContext().postFrameCallback(new HeroFrameCallback(() => {
      if (this.isDestroyed() || this.isClosing()) return;
      this.uiContext().animateTo({ duration: this.motion.wholeCardExpandMs, curve: Curve.EaseInOut, onFinish: () => {
        this.access.setWholeCardSnapshotOpacity(0);
        this.access.setWholeCardAnimating(false);
        this.openEntranceGate();
      } }, () => {
        this.access.setWholeCardScale(1);
        this.access.setWholeCardTranslateX(0);
        this.access.setWholeCardTranslateY(0);
        this.access.setWholeCardClipHeight(this.getScreenHeightVp());
        this.access.setWholeCardRadius(0);
      });
      this.uiContext().animateTo({ duration: this.motion.wholeCardContentMs, curve: Curve.Sharp }, () => {
        this.access.setContentOpacity(1);
      });
      this.uiContext().animateTo({ duration: this.motion.wholeCardSnapshotFadeMs,
        delay: this.motion.wholeCardSnapshotFadeDelayMs, curve: Curve.Sharp }, () => {
        this.access.setWholeCardSnapshotOpacity(0);
      });
    }));
  }

  /** 有 srcRect 时，首帧只把一张独立封面放在源卡片封面上。 */
  prepareCardEntrance(): void {
    const rect = this.getSrcRect();
    if (rect === undefined || rect.w <= 0 || rect.h <= 0) return;
    if (this.measureHeroRect() === undefined) return;
    this.access.setFromRect(true);
    this.access.setContentOpacity(0);
    this.access.setHeroSource(this.getCoverUrl());
    this.access.setHeroX(rect.x);
    this.access.setHeroY(rect.y);
    this.access.setHeroWidth(rect.w);
    this.access.setHeroHeight(rect.h);
    this.access.setHeroRadius(this.motion.cardCoverRadius);
    this.access.setHeroOpacity(1);
    this.access.setHeroVisible(true);
    this.access.setEntranceArmed(true);
  }

  /** VSync 驱动封面飞向播放区；正文稍后淡入，不再出现缩小的完整详情页。 */
  triggerEntranceExpansion(): void {
    if (!this.access.isEntranceArmed() || this.isDestroyed() || this.isClosing()) return;
    this.access.setEntranceArmed(false);
    const target: ImageViewerSrcRect | undefined = this.measureHeroRect();
    if (target === undefined) {
      this.access.setHeroVisible(false);
      this.access.setContentOpacity(1);
      this.openEntranceGate();
      return;
    }
    this.uiContext().postFrameCallback(new HeroFrameCallback(() => {
      if (this.isDestroyed() || this.isClosing()) return;
      this.uiContext().animateTo({ duration: this.motion.cardFlightMs, curve: Curve.EaseOut, onFinish: () => {
        // 节点透明保活：返回时复用同一张已解码封面，避免重新创建 Image 导致卡顿。
        this.access.setHeroOpacity(0);
        this.openEntranceGate();
      } }, () => {
        this.access.setHeroX(target.x);
        this.access.setHeroY(target.y);
        this.access.setHeroWidth(target.w);
        this.access.setHeroHeight(target.h);
        this.access.setHeroRadius(0);
      });
      this.uiContext().animateTo({ duration: this.motion.cardContentMs,
        delay: this.motion.cardContentDelayMs, curve: Curve.EaseOut }, () => {
        this.access.setContentOpacity(1);
      });
    }));
  }

  private beginHeroNavPop(): void {
    AppStorage.setOrCreate<boolean>(this.keys.activeKey, true);
    AppStorage.setOrCreate<number>(this.keys.durationKey, this.motion.popDurationMs);
    AppNavStack.pop();
  }

  private finishHeroNavPop(): void {
    const request: number = AppStorage.get<number>(this.keys.finishRequestKey) ?? 0;
    AppStorage.setOrCreate<number>(this.keys.finishRequestKey, request + 1);
  }

  /** 镜面退出的动画主体（goBack 的 closing 防重入之后）：整卡收合或封面收回源卡片，最后兜底直接 pop。 */
  runCloseTransition(): void {
    if (this.isMirrorReturnDisabled()) {
      AppNavStack.pop();
      return;
    }
    const cardRect: ImageViewerSrcRect | undefined = this.getCardRect();
    if (this.access.isFromWholeCard() && cardRect !== undefined && this.getScreenWidthVp() > 0) {
      const rect: ImageViewerSrcRect = cardRect;
      const scale: number = rect.w / this.getScreenWidthVp();
      const clipHeight: number = rect.h / scale;
      // 从正常的整屏布局切回固定尺寸动画层；两者此刻视觉尺寸相同，不会产生跳帧。
      this.access.setWholeCardScale(1);
      this.access.setWholeCardTranslateX(0);
      this.access.setWholeCardTranslateY(0);
      this.access.setWholeCardClipHeight(this.getScreenHeightVp());
      this.access.setWholeCardRadius(0);
      this.access.setWholeCardSnapshotOpacity(0);
      this.access.setContentOpacity(1);
      this.access.setWholeCardAnimating(true);
      this.uiContext().postFrameCallback(new HeroFrameCallback(() => {
        this.beginHeroNavPop();
        this.uiContext().animateTo({ duration: this.motion.wholeCardCollapseMs, curve: Curve.EaseInOut,
          onFinish: () => {
            this.finishHeroNavPop();
          } }, () => {
          this.access.setWholeCardScale(scale);
          this.access.setWholeCardTranslateX(rect.x - (this.getScreenWidthVp() - rect.w) / 2);
          this.access.setWholeCardTranslateY(rect.y - (clipHeight - rect.h) / 2);
          this.access.setWholeCardClipHeight(clipHeight);
          this.access.setWholeCardRadius(this.motion.cardCornerVp / scale);
        });
        this.uiContext().animateTo({ duration: this.motion.exitSnapshotInMs,
          delay: this.motion.exitSnapshotInDelayMs, curve: Curve.Friction }, () => {
          this.access.setWholeCardSnapshotOpacity(1);
        });
        this.uiContext().animateTo({ duration: this.motion.exitContentOutMs,
          delay: this.motion.exitContentOutDelayMs, curve: Curve.Friction }, () => {
          this.access.setContentOpacity(0);
        });
      }));
      return;
    }
    const rect = this.getSrcRect();
    if (this.access.isFromRect() && rect !== undefined) {
      const start: ImageViewerSrcRect | undefined = this.measureHeroRect();
      if (start !== undefined) {
        this.access.setHeroSource(this.getCoverUrl());
        this.access.setHeroX(start.x);
        this.access.setHeroY(start.y);
        this.access.setHeroWidth(start.w);
        this.access.setHeroHeight(start.h);
        this.access.setHeroRadius(0);
        this.access.setHeroVisible(true);
        this.access.setHeroOpacity(1);
        this.uiContext().postFrameCallback(new HeroFrameCallback(() => {
          this.beginHeroNavPop();
          this.uiContext().animateTo({ duration: this.motion.cardExitContentMs, curve: Curve.EaseOut }, () => {
            this.access.setContentOpacity(0);
          });
          this.uiContext().animateTo({ duration: this.motion.cardExitFlightMs, curve: Curve.EaseOut,
            onFinish: () => {
              this.finishHeroNavPop();
            } }, () => {
            this.access.setHeroX(rect.x);
            this.access.setHeroY(rect.y);
            this.access.setHeroWidth(rect.w);
            this.access.setHeroHeight(rect.h);
            this.access.setHeroRadius(this.motion.cardCoverRadius);
          });
        }));
        return;
      }
    }
    AppNavStack.pop();
  }

}
