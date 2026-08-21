import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { display, FrameCallback } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  ImageViewerParam, ImageViewerSrcRect } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { BackButton } from '../components/BackButton';
import { biliImageThumbnail } from '../common/ImageUrl';

/** 返回分三段：hero 落位、与来源缩略图交叉淡化、最后完成 Navigation pop。 */
const IMAGE_HERO_ENTER_DURATION: number = 280;
const IMAGE_BG_ENTER_DURATION: number = 260;
const IMAGE_HERO_RETURN_DURATION: number = 260;
const IMAGE_HERO_HANDOFF_DURATION: number = 90;
const IMAGE_BG_RETURN_DURATION: number = 330;
const IMAGE_NAV_RETURN_DURATION: number = 400;

/** 用 VSync 驱动 hero 首帧提交，避免固定 setTimeout 在高刷/负载变化时跳过起始矩形。 */
class ImageHeroFrameCallback extends FrameCallback {
  private task: () => void;

  constructor(task: () => void) {
    super();
    this.task = task;
  }

  onFrame(_frameTimeInNano: number): void {
    this.task();
  }
}

@Component
struct ZoomableImage {
  @Prop source: string = '';
  @Prop previewSource: string = '';
  @Prop transitionId: string = '';
  @Prop snapshotId: string = '';
  onLongPress: () => void = () => {};
  onZoomChange: (zoomed: boolean) => void = () => {};
  onNaturalSize: (width: number, height: number) => void = () => {};
  /** 单击：参数=是否落在图片内容上。命中内容→切换顶/底 UI 栏（捏合误识别单击不会弹掉查看器）；
   * 落在黑色留白区→关闭查看器。 */
  onSingleTap: (hitContent: boolean) => void = () => {};
  @State scaleValue: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  /** 图片源原始像素尺寸（onComplete 回传，仅用宽高比，单位无关）。 */
  private naturalW: number = 0;
  private naturalH: number = 0;
  private pinchBase: number = 1;
  private pinchBaseX: number = 0;
  private pinchBaseY: number = 0;
  private pinchCenterX: number = 0;
  private pinchCenterY: number = 0;
  private panBaseX: number = 0;
  private panBaseY: number = 0;

