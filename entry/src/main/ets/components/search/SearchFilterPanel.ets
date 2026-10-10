import { FilterChip } from '../FilterChip';
import { AppTheme } from '../../common/AppTheme';
import { SearchNumOption, VIDEO_PUBTIME_OPTIONS, VIDEO_DURATION_OPTIONS, VIDEO_ZONE_OPTIONS } from '../../model/Models';

@Component
export struct SearchFilterPanel {
  @Prop duration: number = 0;
  @Prop pubtime: number = 0;
  @Prop tids: number = 0;
  @State tmpDuration: number = 0;
  @State tmpPubtime: number = 0;
  @State tmpTids: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onApply: (duration: number, pubtime: number, tids: number) => void = (): void => {};

  aboutToAppear(): void {
    this.tmpDuration = this.duration;
    this.tmpPubtime = this.pubtime;
    this.tmpTids = this.tids;
  }

  @Builder
  FilterGroup(title: string, options: Array<SearchNumOption>, selected: number, kind: number) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(13)
        .fontColor(this.isDark ? '#C6C7CB' : '#61666D')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(options, (opt: SearchNumOption, idx: number) => {
          FilterChip({
            label: opt.label,
            selected: kind === 2 ? opt.value === selected : idx === selected,
            bottomMargin: 8,
            onTap: () => {
              if (kind === 0) {
                this.tmpPubtime = idx;
              } else if (kind === 1) {
                this.tmpDuration = idx;
              } else {
                this.tmpTids = opt.value;
              }
            },
          })
        }, (opt: SearchNumOption) => String(opt.value))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 结果态：筛选面板（bindSheet 底部弹层） =====
  build() {
    Column({ space: 16 }) {
      Text('筛选')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .width('100%')
        .textAlign(TextAlign.Center)

      this.FilterGroup('发布时间', VIDEO_PUBTIME_OPTIONS, this.tmpPubtime, 0)
      this.FilterGroup('时长', VIDEO_DURATION_OPTIONS, this.tmpDuration, 1)
      this.FilterGroup('分区', VIDEO_ZONE_OPTIONS, this.tmpTids, 2)

      Row({ space: 12 }) {
        Button('重置', { type: ButtonType.Normal })
          .fontSize(14)
          .fontColor(this.isDark ? '#C6C7CB' : '#61666D')
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .constraintSize({ minHeight: 44 })
          .labelStyle({ textAlign: TextAlign.Center })
          .backgroundColor(this.isDark ? '#2E3136' : '#ECEEF0')
          .borderRadius(18)
          .onClick(() => {
            this.tmpDuration = 0;
            this.tmpPubtime = 0;
            this.tmpTids = 0;
          })
        Button('完成', { type: ButtonType.Normal })
          .fontSize(14)
          .fontColor(AppTheme.onAccent(this.accent))
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .constraintSize({ minHeight: 44 })
          .labelStyle({ textAlign: TextAlign.Center })
          .backgroundColor(this.accent)
          .borderRadius(18)
          .onClick(() => {
            this.onApply(this.tmpDuration, this.tmpPubtime, this.tmpTids);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
  }

}
