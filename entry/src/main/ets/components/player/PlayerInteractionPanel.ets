import { VideoInteractionCard, VideoInteractionOption } from '../../model/video/VideoInteractionModels';
import { formatCount } from '../../common/Utils';

/** UP 主时间轴互动卡片。提交、导航和时间窗由播放器控制器管理。 */
@Component
export struct PlayerInteractionPanel {
  @Prop current: VideoInteractionCard | null = null;
  @Prop loading: boolean = false;
  @Prop submitting: boolean = false;
  @Prop message: string = '';
  @Prop fullscreen: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onGrade: (id: string, stars: number) => void = () => {};
  onVote: (id: string, optionId: number) => void = () => {};
  onLink: (id: string) => void = () => {};
  onDismiss: (id: string) => void = () => {};

  private isCurrent(card: VideoInteractionCard): boolean {
    return this.current !== null && this.current.id === card.id && this.current.kind === card.kind;
  }

  private canGrade(card: VideoInteractionCard): boolean {
    return this.isCurrent(card) && card.kind === 'grade' && !this.loading && !this.submitting &&
      this.current !== null && this.current.selectedStars <= 0 && card.selectedStars <= 0;
  }

  private grade(card: VideoInteractionCard, stars: number): void {
    if (!this.canGrade(card) || !Number.isInteger(stars) || stars < 1 || stars > 5 || stars > card.maxStars) return;
    this.onGrade(card.id, stars);
  }

  private canVote(card: VideoInteractionCard, option: VideoInteractionOption): boolean {
    return this.isCurrent(card) && card.kind === 'vote' && !this.loading && !this.submitting &&
      this.current !== null && this.current.selectedOptionId <= 0 && card.selectedOptionId <= 0 &&
      !option.hasSelfDef && card.options.some((value: VideoInteractionOption): boolean => value.id === option.id);
  }

  private vote(card: VideoInteractionCard, option: VideoInteractionOption): void {
    if (this.canVote(card, option)) this.onVote(card.id, option.id);
  }

  private canOpenLink(card: VideoInteractionCard): boolean {
    return this.isCurrent(card) && card.kind === 'link' && !this.loading && !this.submitting &&
      card.link !== null && (card.link.aid > 0 || card.link.bvid.length > 0 || card.link.epId > 0);
  }

  private openLink(card: VideoInteractionCard): void {
    if (this.canOpenLink(card)) this.onLink(card.id);
  }

  private dismiss(card: VideoInteractionCard): void {
    if (this.isCurrent(card)) this.onDismiss(card.id);
  }

  private starScores(card: VideoInteractionCard): Array<number> {
    const scores: Array<number> = [];
    const maximum: number = Math.max(1, Math.min(5, Math.round(card.maxStars)));
    for (let star: number = 1; star <= maximum; star++) scores.push(star);
    return scores;
  }

  private kindLabel(card: VideoInteractionCard): string {
    if (card.kind === 'grade') return 'UP主评分';
    if (card.kind === 'vote') return 'UP主投票';
    return 'UP主推荐';
  }

  private linkTitle(card: VideoInteractionCard): string {
    return card.link !== null && card.link.title.length > 0 ? card.link.title : '推荐视频';
  }

  private linkCover(card: VideoInteractionCard): string {
    return card.link !== null ? card.link.cover : '';
  }