  aboutToAppear(): void {
    // 首帧 onAreaChange 会把视口尺寸写入 viewportWidth/Height。若初始为 0，首帧布局阶段
    // 即发生 0→满屏 的状态变更——在 bindContentCover(ModalTransition.NONE) 的提交事务里
    // 首帧写 @State 会造成 ModalPage 同帧回滚（看图一闪即关、封面盖不回来）。
    // 先按屏幕尺寸预填，使首次回调成为同值无操作。
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.viewportWidth = d.width;
      this.viewportHeight = d.height;
    } catch (e) {
      // 取不到屏幕尺寸时保持 0，首帧 onAreaChange 再兜底写入。
    }
  }

  private clampScale(value: number): number {
    return Math.max(1, Math.min(5, value));
  }

  private clampX(value: number, scale: number): number {
    const limit: number = Math.max(0, this.viewportWidth * 0.5 * (scale - 1));
    return Math.max(-limit, Math.min(limit, value));
  }

  private clampY(value: number, scale: number): number {
    const limit: number = Math.max(0, this.viewportHeight * 0.5 * (scale - 1));
    return Math.max(-limit, Math.min(limit, value));
  }

  /** 点击点（视口坐标）是否落在图片实际显示内容上（ObjectFit.Contain 黑边之外区域不算）。 */
  private hitContent(x: number, y: number): boolean {
    if (this.naturalW <= 0 || this.naturalH <= 0) return true;
    const ar: number = this.naturalW / this.naturalH;
    let baseW: number = this.viewportWidth;
    let baseH: number = this.viewportWidth / ar;
    if (baseH > this.viewportHeight) {
      baseH = this.viewportHeight;
      baseW = this.viewportHeight * ar;
    }
    const w: number = baseW * this.scaleValue;
    const h: number = baseH * this.scaleValue;
    const cx: number = this.viewportWidth * 0.5 + this.offsetX;
    const cy: number = this.viewportHeight * 0.5 + this.offsetY;
    // 边缘留 12px 容差：贴着画面边界的点击按内容处理，避免"点画面却关了"的误判。
    return Math.abs(x - cx) <= w * 0.5 + 12 && Math.abs(y - cy) <= h * 0.5 + 12;
  }

  /** 保持 focus 对应的图片内容缩放前后仍停在 focus 下方。 */
  private zoomAt(targetScale: number, focusX: number, focusY: number, animated: boolean): void {
    const nextScale: number = this.clampScale(targetScale);
    const ratio: number = nextScale / Math.max(0.01, this.scaleValue);
    const centeredX: number = focusX - this.viewportWidth * 0.5;
    const centeredY: number = focusY - this.viewportHeight * 0.5;
    const nextX: number = this.clampX(centeredX - (centeredX - this.offsetX) * ratio, nextScale);
    const nextY: number = this.clampY(centeredY - (centeredY - this.offsetY) * ratio, nextScale);
    const update = (): void => {
      this.scaleValue = nextScale;
      this.offsetX = nextX;
      this.offsetY = nextY;
    };
    if (animated) this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, update);
    else update();
    this.onZoomChange(nextScale > 1.05);
  }

  private resetTransform(animated: boolean): void {
    const update = (): void => {
      this.scaleValue = 1;
      this.offsetX = 0;
      this.offsetY = 0;
    };
    if (animated) this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, update);
    else update();
    this.onZoomChange(false);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.source)
        .alt(this.previewSource)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .id(this.snapshotId)
        // 记录源图原始像素尺寸：单击时据此区分"点在画面上"与"点在黑色留白区"。
        .onComplete((event) => {
          if (event !== undefined) {
            this.naturalW = Number(event.width);
            this.naturalH = Number(event.height);
            this.onNaturalSize(this.naturalW, this.naturalH);
          }
        })
        // Navigation 栈下用 geometryTransition（一镜到底）；旧 sharedTransition 只对 legacy router 生效。
        .geometryTransition(this.transitionId)
        .scale({ x: this.scaleValue, y: this.scaleValue })
        .translate({ x: this.offsetX, y: this.offsetY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => {
                this.pinchBase = this.scaleValue;
                this.pinchBaseX = this.offsetX;
                this.pinchBaseY = this.offsetY;
                this.pinchCenterX = event.pinchCenterX;
                this.pinchCenterY = event.pinchCenterY;
              })
              .onActionUpdate((event: GestureEvent) => {
                const nextScale: number = this.clampScale(this.pinchBase * event.scale);
                const ratio: number = nextScale / Math.max(0.01, this.pinchBase);
                const startX: number = this.pinchCenterX - this.viewportWidth * 0.5;
                const startY: number = this.pinchCenterY - this.viewportHeight * 0.5;
                const currentX: number = event.pinchCenterX - this.viewportWidth * 0.5;
                const currentY: number = event.pinchCenterY - this.viewportHeight * 0.5;
                // 缩放与两指中心移动一起计算；锚点不再固定在画面中心。
                this.offsetX = this.clampX(currentX - (startX - this.pinchBaseX) * ratio, nextScale);
                this.offsetY = this.clampY(currentY - (startY - this.pinchBaseY) * ratio, nextScale);
                this.scaleValue = nextScale;
                this.onZoomChange(this.scaleValue > 1.05);
                if (this.scaleValue <= 1.01) this.resetTransform(false);
              })
              .onActionEnd(() => {
                if (this.scaleValue < 1.05) this.resetTransform(true);
              }),
            // 原始尺寸下不要截获横滑，交由外层 Swiper 切换图片。
            PanGesture({ fingers: 1, direction: this.scaleValue > 1.05 ? PanDirection.All : PanDirection.None, distance: 1 })
              .onActionStart(() => {
                this.panBaseX = this.offsetX;
                this.panBaseY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.scaleValue <= 1) return;
                // 高倍缩放时同样的手指位移在画面上显得偏慢，做有上限的倍率补偿保持跟手。
                const followRate: number = Math.min(1.6, 0.75 + this.scaleValue * 0.35);
                this.offsetX = this.clampX(this.panBaseX + event.offsetX * followRate, this.scaleValue);
                this.offsetY = this.clampY(this.panBaseY + event.offsetY * followRate, this.scaleValue);
              }),
            // 单击/双击互斥识别：双击缩放优先，单击等待双击超时后退出查看器。
            GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2 })
                .onAction((event: GestureEvent) => {
                  if (this.scaleValue > 1.05) this.resetTransform(true);
                  else {
                    const finger: FingerInfo | undefined = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
                    const focusX: number = finger !== undefined ? finger.localX : this.viewportWidth * 0.5;
                    const focusY: number = finger !== undefined ? finger.localY : this.viewportHeight * 0.5;
                    this.zoomAt(2.5, focusX, focusY, true);
                  }
                }),
              TapGesture({ count: 1 })
                .onAction((event: GestureEvent) => {
                  const finger: FingerInfo | undefined = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
                  const x: number = finger !== undefined ? finger.localX : this.viewportWidth * 0.5;
                  const y: number = finger !== undefined ? finger.localY : this.viewportHeight * 0.5;
                  this.onSingleTap(this.hitContent(x, y));
                })
            )
          )
        )
        // Swiper 的横滑识别会与图片长按竞争；高优先级长按保证按住图片一定弹出操作菜单。
        .priorityGesture(
          LongPressGesture({ fingers: 1, repeat: false, duration: 450 })
            .onAction(() => this.onLongPress())
        )
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number.parseFloat(String(newValue.width));
      const height: number = Number.parseFloat(String(newValue.height));
      if (Number.isFinite(width) && width > 0) this.viewportWidth = width;
      if (Number.isFinite(height) && height > 0) this.viewportHeight = height;
    })
  }
}

