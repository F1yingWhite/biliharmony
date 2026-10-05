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

  private gradeClick(stars: number): () => void {
    const id: string = this.liveCard().id;
    return (): void => {
      if (this.current !== null && this.current.id === id && this.current.kind === 'grade') this.grade(this.current, stars);
    };
  }

  private voteClick(optionId: number): () => void {
    const id: string = this.liveCard().id;
    return (): void => {
      if (this.current === null || this.current.id !== id || this.current.kind !== 'vote') return;
      const option: VideoInteractionOption | undefined = this.current.options.find((value: VideoInteractionOption): boolean => value.id === optionId);
      if (option !== undefined) this.vote(this.current, option);
    };
  }

  private linkClick(): () => void {
    const id: string = this.liveCard().id;
    return (): void => {
      if (this.current !== null && this.current.id === id && this.current.kind === 'link') this.openLink(this.current);
    };
  }

  private dismissClick(): () => void {
    const id: string = this.liveCard().id;
    const kind: string = this.liveCard().kind;
    return (): void => {
      if (this.current !== null && this.current.id === id && this.current.kind === kind) this.dismiss(this.current);
    };
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

  /** Builder callbacks outlive their first parameters; read the current Prop on each update. */
  private liveCard(): VideoInteractionCard {
    return this.current !== null ? this.current : new VideoInteractionCard();
  }

  @Builder
  GradeContent() {
    Row({ space: 4 }) {
      ForEach(this.starScores(this.liveCard()), (star: number) => {
        Button(star <= this.liveCard().selectedStars ? '★' : '☆', { type: ButtonType.Normal })
          .width(36)
          .height(34)
          .fontSize(28)
          .fontColor('#FFC857')
          .backgroundColor('#00000000')
          .borderRadius(6)
          .accessibilityText('评分' + String(star) + '星')
          .enabled(this.canGrade(this.liveCard()))
          .onClick(this.gradeClick(star))
      }, (star: number) => this.liveCard().id + ':' + String(star) + ':' +
        String(this.liveCard().selectedStars) + ':' + String(this.submitting))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    Text(this.liveCard().selectedStars > 0 ? '已评 ' + String(this.liveCard().selectedStars) + ' 星' : '点击星星评分')
      .fontSize(11)
      .fontColor('#DDFFFFFF')
    if (this.liveCard().count > 0) {
      Text(this.liveCard().averageScore.toFixed(1) + ' 分 · ' + formatCount(this.liveCard().count) + ' 人评分')
        .fontSize(10)
        .fontColor('#AFFFFFFF')
    }
  }

  @Builder
  VoteContent() {
    Column({ space: 4 }) {
        ForEach(this.liveCard().options, (option: VideoInteractionOption) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              Row({ space: 4 }) {
                Text(option.text)
                  .fontSize(12)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .fontColor('#FFFFFF')
                if (this.liveCard().selectedOptionId === option.id) {
                  Text('✓').fontSize(11).fontColor(this.accent)
                }
                if (this.hasVoteResult(this.liveCard())) {
                  Text(formatCount(this.safeVotes(option)) + '票').fontSize(10).fontColor('#CCFFFFFF')
                  Text(String(this.votePercent(this.liveCard(), option)) + '%').fontSize(11).fontColor('#FFFFFF')
                    .width(34).textAlign(TextAlign.End)
                }
              }
              .width('100%')
              .height(14)
              if (this.hasVoteResult(this.liveCard())) {
                Progress({ value: this.votePercent(this.liveCard(), option), total: 100, type: ProgressType.Linear })
                  .width('100%').height(3)
                  .color(this.liveCard().selectedOptionId === option.id ? this.accent : '#99FFFFFF')
                  .backgroundColor('#25FFFFFF')
                  .style({ strokeWidth: 3, enableSmoothEffect: false })
                  .accessibilityText(option.text + '，' + String(this.votePercent(this.liveCard(), option)) + '%')
                  .hitTestBehavior(HitTestMode.None)
              }
            }
            .width('100%')
          }
          .width('100%')
          .height(this.voteOptionHeight(this.liveCard()))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(this.liveCard().selectedOptionId === option.id ? '#55FB7299' : '#25FFFFFF')
          .opacity(option.hasSelfDef && !this.hasVoteResult(this.liveCard()) ? 0.5 : 1)
          .accessibilityText('投票选项' + String(option.id))
          .accessibilityDescription(option.text)
          .enabled(this.canVote(this.liveCard(), option))
          .onClick(this.voteClick(option.id))
        }, (option: VideoInteractionOption) => this.liveCard().kind + ':' + this.liveCard().id + ':' + String(option.id) + ':' +
          option.text + ':' + String(option.hasSelfDef) + ':' +
          String(this.liveCard().selectedOptionId) + ':' + String(this.safeVotes(option)) + ':' + String(this.votePercent(this.liveCard(), option)))
    }
    .width('100%')
    if (this.liveCard().options.some((option: VideoInteractionOption): boolean => option.hasSelfDef)) {
      Text('自定义选项需要填写内容')
        .fontSize(10)
        .fontColor('#AFFFFFFF')
    }
  }

  @Builder
  LinkContent() {
    Row({ space: 8 }) {
      if (this.linkCover(this.liveCard()).length > 0) {
        Image(this.linkCover(this.liveCard())).width(52).height(36).borderRadius(4).objectFit(ImageFit.Cover)
      }
      Text(this.linkTitle(this.liveCard()))
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
      .enabled(this.canOpenLink(this.liveCard()))
      .onClick(this.linkClick())
  }

  @Builder
  Card() {
    Column({ space: this.cardGap(this.liveCard()) }) {
      Row({ space: 6 }) {
        if (this.liveCard().kind === 'vote') {
          Column({ space: 0 }) {
            Text(this.kindLabel(this.liveCard()) + (this.hasVoteResult(this.liveCard()) ? ' · 已投票' :
              (this.liveCard().options.length > 2 ? ' · 上下滑动查看选项' : '')))
              .fontSize(10).fontColor('#BFFFFFFF').height(12).maxLines(1)
            Text(this.liveCard().title).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .height(16).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        } else {
          Text(this.kindLabel(this.liveCard())).fontSize(10).fontColor('#BFFFFFFF').layoutWeight(1)
        }
        Button('×', { type: ButtonType.Normal })
          .width(24)
          .height(24)
          .fontSize(18)
          .fontColor('#DDFFFFFF')
          .backgroundColor('#00000000')
          .accessibilityText('关闭当前互动卡片')
          .onClick(this.dismissClick())
      }
      .width('100%')
      .height(this.headerHeight(this.liveCard()))
      .flexShrink(0)
      Scroll() {
        Column({ space: 6 }) {
          if (this.liveCard().kind !== 'vote' && this.liveCard().title.length > 0) {
            Text(this.liveCard().title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .maxLines(2).width('100%')
          }
          if (this.liveCard().kind === 'grade') this.GradeContent()
          else if (this.liveCard().kind === 'vote') this.VoteContent()
          else if (this.liveCard().kind === 'link') this.LinkContent()
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
      .height(this.bodyHeight(this.liveCard()))
      .flexShrink(0)
      .scrollBar(this.liveCard().kind === 'vote' ? BarState.Auto : BarState.Off)
    }
    .width('100%')
    .constraintSize({ maxHeight: this.cardHeight() })
    .padding(this.cardPadding(this.liveCard()))
    .borderRadius(12)
    .backgroundColor('#E618191C')
    .border({ width: 0.5, color: '#44FFFFFF' })
  }

  build() {
    Column() {
      if (this.current !== null) this.Card()
    }
    .width('85%')
    .constraintSize({ maxWidth: this.fullscreen ? 320 : 260 })
  }
}