  @Builder
  GradeContent(card: VideoInteractionCard) {
    Row({ space: 4 }) {
      ForEach(this.starScores(card), (star: number) => {
        Button(star <= card.selectedStars ? '★' : '☆', { type: ButtonType.Normal })
          .width(36)
          .height(34)
          .fontSize(28)
          .fontColor('#FFC857')
          .backgroundColor('#00000000')
          .borderRadius(6)
          .accessibilityText('评分' + String(star) + '星')
          .enabled(this.canGrade(card))
          .onClick(() => this.grade(card, star))
      }, (star: number) => String(star))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    Text(card.selectedStars > 0 ? '已评 ' + String(card.selectedStars) + ' 星' : '点击星星评分')
      .fontSize(11)
      .fontColor('#DDFFFFFF')
    if (card.count > 0) {
      Text(card.averageScore.toFixed(1) + ' 分 · ' + formatCount(card.count) + ' 人评分')
        .fontSize(10)
        .fontColor('#AFFFFFFF')
    }
  }

  @Builder
  VoteContent(card: VideoInteractionCard) {
    Column({ space: 6 }) {
        ForEach(card.options, (option: VideoInteractionOption) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 6 }) {
              Text(option.text)
                .fontSize(12)
                .maxLines(2)
                .layoutWeight(1)
                .fontColor('#FFFFFF')
              if (card.selectedOptionId === option.id) {
                Text('✓').fontSize(13).fontColor(this.accent)
              }
              if (card.selectedOptionId > 0 || option.votes > 0) {
                Text(formatCount(option.votes) + ' 票').fontSize(10).fontColor('#CCFFFFFF')
              }
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor(card.selectedOptionId === option.id ? '#55FB7299' : '#25FFFFFF')
          .opacity(option.hasSelfDef ? 0.5 : 1)
          .accessibilityText('投票选项' + String(option.id))
          .enabled(this.canVote(card, option))
          .onClick(() => this.vote(card, option))
        }, (option: VideoInteractionOption) => String(option.id))
    }
    .width('100%')
    if (card.options.some((option: VideoInteractionOption): boolean => option.hasSelfDef)) {
      Text('自定义选项需要填写内容')
        .fontSize(10)
        .fontColor('#AFFFFFFF')
    }
    if (card.selectedOptionId > 0) {
      Text('已投票').fontSize(11).fontColor('#DDFFFFFF')
    }
  }

  @Builder
  LinkContent(card: VideoInteractionCard) {
    Row({ space: 8 }) {
      if (this.linkCover(card).length > 0) {
        Image(this.linkCover(card)).width(52).height(36).borderRadius(4).objectFit(ImageFit.Cover)
      }
      Text(this.linkTitle(card))
        .fontSize(12)
        .fontColor('#FFFFFF')
        .maxLines(2)
        .layoutWeight(1)
    }
    .width('100%')
    Button('观看推荐视频', { type: ButtonType.Normal })
      .width('100%')
      .height(32)
      .borderRadius(8)
      .fontSize(12)
      .fontColor('#FFFFFF')
      .backgroundColor(this.accent)
      .accessibilityText('观看推荐视频')
      .enabled(this.canOpenLink(card))
      .onClick(() => this.openLink(card))
  }

  @Builder
  Card(card: VideoInteractionCard) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.kindLabel(card)).fontSize(10).fontColor('#BFFFFFFF').layoutWeight(1)
        Button('×', { type: ButtonType.Normal })
          .width(24)
          .height(24)
          .fontSize(18)
          .fontColor('#DDFFFFFF')
          .backgroundColor('#00000000')
          .accessibilityText('关闭当前互动卡片')
          .onClick(() => this.dismiss(card))
      }
      .width('100%')
      Scroll() {
        Column({ space: 6 }) {
          if (card.title.length > 0) {
            Text(card.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .maxLines(2).width('100%')
          }
          if (card.kind === 'grade') this.GradeContent(card)
          else if (card.kind === 'vote') this.VoteContent(card)
          else if (card.kind === 'link') this.LinkContent(card)
          if (this.loading || this.submitting) {
            Row({ space: 6 }) {
              LoadingProgress().width(14).height(14).color(this.accent)
              Text(this.submitting ? '提交中…' : '加载中…').fontSize(10).fontColor('#CCFFFFFF')
            }
          }
          if (this.message.length > 0) {
            Text(this.message).fontSize(11).fontColor('#DDFFFFFF').maxLines(2).width('100%')
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: this.fullscreen ? 230 : 90 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .constraintSize({ maxHeight: this.fullscreen ? 280 : 140 })
    .padding(10)
    .borderRadius(12)
    .backgroundColor('#E618191C')
    .border({ width: 0.5, color: '#44FFFFFF' })
  }

  build() {
    Column() {
      if (this.current !== null) this.Card(this.current)
    }
    .width('85%')
    .constraintSize({ maxWidth: this.fullscreen ? 320 : 260 })
  }
}