@Component
export struct ImageViewerPage {
  param: ImageViewerParam = { images: [], initialIndex: 0 };
  @State currentIndex: number = 0;
  @State saving: boolean = false;
  @State actionMenuOpen: boolean = false;
  @State currentZoomed: boolean = false;
  /** 黑底：首帧直接置为不透明，避免从底层白页淡入造成黑白闪烁。 */
  @State bgOpacity: number = 1;
  /** 每张图是否已切换为原图（默认只加载缩略图，点"查看原图"才加载原图，节约内存） */
  @State originalFlags: Array<boolean> = [];
  /** 顶/底 UI 栏（返回键、查看原图、页码）显隐：单击切换。对齐 B 站官方——单击不关闭，避免缩放手势误触直接退出。 */
  @State uiVisible: boolean = true;
  /** 原图 HEAD 体积过小视为低清图，不展示“查看原图”入口。 */
  @State lowResFlags: Array<boolean> = [];
  @State originalSizeText: string = '';
  private sizeCache: Map<number, string> = new Map<number, string>();
  @StorageProp('imageViewerCloseRequest') @Watch('onCloseRequested') closeRequest: number = 0;
  @State closing: boolean = false;
  /** 根 Tabs 手工 hero：只移动一张不透明图片，Swiper、黑底、控件不再共用同一组变换。 */
  @State viewerOpacity: number = 1;
  @State uiOpacity: number = 1;
  @State heroVisible: boolean = false;
  @State heroSource: string = '';
  @State heroX: number = 0;
  @State heroY: number = 0;
  @State heroWidth: number = 0;
  @State heroHeight: number = 0;
  @State heroRadius: number = 0;
  @State heroOpacity: number = 1;
  /** GIF 返回时冻结的当前播放帧；避免两个 Image 动画时间轴不同导致切层闪烁。 */
  @State heroFrame: image.PixelMap | null = null;
  /** 入场结束前屏蔽图片手势，避免打开动作的抬起事件穿透到新页面并立即触发关闭。 */
  @State interactionReady: boolean = true;
  private entryFromRect: boolean = false;
  private heroEntranceStarted: boolean = false;
  private heroNaturalWidth: number = 0;
  private heroNaturalHeight: number = 0;
  private naturalSizes: Map<number, ImageViewerSrcRect> = new Map<number, ImageViewerSrcRect>();
  private heroFallbackTimer: number = -1;
  /** 入场飞行结束后必须等 Swiper 内的目标 Image 真正解码，再做两张图的纹理交接。 */
  private heroFlightFinished: boolean = false;
  private heroHandoffTimer: number = -1;
  /** 退出时先在当前大图上方预解码 hero，再交叉淡化并开始 pop，避免首帧空纹理。 */
  private heroExitPending: boolean = false;
  private heroExitTarget: ImageViewerSrcRect | undefined = undefined;
  private heroExitTimer: number = -1;
  private interactionReadyTimer: number = -1;
  private swiperController: SwiperController = new SwiperController();
  /** 低于此体积（3MB）的图片直接加载原图，不再先缩略图后手动“查看原图”。 */
  private static readonly ORIGINAL_SIZE_THRESHOLD: number = 3 * 1024 * 1024;

  aboutToAppear(): void {
    this.closing = false;
    this.entryFromRect = false;
    this.heroEntranceStarted = false;
    this.heroFlightFinished = false;
    this.heroExitPending = false;
    this.heroExitTarget = undefined;
    this.heroVisible = false;
    this.heroOpacity = 1;
    this.heroFrame = null;
    this.naturalSizes.clear();
    this.interactionReady = true;
    this.viewerOpacity = 1;
    this.uiOpacity = 1;
    this.bgOpacity = 1;
    this.currentIndex = Math.max(0, Math.min(this.param.images.length - 1, this.param.initialIndex));
    Immersive.setBarIcons(true, true);
    this.originalFlags = this.param.images.map(() => false);
    this.lowResFlags = this.param.images.map(() => false);
    this.fetchOriginalSize(this.currentIndex);
    this.prepareRectEntrance();
    // @State 从 0 改到 initialIndex 会让 Swiper 在首帧自动“滑过去”。改由官方 controller
    // 无动画定位，hero 结束时底下已经是被点击的那一张。
    this.getUIContext().postFrameCallback(new ImageHeroFrameCallback(() => {
      this.swiperController.changeIndex(this.currentIndex, false);
    }));
  }

  /** 有 srcRect 时先让独立 hero 与源缩略图完全重合；图片解码完成后按原始比例飞到 Contain 落点。 */
  private prepareRectEntrance(): void {
    // 来源与当前大图存在同名 geometryTransition 时由 ArkUI 复用同一个渲染节点，
    // 不再额外创建 hero Image，避免退出时二次解码/上传纹理造成闪帧。
    if (this.hasSystemGeometryTransition()) return;
    const rect: ImageViewerSrcRect | undefined = this.sourceRectFor(this.currentIndex);
    if (rect === undefined || rect.w <= 0 || rect.h <= 0) return;
    this.entryFromRect = true;
    this.heroEntranceStarted = false;
    this.heroSource = this.sourcePreviewFor(this.currentIndex);
    this.heroX = rect.x;
    this.heroY = rect.y;
    this.heroWidth = rect.w;
    this.heroHeight = rect.h;
    this.heroRadius = 8;
    this.heroOpacity = 1;
    this.heroVisible = true;
    this.interactionReady = false;
    this.viewerOpacity = 0;
    this.uiOpacity = 0;
    this.bgOpacity = 0;
    // 背景变暗不等待图片二次解码；否则冷缓存图片超过 Navigation 保活时长时，
    // 来源页先消失、黑底后出现，会形成只有部分图片可见的亮色闪帧。
    this.getUIContext().postFrameCallback(new ImageHeroFrameCallback(() => {
      if (this.closing) return;
      this.getUIContext().animateTo({ duration: IMAGE_BG_ENTER_DURATION, curve: Curve.EaseInOut }, () => {
        this.bgOpacity = 1;
      });
    }));
    // 图片若异常未回调 onComplete，不能让查看器永久停在缩略图状态。
    this.heroFallbackTimer = setTimeout(() => {
      if (!this.heroEntranceStarted && !this.closing) this.finishHeroEntranceWithoutFlight();
    }, 600);
  }

