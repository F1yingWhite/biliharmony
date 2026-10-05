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
  /** 播放画布扣除控制条和边距后留给卡片的实际高度。 */
  @Prop availableHeight: number = 0;
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

  private cardHeight(): number {
    const maximum: number = this.fullscreen ? 280 : 140;
    return Number.isFinite(this.availableHeight) && this.availableHeight > 0 ?
      Math.min(maximum, this.availableHeight) : maximum;
  }

  private cardPadding(card: VideoInteractionCard): number {
    return card.kind === 'vote' ? 8 : 10;
  }

  private cardGap(card: VideoInteractionCard): number {
    return card.kind === 'vote' ? 4 : 6;
  }

  private headerHeight(card: VideoInteractionCard): number {
    return card.kind === 'vote' ? 32 : 24;
  }

  private bodyHeight(card: VideoInteractionCard): number {
    return Math.max(0, this.cardHeight() - this.headerHeight(card) - this.cardGap(card) - this.cardPadding(card) * 2);
  }

  private voteOptionHeight(card: VideoInteractionCard): number {
    // 两个常见答案始终共享完整可用视口；更多答案继续在同一列表内滚动。
    return Math.max(1, Math.min(40, Math.floor((this.bodyHeight(card) - 4) / 2)));
  }

  private hasVoteResult(card: VideoInteractionCard): boolean {
    return card.selectedOptionId > 0 && card.options.some((option: VideoInteractionOption): boolean => option.id === card.selectedOptionId);
  }

  private safeVotes(option: VideoInteractionOption): number {
    return Number.isFinite(option.votes) && option.votes > 0 ? option.votes : 0;
  }

  private votePercent(card: VideoInteractionCard, option: VideoInteractionOption): number {
    let total: number = 0;
    for (const value of card.options) total += this.safeVotes(value);
    if (total <= 0 || !Number.isFinite(total)) return 0;
    // 与官方播放器一致：前面的选项向下取整，末项补齐余数，总和为 100%。
    let remaining: number = 100;
    for (let index: number = 0; index < card.options.length; index++) {
      const value: VideoInteractionOption = card.options[index];
      const percent: number = index === card.options.length - 1 ? remaining :
        Math.floor(this.safeVotes(value) / total * 100);
      if (value.id === option.id) return Math.max(0, Math.min(100, percent));
      remaining -= percent;
    }
    return 0;
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
    Column({ space: 4 }) {
        ForEach(card.options, (option: VideoInteractionOption) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              Row({ space: 4 }) {
                Text(option.text)
                  .fontSize(12)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .fontColor('#FFFFFF')
                if (card.selectedOptionId === option.id) {
                  Text('✓').fontSize(11).fontColor(this.accent)
                }
                if (this.hasVoteResult(card)) {
                  Text(formatCount(this.safeVotes(option)) + '票').fontSize(10).fontColor('#CCFFFFFF')
                  Text(String(this.votePercent(card, option)) + '%').fontSize(11).fontColor('#FFFFFF')
                    .width(34).textAlign(TextAlign.End)
                }
              }
              .width('100%')
              .height(14)
              if (this.hasVoteResult(card)) {
                Progress({ value: this.votePercent(card, option), total: 100, type: ProgressType.Linear })
                  .width('100%').height(3)
                  .color(card.selectedOptionId === option.id ? this.accent : '#99FFFFFF')
                  .backgroundColor('#25FFFFFF')
                  .style({ strokeWidth: 3, enableSmoothEffect: false })
                  .accessibilityText(option.text + '，' + String(this.votePercent(card, option)) + '%')
                  .hitTestBehavior(HitTestMode.None)
              }
            }
            .width('100%')
          }
          .width('100%')
          .height(this.voteOptionHeight(card))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(card.selectedOptionId === option.id ? '#55FB7299' : '#25FFFFFF')
          .opacity(option.hasSelfDef && !this.hasVoteResult(card) ? 0.5 : 1)
          .accessibilityText('投票选项' + String(option.id))
          .accessibilityDescription(option.text)
          .enabled(this.canVote(card, option))
          .onClick(() => this.vote(card, option))
        }, (option: VideoInteractionOption) => card.id + ':' + String(option.id) + ':' +
          String(card.selectedOptionId) + ':' + String(this.safeVotes(option)) + ':' + String(this.votePercent(card, option)))
    }
    .width('100%')
    if (card.options.some((option: VideoInteractionOption): boolean => option.hasSelfDef)) {
      Text('自定义选项需要填写内容')
        .fontSize(10)
        .fontColor('#AFFFFFFF')
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
    Column({ space: this.cardGap(card) }) {
      Row({ space: 6 }) {
        if (card.kind === 'vote') {
          Column({ space: 0 }) {
            Text(this.kindLabel(card) + (this.hasVoteResult(card) ? ' · 已投票' :
              (card.options.length > 2 ? ' · 上下滑动查看选项' : '')))
              .fontSize(10).fontColor('#BFFFFFFF').height(12).maxLines(1)
            Text(card.title).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .height(16).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        } else {
          Text(this.kindLabel(card)).fontSize(10).fontColor('#BFFFFFFF').layoutWeight(1)
        }
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
      .height(this.headerHeight(card))
      .flexShrink(0)
      Scroll() {
        Column({ space: 6 }) {
          if (card.kind !== 'vote' && card.title.length > 0) {
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
      .height(this.bodyHeight(card))
      .flexShrink(0)
      .scrollBar(card.kind === 'vote' ? BarState.Auto : BarState.Off)
    }
    .width('100%')
    .constraintSize({ maxHeight: this.cardHeight() })
    .padding(this.cardPadding(card))
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
