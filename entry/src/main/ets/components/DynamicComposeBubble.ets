import { Handedness } from '../common/Handedness';
import { Immersive } from '../common/Immersive';

/** 发布动态入口独立订阅惯用手，换边动画不驱动动态列表刷新。 */
@Component
export struct DynamicComposeBubble {
  @StorageProp(Handedness.KEY_SIDE) @Watch('onHandSideChanged') handSide: string = Handedness.RIGHT;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @State handPosition: number = 0;
  @State containerWidth: number = 0;
  private mounted: boolean = false;
  onCompose: () => void = () => {};

  aboutToAppear(): void {
    this.handPosition = this.handSide === Handedness.LEFT ? 1 : 0;
    this.mounted = true;
  }

  aboutToDisappear(): void {
    this.mounted = false;
  }

  onHandSideChanged(): void {
    if (!this.mounted) return;
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
      this.handPosition = this.handSide === Handedness.LEFT ? 1 : 0;
    });
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_comment'))
          .width(22).height(22).fillColor('#FFFFFF')
      }
      .width(48).height(48).borderRadius(24)
      .backgroundColor(this.accent)
      .shadow({ radius: 12, color: '#66FB7299', offsetY: 3 })
      // 48vp 按钮，两侧各留 16vp；保持同一节点，点击区域随位移一起移动。
      .translate({ x: -Math.max(0, this.containerWidth - 80) * this.handPosition })
      .id('dynamic-compose-entry')
      .accessibilityText('发布动态')
      .onClick(() => this.onCompose())
      .stateStyles({
        pressed: { opacity: 0.85 },
        normal: { opacity: 1 },
      })
    }
    .width('100%').height('100%')
    .padding({ left: 16, right: 16, bottom: Immersive.bottomInset() + 88 })
    .onAreaChange((_old: Area, area: Area) => {
      this.containerWidth = Number(area.width);
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