  private sourceRectFor(index: number): ImageViewerSrcRect | undefined {
    const rects: Array<ImageViewerSrcRect> | undefined = this.param.srcRects;
    if (rects !== undefined && index >= 0 && index < rects.length) {
      const rect: ImageViewerSrcRect = rects[index];
      if (rect.w > 0 && rect.h > 0) return rect;
    }
    if (index === this.param.initialIndex && this.param.srcRect !== undefined &&
      this.param.srcRect.w > 0 && this.param.srcRect.h > 0) return this.param.srcRect;
    return undefined;
  }

  /**
   * 退出时不再使用打开瞬间缓存的旧坐标：来源页仍保留在 Navigation 栈内，可按组件 ID
   * 读取当前窗口位置。若对应缩略图已经滚出屏幕，宁可就地淡出，也不飞向屏外旧位置。
   */
  private exitSourceRectFor(index: number): ImageViewerSrcRect | undefined {
    const ids: Array<string> | undefined = this.param.srcIds;
    if (ids === undefined || index < 0 || index >= ids.length || ids[index].length === 0) {
      return this.sourceRectFor(index);
    }
    try {
      const area = this.getUIContext().getComponentUtils().getRectangleById(ids[index]);
      const x: number = this.getUIContext().px2vp(area.windowOffset.x);
      const y: number = this.getUIContext().px2vp(area.windowOffset.y);
      const w: number = this.getUIContext().px2vp(area.size.width);
      const h: number = this.getUIContext().px2vp(area.size.height);
      const screenW: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
      const screenH: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().height);
      if (w <= 0 || h <= 0 || x >= screenW || y >= screenH || x + w <= 0 || y + h <= 0) return undefined;
      return { x: x, y: y, w: w, h: h };
    } catch (e) {
      return undefined;
    }
  }

  private rememberNaturalSize(index: number, width: number, height: number): void {
    if (width <= 0 || height <= 0) return;
    this.naturalSizes.set(index, { x: 0, y: 0, w: width, h: height });
    if (index === this.param.initialIndex) {
      this.heroNaturalWidth = width;
      this.heroNaturalHeight = height;
    }
    if (index === this.param.initialIndex) this.finishHeroEntranceHandoff(false);
  }

  private beginHeroNavPop(duration: number): void {
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
    AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, duration);
    AppNavStack.pop();
  }

  /** 原图按 ImageFit.Contain 落在全屏视口中的实际可见矩形。 */
  private containRect(naturalWidth: number, naturalHeight: number): ImageViewerSrcRect | undefined {
    if (naturalWidth <= 0 || naturalHeight <= 0) return undefined;
    try {
      const vpW: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
      const vpH: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().height);
      if (vpW <= 0 || vpH <= 0) return undefined;
      const imageRatio: number = naturalWidth / naturalHeight;
      const viewportRatio: number = vpW / vpH;
      if (imageRatio >= viewportRatio) {
        const h: number = vpW / imageRatio;
        return { x: 0, y: (vpH - h) / 2, w: vpW, h: h };
      }
      const w: number = vpH * imageRatio;
      return { x: (vpW - w) / 2, y: 0, w: w, h: vpH };
    } catch (e) {
      return undefined;
    }
  }

  private startHeroEntrance(naturalWidth: number, naturalHeight: number): void {
    if (!this.entryFromRect || this.heroEntranceStarted || this.closing) return;
    const target: ImageViewerSrcRect | undefined = this.containRect(naturalWidth, naturalHeight);
    if (target === undefined) {
      this.finishHeroEntranceWithoutFlight();
      return;
    }
    this.heroEntranceStarted = true;
    this.heroNaturalWidth = naturalWidth;
    this.heroNaturalHeight = naturalHeight;
    if (this.heroFallbackTimer >= 0) {
      clearTimeout(this.heroFallbackTimer);
      this.heroFallbackTimer = -1;
    }
    this.getUIContext().postFrameCallback(new ImageHeroFrameCallback(() => {
      if (this.closing) return;
      this.getUIContext().animateTo({ duration: IMAGE_HERO_ENTER_DURATION, curve: Curve.EaseOut, onFinish: () => {
        // Swiper 先放到 hero 下方；是否淡掉 hero 由 Image.onComplete 决定，不能只按固定
        // 帧数猜解码速度。冷缓存图片比动画慢时，固定延迟仍会露出一帧黑底。
        this.viewerOpacity = 1;
        this.heroFlightFinished = true;
        this.finishHeroEntranceHandoff(false);
        if (this.heroFlightFinished) {
          this.heroHandoffTimer = setTimeout(() => {
            this.heroHandoffTimer = -1;
            this.finishHeroEntranceHandoff(true);
          }, 700);
        }
        this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
          this.uiOpacity = 1;
        });
      } }, () => {
        this.heroX = target.x;
        this.heroY = target.y;
        this.heroWidth = target.w;
        this.heroHeight = target.h;
        this.heroRadius = 0;
      });
    }));
  }

  /** hero 与 Swiper 的纹理都已就绪后再交叉淡化；force 仅用于异常图片的有界兜底。 */
  private finishHeroEntranceHandoff(force: boolean): void {
    if (!this.heroFlightFinished || !this.heroVisible || this.closing) return;
    if (!force && !this.naturalSizes.has(this.param.initialIndex)) return;
    this.heroFlightFinished = false;
    if (this.heroHandoffTimer >= 0) {
      clearTimeout(this.heroHandoffTimer);
      this.heroHandoffTimer = -1;
    }
    this.getUIContext().animateTo({ duration: 76, curve: Curve.EaseOut, onFinish: () => {
      // 保持透明 hero 节点常驻并保留已解码纹理。返回时复用同一个 Image，避免重新插入
      // 节点触发纹理上传而在大图上方闪出一帧。
      this.heroOpacity = 0;
      this.enableInteractionAfterTapSettles();
    } }, () => {
      this.heroOpacity = 0;
    });
  }

  private finishHeroEntranceWithoutFlight(): void {
    this.heroEntranceStarted = true;
    this.heroFlightFinished = false;
    this.heroVisible = false;
    this.heroOpacity = 1;
    this.enableInteractionAfterTapSettles();
    this.viewerOpacity = 1;
    this.bgOpacity = 1;
    this.uiOpacity = 1;
  }

  /** Exclusive 单/双击会延迟派发单击；再等一小段，确保打开页面的那次 tap 不会被新页面接走。 */
  private enableInteractionAfterTapSettles(): void {
    if (this.interactionReadyTimer >= 0) clearTimeout(this.interactionReadyTimer);
    this.interactionReadyTimer = setTimeout(() => {
      this.interactionReadyTimer = -1;
      if (!this.closing) this.interactionReady = true;
    }, 260);
  }

  onCloseRequested(): void {
    this.goBack();
  }

  goBack(): void {
    if (this.closing) return;
    this.closing = true;
    this.interactionReady = false;
    if (this.heroFallbackTimer >= 0) {
      clearTimeout(this.heroFallbackTimer);
      this.heroFallbackTimer = -1;
    }
    if (this.interactionReadyTimer >= 0) {
      clearTimeout(this.interactionReadyTimer);
      this.interactionReadyTimer = -1;
    }
    if (this.heroHandoffTimer >= 0) {
      clearTimeout(this.heroHandoffTimer);
      this.heroHandoffTimer = -1;
    }
    if (this.heroExitTimer >= 0) {
      clearTimeout(this.heroExitTimer);
      this.heroExitTimer = -1;
    }
    if (this.hasSystemGeometryTransition()) {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        AppNavStack.pop(false);
      });
      return;
    }
    // 根 Tabs 没有稳定的跨 Navigation 共享节点：仅把当前图片的独立 hero 镜面收回最初缩略图。
    // 已横滑到别张图片时源矩形已不匹配，改为短淡出，避免图片飞到错误卡片。
    const targetRect: ImageViewerSrcRect | undefined = this.exitSourceRectFor(this.currentIndex);
    const natural: ImageViewerSrcRect | undefined = this.naturalSizes.get(this.currentIndex);
    const naturalWidth: number = natural !== undefined ? natural.w :
      (this.currentIndex === this.param.initialIndex ? this.heroNaturalWidth : 0);
    const naturalHeight: number = natural !== undefined ? natural.h :
      (this.currentIndex === this.param.initialIndex ? this.heroNaturalHeight : 0);
    if (this.entryFromRect && targetRect !== undefined && naturalWidth > 0 && naturalHeight > 0) {
      const start: ImageViewerSrcRect | undefined = this.containRect(naturalWidth, naturalHeight);
      if (start !== undefined) {
        const target: ImageViewerSrcRect = targetRect;
        this.freezeCurrentGifFrame(start);
        const exitSource: string = this.sourcePreviewFor(this.currentIndex);
        const residentHero: boolean = this.heroVisible && this.heroSource === exitSource;
        if (!residentHero) this.heroSource = exitSource;
        this.heroX = start.x;
        this.heroY = start.y;
        this.heroWidth = start.w;
        this.heroHeight = start.h;
        this.heroRadius = 0;
        // 先以透明状态创建并解码退出 hero，当前 Swiper 图片继续垫底；否则同一帧
        // 隐藏 Swiper、显示新 Image 时仍可能露出黑底。
        this.heroOpacity = 0;
        this.heroVisible = true;
        this.heroExitTarget = target;
        this.heroExitPending = true;
        if (residentHero) {
          // 节点与纹理均已在组件树中，下一帧即可开始交叉淡化，无需重新解码等待。
          this.getUIContext().postFrameCallback(new ImageHeroFrameCallback(() => this.startHeroExitFlight()));
        } else {
          this.heroExitTimer = setTimeout(() => {
            this.heroExitTimer = -1;
            this.startHeroExitFlight();
          }, 260);
        }
        return;
      }
    }
    if (this.entryFromRect) {
      this.beginHeroNavPop(420);
      this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
        this.viewerOpacity = 0;
        this.uiOpacity = 0;
      });
      this.getUIContext().animateTo({ duration: 380, curve: Curve.EaseInOut }, () => {
        this.bgOpacity = 0;
      });
      return;
    }
    // 保持黑底不先淡出，直接让 geometryTransition 把图片缩回缩略图；
    // 如果先 fade 黑底，收缩动画会被白底/透明底盖掉，看起来像没有缩小动画。
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
      AppNavStack.pop(false);
    });
  }

  /** 退出 hero 解码完成后先覆盖当前大图，再启动缩回及 Navigation pop。 */
  private startHeroExitFlight(): void {
    if (!this.closing || !this.heroExitPending || this.heroExitTarget === undefined) return;
    this.heroExitPending = false;
    if (this.heroExitTimer >= 0) {
      clearTimeout(this.heroExitTimer);
      this.heroExitTimer = -1;
    }
    const target: ImageViewerSrcRect = this.heroExitTarget;
    this.getUIContext().animateTo({ duration: 60, curve: Curve.EaseOut, onFinish: () => {
      // hero 已经完全盖住当前大图，此时再瞬时移除底图不会改变画面。
      // 不能让两张图同时做反向透明度交叉：在黑底上 alpha 合成的中间帧会变暗，
      // 表现为按下返回的瞬间闪一下。
      this.viewerOpacity = 0;
      this.getUIContext().postFrameCallback(new ImageHeroFrameCallback(() => {
        this.beginHeroNavPop(IMAGE_NAV_RETURN_DURATION);
        this.getUIContext().animateTo({ duration: IMAGE_HERO_RETURN_DURATION, curve: Curve.EaseOut, onFinish: () => {
          // Navigation 的来源页此时已经在下层保持渲染。hero 到达缩略图后渐隐，
          // 让同位置的真实 Image 接管纹理，避免 pop 完成时整层移除造成一次硬切闪帧。
          this.getUIContext().animateTo({ duration: IMAGE_HERO_HANDOFF_DURATION, curve: Curve.EaseOut }, () => {
            this.heroOpacity = 0;
          });
        } }, () => {
          this.heroX = target.x;
          this.heroY = target.y;
          this.heroWidth = target.w;
          this.heroHeight = target.h;
          this.heroRadius = 8;
        });
        this.getUIContext().animateTo({ duration: IMAGE_BG_RETURN_DURATION, curve: Curve.EaseInOut }, () => {
          this.bgOpacity = 0;
        });
      }));
    } }, () => {
      this.heroOpacity = 1;
      this.uiOpacity = 0;
    });
  }

  private currentUrl(): string {
    return this.param.images.length > 0 ? this.param.images[this.currentIndex] : '';
  }

  /** 优先复用来源页已经显示并解码的同一档缩略图，减少新 Image 节点的冷解码闪帧。 */
  private sourcePreviewFor(index: number): string {
    const previews: Array<string> | undefined = this.param.srcPreviews;
    if (previews !== undefined && index >= 0 && index < previews.length && previews[index].length > 0) {
      return previews[index];
    }
    const source: string = index >= 0 && index < this.param.images.length ? this.param.images[index] : '';
    return this.previewUrl(source);
  }

  /** 非当前页用缩略参数图（B 站 @<宽>w 后缀），滑到该页时再加载原图。 */
  private thumbUrl(url: string): string {
    return biliImageThumbnail(url, 640);
  }

  /** 首屏展示用缩略图：先快速加载小图，点“查看原图”才切原图。 */
  private previewUrl(url: string): string {
    return biliImageThumbnail(url, 640);
  }

  private isOriginal(index: number): boolean {
    return index >= 0 && index < this.originalFlags.length && this.originalFlags[index];
  }

  /**
   * 生成当前 index 对应的共享元素 ID。
   * transitionId 只携带了打开时那一张的完整 ID，多图滑动后需要按同一前缀推导出当前图片的 ID，
   * 关闭时才能缩回当前图片对应的缩略图。
   * 注意：同一时刻只能给「当前页」绑定共享元素 ID。Swiper cachedCount 会预渲染相邻页，
   * 若每页都绑 ID，相邻页的 ID 恰好命中源页面宫格里相邻的缩略图，多对配对会让
   * geometryTransition 解析错源节点（点开图片从错误位置放大，如右上角）。
   */
  private transitionIdFor(index: number): string {
    // geometryTransition 不接受空 ID（真机会直接报 4100001，并中断图片页构建）。
    // 手动 hero 动画和非当前 Swiper 页仍给一个仅查看器内部使用、不会命中源图的稳定 ID。
    if (index !== this.currentIndex) return 'image-viewer-idle-' + String(index);
    const ids: Array<string> | undefined = this.param.transitionIds;
    if (ids !== undefined && index >= 0 && index < ids.length && ids[index].length > 0) return ids[index];
    const base: string = this.param.transitionId ?? '';
    if (base.length === 0) return 'image-viewer-manual-' + String(index);
    if (index === this.param.initialIndex) return base;
    const suffix: string = '-' + String(this.param.initialIndex);
    const prefix: string = base.endsWith(suffix) ? base.substring(0, base.length - suffix.length) : base;
    return prefix + '-' + String(index);
  }

  private snapshotIdFor(index: number): string {
    return 'image-viewer-frame-' + String(index);
  }

  private isCurrentGif(): boolean {
    const source: string = this.currentUrl().toLowerCase();
    const queryAt: number = source.indexOf('?');
    const clean: string = queryAt >= 0 ? source.substring(0, queryAt) : source;
    return clean.endsWith('.gif') || clean.indexOf('.gif@') >= 0;
  }

  /** 截取 GIF 当前已经渲染完成的画面区域，退出 hero 不再切换到另一时间轴的 GIF 节点。 */
  private freezeCurrentGifFrame(rect: ImageViewerSrcRect): void {
    this.heroFrame = null;
    if (!this.isCurrentGif()) return;
    try {
      const left: number = Math.max(0, Math.round(this.getUIContext().vp2px(rect.x)));
      const top: number = Math.max(0, Math.round(this.getUIContext().vp2px(rect.y)));
      const right: number = Math.max(left + 1, Math.round(this.getUIContext().vp2px(rect.x + rect.w)));
      const bottom: number = Math.max(top + 1, Math.round(this.getUIContext().vp2px(rect.y + rect.h)));
      this.heroFrame = this.getUIContext().getComponentSnapshot().getSync(this.snapshotIdFor(this.currentIndex), {
        waitUntilRenderFinished: true,
        region: { left: left, top: top, right: right, bottom: bottom },
      });
    } catch (e) {
      // 快照失败时沿用已验证的普通图片 hero 路径，返回操作不能被截图异常阻断。
      this.heroFrame = null;
    }
  }

  private hasSystemGeometryTransition(): boolean {
    const ids: Array<string> | undefined = this.param.transitionIds;
    if (ids !== undefined && this.currentIndex >= 0 && this.currentIndex < ids.length &&
      ids[this.currentIndex].length > 0) return true;
    return (this.param.transitionId ?? '').length > 0;
  }

  /** 查看原图：仅切换当前张，其余保持中图。 */
  private viewOriginal(): void {
    const next: Array<boolean> = this.originalFlags.slice();
    next[this.currentIndex] = true;
    this.originalFlags = next;
  }

  /** HEAD 请求读 Content-Length，给"查看原图"按钮带上文件大小；失败则不显示大小。 */
  private fetchOriginalSize(index: number): void {
    if (index < 0 || index >= this.param.images.length) return;
    if (this.sizeCache.has(index)) {
      this.originalSizeText = this.sizeCache.get(index) ?? '';
      return;
    }
    const request: http.HttpRequest = http.createHttp();
    request.request(this.param.images[index], {
      method: http.RequestMethod.HEAD,
      header: { 'Referer': 'https://www.bilibili.com/' },
      connectTimeout: 8000,
      readTimeout: 8000,
    }).then((response: http.HttpResponse) => {
      const headers: Record<string, Object> = response.header as Record<string, Object>;
      const lengthText: string = String(headers['content-length'] ?? '');
      const bytes: number = Number.parseInt(lengthText);
      let label: string = '';
      // 3MB 以下的图片打开即加载原图：体积小，先缩略图再手动换原图反而闪一次。
      const autoOriginal: boolean = Number.isFinite(bytes) && bytes > 0 &&
        bytes < ImageViewerPage.ORIGINAL_SIZE_THRESHOLD;
      const lowRes: boolean = Number.isFinite(bytes) && bytes > 0 && bytes < 200 * 1024;
      if (Number.isFinite(bytes) && bytes > 0 && !lowRes) {
        label = bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : String(Math.ceil(bytes / 1024)) + ' KB';
      }
      this.lowResFlags[index] = lowRes;
      if (autoOriginal && !this.originalFlags[index]) {
        const next: Array<boolean> = this.originalFlags.slice();
        next[index] = true;
        this.originalFlags = next;
      }
      this.sizeCache.set(index, label);
      if (index === this.currentIndex) this.originalSizeText = label;
      request.destroy();
    }).catch(() => {
      this.lowResFlags[index] = false;
      this.sizeCache.set(index, '');
      if (index === this.currentIndex) this.originalSizeText = '';
      request.destroy();
    });
  }

  private imageExtension(url: string): string {
    const clean: string = url.split('?')[0].toLowerCase();
    const dot: number = clean.lastIndexOf('.');
    if (dot >= 0) {
      const extension: string = clean.substring(dot + 1);
      if (extension === 'png' || extension === 'gif' || extension === 'webp' || extension === 'jpeg') return extension;
    }
    return 'jpg';
  }

  private async saveCurrentImage(): Promise<void> {
    const url: string = this.currentUrl();
    if (url.length === 0 || this.saving) return;
    this.saving = true;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: { 'Referer': 'https://www.bilibili.com/' },
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      if (Number(response.responseCode) < 200 || Number(response.responseCode) >= 300) {
        throw new Error('HTTP ' + response.responseCode);
      }
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const extension: string = this.imageExtension(url);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, extension,
        { title: 'BiliHarmony_' + Date.now() });
      const file: fs.File = await fs.open(uri, fs.OpenMode.READ_WRITE);
      try {
        await fs.write(file.fd, response.result as ArrayBuffer);
      } finally {
        fs.closeSync(file);
      }
      this.getUIContext().getPromptAction().showToast({ message: '已保存到图库' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请稍后重试' });
    } finally {
      request.destroy();
      this.saving = false;
    }
  }

  private shareCurrentImage(): void {
    const url: string = this.currentUrl();
    if (url.length === 0) return;
    this.actionMenuOpen = false;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: 'general.hyperlink',
      title: '分享图片',
      content: url,
      description: '来自哔哩哔哩的图片',
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开系统分享' });
    });
  }

  @Builder
  ImageActionMenu() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => this.actionMenuOpen = false)
      Column({ space: 8 }) {
        Text('图片')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F2F4')
          .width('100%')
          .padding({ left: 2, top: 2, bottom: 8 })
        Row({ space: 12 }) {
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE,
            buttonType: ButtonType.Normal })
            .width('48%')
            .height(48)
            .fontSize(14)
            .fontColor('#F2F2F4')
            .backgroundColor('#2A2C31')
            .borderRadius(14)
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              this.actionMenuOpen = false;
              if (result === SaveButtonOnClickResult.SUCCESS) this.saveCurrentImage();
            })
          Button() {
            Row({ space: 7 }) {
              Image($r('app.media.ic_share'))
                .width(18)
                .height(18)
                .renderMode(ImageRenderMode.Template)
                .fillColor('#F2F2F4')
              Text('分享').fontSize(14).fontColor('#F2F2F4')
            }
          }
          .width('48%')
          .height(48)
          .backgroundColor('#2A2C31')
          .borderRadius(14)
          .onClick(() => this.shareCurrentImage())
        }
        .width('100%')
        Text('取消')
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor('#A8ABB2')
          .textAlign(TextAlign.Center)
          .onClick(() => this.actionMenuOpen = false)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: Immersive.bottomInset() + 8 })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor('#191A1F')
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }),
      TransitionEffect.opacity(0).animation({ duration: 150, curve: Curve.EaseIn })))
  }

  aboutToDisappear(): void {
    if (this.heroFallbackTimer >= 0) {
      clearTimeout(this.heroFallbackTimer);
      this.heroFallbackTimer = -1;
    }
    if (this.interactionReadyTimer >= 0) {
      clearTimeout(this.interactionReadyTimer);
      this.interactionReadyTimer = -1;
    }
    if (this.heroHandoffTimer >= 0) {
      clearTimeout(this.heroHandoffTimer);
      this.heroHandoffTimer = -1;
    }
    if (this.heroExitTimer >= 0) {
      clearTimeout(this.heroExitTimer);
      this.heroExitTimer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .opacity(this.bgOpacity)

      if (this.param.images.length > 0) {
        Swiper(this.swiperController) {
          ForEach(this.param.images, (source: string, index: number) => {
            ZoomableImage({
              // 默认只加载 1080w 中图，点"查看原图"后该张才换原图
              source: this.isOriginal(index) ? source : this.previewUrl(source),
              // alt 与来源缩略图使用完全相同的 URL，主图冷加载时可直接复用已解码纹理。
              previewSource: this.sourcePreviewFor(index),
              transitionId: this.transitionIdFor(index),
              snapshotId: this.snapshotIdFor(index),
               onLongPress: () => {
                 if (this.interactionReady) this.actionMenuOpen = true;
               },
               onZoomChange: (zoomed: boolean) => this.currentZoomed = zoomed,
               onNaturalSize: (width: number, height: number) => this.rememberNaturalSize(index, width, height),
               onSingleTap: (hitContent: boolean) => {
                 if (!this.interactionReady) return;
                 if (hitContent) {
                   this.uiVisible = !this.uiVisible;
                 } else {
                   // 点黑色留白区＝官方客户端同款关闭手势。
                   this.goBack();
                 }
               },
            })
          }, (source: string, index: number) => source + String(index))
        }
        .width('100%')
        .height('100%')
        .indicator(false)
        .loop(false)
        .cachedCount(1)
        .disableSwipe(this.currentZoomed)
        .opacity(this.viewerOpacity)
        .onChange((index: number) => {
          this.currentIndex = index;
          this.currentZoomed = false;
          this.originalSizeText = this.sizeCache.get(index) ?? '';
          this.fetchOriginalSize(index);
        })
      }

      // 根页面的 hero 独立于 Swiper：只让一张不透明图片改变边界，避免整页控件和黑底跟着缩放。
      if (this.heroVisible && this.heroSource.length > 0) {
        Stack() {
          if (this.heroFrame !== null) {
            Image(this.heroFrame)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .hitTestBehavior(HitTestMode.None)
          } else {
            Image(this.heroSource)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .hitTestBehavior(HitTestMode.None)
              .onComplete((event) => {
                if (event === undefined) return;
                if (this.closing && this.heroExitPending) {
                  this.startHeroExitFlight();
                } else {
                  this.startHeroEntrance(Number(event.width), Number(event.height));
                }
              })
          }
        }
        .width(this.heroWidth)
        .height(this.heroHeight)
        .position({ x: this.heroX, y: this.heroY })
        .borderRadius(this.heroRadius)
        .clip(true)
        .opacity(this.heroOpacity)
        .hitTestBehavior(HitTestMode.None)
      }

      // 顶部只放返回键，页码固定在底部，不再悬在图片正中央。单击切换显隐（见 uiVisible）。
      if (this.uiVisible) {
        Column() {
          Row() {
            BackButton({ triggerWidth: 44, triggerHeight: 44, fontSize: 34, color: '#FFFFFF', nudgeY: 0,
              onBack: () => this.goBack() })
            Blank()
          }
          .width('100%')
          .padding({ left: 8, right: 12 })
          .margin({ top: Immersive.statusBarHeight() + 4 })
          Blank()
          if (!this.isOriginal(this.currentIndex) && !this.lowResFlags[this.currentIndex]) {
            Text(this.originalSizeText.length > 0 ? '查看原图 (' + this.originalSizeText + ')' : '查看原图')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(18)
              .backgroundColor('#73000000')
              .margin({ bottom: 12 })
              .onClick(() => this.viewOriginal())
          }
          if (this.param.images.length > 1) {
            Text((this.currentIndex + 1) + ' / ' + this.param.images.length)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor('#73000000')
              .margin({ bottom: Immersive.bottomInset() + 16 })
          }
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
        .opacity(this.uiOpacity)
        .transition(TransitionEffect.opacity(1).animation({ duration: 140, curve: Curve.EaseOut }))
      }

      if (this.actionMenuOpen) {
        this.ImageActionMenu()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
