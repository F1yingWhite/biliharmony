/**
 * 弹幕列表面板：竖屏弹层/横屏抽屉/设置内嵌页共用。
 * 从 PlayerView.DanmakuListPanel 拆出。
 */
import { BasicDataSource } from '../common/BasicDataSource';
import { playerPanelTitle, playerPanelSub, playerPanelRowBg } from './PlayerSheetTheme';
import { formatDuration } from '../common/Utils';
import { DanmakuItem } from '../api/BiliApi';

@Component
export struct DanmakuListPanel {
  @Prop embedded: boolean = false;
  @Prop count: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  source: BasicDataSource<DanmakuItem> = new BasicDataSource<DanmakuItem>();
  onSeek: (seconds: number) => void = (seconds: number) => {
  };
  onReport: (item: DanmakuItem) => void = (item: DanmakuItem) => {
  };
  onClose: () => void = () => {
  };

  private titleColor(): string {
    return playerPanelTitle(this.isDark);
  }

  private subColor(): string {
    return playerPanelSub(this.isDark);
  }

  private rowBg(): string {
    return playerPanelRowBg(this.isDark);
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('弹幕列表').fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.titleColor())
        Blank()
        Text(this.count > 0 ? '已加载 ' + String(this.count) + ' 条' : '暂无弹幕')
          .fontSize(11)
          .fontColor(this.subColor())
      }
      .width('100%')
      if (this.count === 0) {
        Text('播放后这里会列出已加载的弹幕')
          .fontSize(12)
          .fontColor(this.subColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 20, bottom: 20 })
      } else {
        List({ space: 4 }) {
          LazyForEach(this.source, (item: DanmakuItem) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(formatDuration(item.time))
                  .fontSize(11)
                  .fontColor(this.accent)
                Text(item.text)
                  .fontSize(12)
                  .fontColor(this.titleColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 7, bottom: 7 })
              .borderRadius(6)
              .backgroundColor(this.rowBg())
              .onClick(() => {
                this.onSeek(item.time);
                this.onClose();
              })
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction(() => {
                    this.onReport(item);
                  })
              )
            }
          }, (item: DanmakuItem) => String(item.time) + '_' + item.text)
        }
        .width('100%')
        .height(this.embedded ? 'auto' : 200)
        .layoutWeight(this.embedded ? 1 : 0)
        .scrollBar(BarState.Off)
        .cachedCount(4)
      }
    }
    .width('100%')
    .height(this.embedded ? '100%' : 'auto')
    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
    .borderRadius(this.embedded ? 0 : { topLeft: 16, topRight: 16 })
    .backgroundColor(this.embedded ? '#00000000' : (this.isDark ? '#18191C' : '#FFFFFF'))
    .backdropBlur(this.embedded ? 0 : 24)
    .border(this.embedded ? { width: 0 } : { width: { top: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
    .align(this.embedded ? Alignment.Top : Alignment.Bottom)
    .transition(this.embedded ? TransitionEffect.IDENTITY :
      TransitionEffect.asymmetric(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 24 }))
          .animation({ duration: 200, curve: Curve.EaseOut }),
        TransitionEffect.opacity(0).animation({ duration: 150, curve: Curve.EaseIn })))
  }
}
