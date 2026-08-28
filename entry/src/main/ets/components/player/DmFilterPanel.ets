/**
 * 弹幕屏蔽管理面板：关键词/类型/用户列表与删除。
 * 从 PlayerView.DmFilterPanel 拆出，供竖屏弹层/设置内嵌页复用。
 */
import { BasicDataSource } from '../../common/BasicDataSource';
import { playerPanelTitle, playerPanelSub, playerPanelRowBg } from './PlayerSheetTheme';
import { DmFilterRule } from '../../api/BiliApi';

@Component
export struct DmFilterPanel {
  @Prop embedded: boolean = false;
  @Prop forceDark: boolean = false;
  @Prop loading: boolean = false;
  @Prop filterType: number = 0;
  @Prop draft: string = '';
  @Prop rulesCount: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  source: BasicDataSource<DmFilterRule> = new BasicDataSource<DmFilterRule>();
  onTypeChange: (type: number) => void = (type: number) => {
  };
  onDraftChange: (value: string) => void = (value: string) => {
  };
  onAdd: () => void = () => {
  };
  onDelete: (id: number) => void = (id: number) => {
  };

  private darkMode(): boolean {
    return this.forceDark || this.isDark;
  }

  private titleColor(): string {
    return playerPanelTitle(this.darkMode());
  }

  private subColor(): string {
    return playerPanelSub(this.darkMode());
  }

  private rowBg(): string {
    return playerPanelRowBg(this.darkMode());
  }

  private typeLabel(type: number): string {
    return type === 1 ? '正则' : (type === 2 ? '用户' : '关键词');
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('弹幕屏蔽管理').fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.titleColor())
        Blank()
        Text(this.loading ? '加载中…' : '')
          .fontSize(11)
          .fontColor(this.subColor())
      }
      .width('100%')
      Row({ space: 6 }) {
        Text('关键词').fontSize(11)
          .fontColor(this.filterType === 0 ? '#FFFFFF' : this.subColor())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(13)
          .backgroundColor(this.filterType === 0 ? this.accent : this.rowBg())
          .onClick(() => this.onTypeChange(0))
        Text('正则').fontSize(11)
          .fontColor(this.filterType === 1 ? '#FFFFFF' : this.subColor())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(13)
          .backgroundColor(this.filterType === 1 ? this.accent : this.rowBg())
          .onClick(() => this.onTypeChange(1))
        Text('用户').fontSize(11)
          .fontColor(this.filterType === 2 ? '#FFFFFF' : this.subColor())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(13)
          .backgroundColor(this.filterType === 2 ? this.accent : this.rowBg())
          .onClick(() => this.onTypeChange(2))
      }
      .width('100%')
      Row({ space: 6 }) {
        TextInput({ text: this.draft, placeholder: '输入后点添加' })
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .fontColor(this.titleColor())
          .placeholderColor(this.subColor())
          .backgroundColor(this.rowBg())
          .borderRadius(15)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => this.onDraftChange(value))
        Text('添加').fontSize(12).fontColor('#FFFFFF')
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor(this.accent)
          .onClick(() => this.onAdd())
      }
      .width('100%')
      if (this.rulesCount === 0) {
        Text(this.loading ? '加载中…' : '暂无屏蔽规则')
          .fontSize(12)
          .fontColor(this.subColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 18, bottom: 18 })
      } else {
        List({ space: 4 }) {
          LazyForEach(this.source, (rule: DmFilterRule) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(this.typeLabel(rule.type))
                  .fontSize(10)
                  .fontColor(this.accent)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(4)
                  .backgroundColor('#26FB7299')
                Text(rule.filter)
                  .fontSize(12)
                  .fontColor(this.titleColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text('删除')
                  .fontSize(11)
                  .fontColor('#FF6B6B')
                  .onClick(() => this.onDelete(rule.id))
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 7, bottom: 7 })
              .borderRadius(6)
              .backgroundColor(this.rowBg())
            }
          }, (rule: DmFilterRule) => String(rule.id))
        }
        .width('100%')
        .height(this.embedded ? 'auto' : 180)
        .layoutWeight(this.embedded ? 1 : 0)
        .scrollBar(BarState.Off)
        .cachedCount(4)
      }
    }
    .width('100%')
    .height(this.embedded ? '100%' : 'auto')
    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
    .borderRadius(this.embedded ? 0 : { topLeft: 16, topRight: 16 })
    .backgroundColor(this.embedded ? '#00000000' : (this.darkMode() ? '#18191C' : '#FFFFFF'))
    .backdropBlur(this.embedded ? 0 : 24)
    .border(this.embedded ? { width: 0 } : { width: { top: 0.5 }, color: this.darkMode() ? '#333333' : '#EEEEEE' })
    .align(this.embedded ? Alignment.Top : Alignment.Bottom)
    .transition(this.embedded ? TransitionEffect.IDENTITY :
      TransitionEffect.asymmetric(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 24 }))
          .animation({ duration: 200, curve: Curve.EaseOut }),
        TransitionEffect.opacity(0).animation({ duration: 150, curve: Curve.EaseIn })))
  }
}
