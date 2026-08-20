/**
 * 投币弹窗（视频详情页）：1/2 枚选项 + 「同时点赞」勾选。
 * 纯展示组件：coinChoice/coinWithLike/提交逻辑（submitCoin）都在详情页。
 */
import { colorWithAlpha } from '../common/Utils';

@Component
export struct CoinSheetView {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  coinCountByMe: number = 0;
  choice: number = 1;
  withLike: boolean = true;
  busy: boolean = false;
  contentWidth: number = 322;
  onChoiceChange: (choice: number) => void = () => {};
  onWithLikeChange: (checked: boolean) => void = () => {};
  onConfirm: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          if (!this.busy) this.onClose();
        })
      Column({ space: 12 }) {
        Row() {
          Text('给 UP 主投硬币')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Blank()
          Image($r('app.media.ic_close'))
            .width(20)
            .height(20)
            .fillColor('#9499A0')
            .onClick(() => {
              if (!this.busy) this.onClose();
            })
        }
        .width('100%')
        Text('单个视频最多可投 2 枚，已投 ' + String(this.coinCountByMe) + ' 枚')
          .fontSize(12)
          .fontColor('#9499A0')
          .width('100%')
        Row({ space: 12 }) {
          // 投币动图仅作视觉素材，选项文案保持为清晰的「1 枚 / 2 枚」。
          this.coinOption($r('app.media.bili_coin_22'), 1, true)
          this.coinOption($r('app.media.bili_coin_33'), 2, this.coinCountByMe === 0)
        }
        .width('100%')
        Row({ space: 8 }) {
          Checkbox({ name: 'coinLike', group: 'coin' })
            .width(20)
            .height(20)
            .select(this.withLike)
            .selectedColor(this.accent)
            .onChange((checked: boolean) => {
              this.onWithLikeChange(checked);
            })
          Text('同时点赞视频')
            .fontSize(13)
            .fontColor(this.isDark ? '#D8D8DC' : '#5A5F66')
        }
        .width('100%')
        Button(this.busy ? '投币中…' : '确认投币')
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accent)
          .borderRadius(21)
          .enabled(!this.busy)
          .onClick(() => {
            this.onConfirm();
          })
      }
      .width(this.contentWidth)
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
      .borderRadius(20)
      .backgroundColor(this.isDark ? '#25262A' : '#FFFFFF')
      .shadow({ radius: 28, color: '#66000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  coinOption(characterImage: Resource, choice: number, enabled: boolean) {
    Column({ space: 2 }) {
      Image(characterImage)
        .width(84)
        .height(112)
        .objectFit(ImageFit.Contain)
      Text(String(choice) + ' 枚')
        .fontSize(12)
        .fontWeight(this.choice === choice ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.choice === choice ? this.accent : (this.isDark ? '#D8D8DC' : '#5A5F66'))
    }
    .layoutWeight(1)
    .height(150)
    .padding({ left: 6, right: 6, top: 7, bottom: 8 })
    .borderRadius(14)
    .border({ width: this.choice === choice ? 2 : 0.5, color: this.choice === choice ? this.accent : '#33808080' })
    .backgroundColor(this.choice === choice ? colorWithAlpha(this.accent, '14') : '#0A808080')
    .opacity(enabled ? 1 : 0.38)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      if (enabled) this.onChoiceChange(choice);
    })
  }
}
