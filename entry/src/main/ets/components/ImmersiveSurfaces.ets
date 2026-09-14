/** HDS 原生材质和渐变遮罩分层，搜索和底栏使用同一套系统光感。 */
import { HdsTabs, DividerMode, hdsMaterial } from '@kit.UIDesignKit';

@Component
export struct GlassCapsuleSurface {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @Prop surfaceHeight: number = 35;
  @State surfaceWidth: number = 270;

  build() {
    HdsTabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar('')
    }
    .width('100%').height(this.surfaceHeight)
    .barHeight(this.surfaceHeight)
    .clip(false)
    .divider({ mode: DividerMode.NONE })
    .barOverlap(true)
    .scrollable(false)
    .barFloatingStyle({
      barWidth: { smallWidth: this.surfaceWidth, mediumWidth: this.surfaceWidth, largeWidth: this.surfaceWidth },
      barSideMargin: 0, barBottomMargin: 0,
      gradientMask: { maskColor: Color.Transparent, maskHeight: 0 },
      systemMaterialEffect: {
        materialType: this.glassOn ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.NONE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    })
    .barBackgroundColor(this.glassOn ? Color.Transparent : (this.isDark ? '#292B32' : '#EDEFF2'))
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_old: Area, area: Area): void => {
      const width: number = Number(area.width);
      if (width > 0 && width !== this.surfaceWidth) this.surfaceWidth = width;
    })
  }
}

/** 全宽背景与局部材质分层。遮罩只作用于模糊背板，不模糊频道文字。 */
@Component
export struct ImmersiveEdgeMask {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @Prop maskHeight: number = 100;
  @Prop topEdge: boolean = false;

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundEffect({ radius: this.glassOn ? 56 : 0, saturation: 1.1,
          color: this.glassOn ? (this.isDark ? '#1818191C' : '#18F1F3F5') :
            (this.isDark ? '#F218191C' : '#F2F1F3F5') })
      Column()
        .width('100%').height('100%')
        .linearGradient({ angle: this.topEdge ? 180 : 0,
          colors: [['#FFFFFFFF', 0], ['#FFFFFFFF', 0.5], ['#B3FFFFFF', 0.73], ['#00FFFFFF', 1]] })
        .blendMode(BlendMode.DST_IN)
    }
    .width('100%').height(this.maskHeight)
    .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
    .hitTestBehavior(HitTestMode.None)
  }
}
