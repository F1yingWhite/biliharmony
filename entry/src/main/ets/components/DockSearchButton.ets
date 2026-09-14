/** 使用与 QQ 音乐相同的 HDS 底栏生成独立搜索胶囊。 */
import { AppTheme } from '../common/AppTheme';
import { Haptic } from '../common/Haptic';
import { HdsTabs, DividerMode, hdsMaterial } from '@kit.UIDesignKit';

export const DOCK_SEARCH_SIZE: number = 76;
export const DOCK_SEARCH_HEIGHT: number = 56;

@Component
export struct DockSearchButton {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('glassEnabled') glassOn: boolean = true;
  private longPressHandled: boolean = false;
  onTap: () => void = (): void => {};
  onLongPress: () => void = (): void => {};

  @Builder
  SearchAction() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.ic_search'))
        .width(26).height(26)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.accent)
        .draggable(false)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%').height('100%')
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down || event.type === TouchType.Cancel) this.longPressHandled = false;
    })
    .parallelGesture(LongPressGesture({ repeat: false }).onAction((): void => {
      this.longPressHandled = true;
      Haptic.tap();
      this.onLongPress();
    }))
    .onClick((): void => {
      if (this.longPressHandled) { this.longPressHandled = false; return; }
      Haptic.light();
      this.onTap();
    })
    .accessibilityText('搜索')
    .accessibilityDescription('轻点搜索，长按设置自动跟手或固定位置')
    .id('dock-search-entry')
  }

  build() {
    HdsTabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar(this.SearchAction())
    }
    .width(DOCK_SEARCH_SIZE).height(DOCK_SEARCH_HEIGHT)
    .clip(false)
    .barHeight(DOCK_SEARCH_HEIGHT)
    .divider({ mode: DividerMode.NONE })
    .barOverlap(true)
    .scrollable(false)
    .barFloatingStyle({
      barWidth: { smallWidth: DOCK_SEARCH_SIZE, mediumWidth: DOCK_SEARCH_SIZE, largeWidth: DOCK_SEARCH_SIZE },
      barSideMargin: 0,
      barBottomMargin: 0,
      gradientMask: { maskColor: Color.Transparent, maskHeight: 0 },
      systemMaterialEffect: {
        materialType: this.glassOn ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.NONE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    })
    .barBackgroundColor(this.glassOn ? Color.Transparent : AppTheme.floatBg(this.isDark, false))
  }
}
