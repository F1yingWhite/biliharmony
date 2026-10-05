import { ReplyVoteCard, ReplyVoteOption, ReplyVoteSource } from '../../model/reply/ReplyVoteModels';
import { ReplyVoteController, ReplyVoteState } from './ReplyVoteController';
import { UserStore } from '../../services/auth/UserStore';
import { AuthSession } from '../../services/auth/AuthSession';
import { AppNavStack, NAV_LOGIN } from '../../common/AppRouter';
import { formatCount } from '../../common/Utils';

/** 评论附件与评论区顶部投票共用；选择和结果均由真实投票控制器管理。 */
@Reusable
@Component
export struct ReplyVotePanel {
  @Prop @Watch('onVoteSourceChanged') vote: ReplyVoteCard | null = null;
  @Prop @Watch('onVoteSourceChanged') source: ReplyVoteSource = new ReplyVoteSource();
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('loginVersion') @Watch('onAccountChanged') loginVersion: number = 0;
  onNavigate: (action: () => void) => void = (action: () => void) => action();
  @State voteState: ReplyVoteState = new ReplyVoteState();
  private destroyed: boolean = false;
  private actionGeneration: number = 0;
  private controller: ReplyVoteController = new ReplyVoteController({
    isDestroyed: (): boolean => this.destroyed,
    getSource: (): ReplyVoteSource => this.source,
    getVote: (): ReplyVoteCard | null => this.vote,
    applyState: (state: ReplyVoteState): void => { this.voteState = state; },
    toast: (message: string): void => this.toast(message),
  });

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
    }
  }

  private bindAndLoad(): void {
    if (this.destroyed) return;
    this.actionGeneration++;
    this.controller.bind(this.source, this.vote);
    if (this.vote !== null) this.controller.load();
  }

  aboutToAppear(): void {
    this.destroyed = false;
    this.bindAndLoad();
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.controller.dispose();
    this.destroyed = false;
    const freshVote: Object | undefined = params['vote'];
    const freshSource: Object | undefined = params['source'];
    if (freshVote === null) this.vote = null;
    else if (freshVote instanceof ReplyVoteCard) this.vote = freshVote.clone();
    if (freshSource !== null && typeof freshSource === 'object' && !Array.isArray(freshSource)) {
      const source: ReplyVoteSource = freshSource as ReplyVoteSource;
      if (typeof source.sourceKey === 'string') this.source = source;
    }
    this.bindAndLoad();
  }

  private onVoteSourceChanged(): void {
    this.bindAndLoad();
  }

  private onAccountChanged(): void {
    this.actionGeneration++;
    if (!this.destroyed) this.controller.onAccountChanged();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.actionGeneration++;
    this.controller.dispose();
  }

  aboutToRecycle(): void {
    this.aboutToDisappear();
  }

  private card(): ReplyVoteCard | null {
    if (this.voteState.detail !== null) return this.voteState.detail;
    if (this.vote === null) return null;
    // 列表元数据可能来自上一账号，只保留标题/选项；选中态必须来自当前账号详情。
    const metadata: ReplyVoteCard = this.vote.clone();
    metadata.selectedIds = [];
    metadata.loaded = false;
    return metadata;
  }

  private ended(card: ReplyVoteCard): boolean {
    return card.ended || card.endTime > 0 && card.endTime * 1000 <= Date.now();
  }

  private hasVoted(card: ReplyVoteCard): boolean {
    return card.selectedIds.length > 0;
  }

  private ownVote(card: ReplyVoteCard): boolean {
    return UserStore.isLogin && UserStore.current !== null && card.publisherMid > 0 &&
      UserStore.current.mid === card.publisherMid;
  }

  private showResults(card: ReplyVoteCard): boolean {
    return this.voteState.resultsVisible || this.hasVoted(card) || this.ended(card) || this.ownVote(card);
  }

  private selected(card: ReplyVoteCard, option: ReplyVoteOption): boolean {
    return this.hasVoted(card) ? card.selectedIds.indexOf(option.id) >= 0 :
      this.voteState.selectedOptionIds.indexOf(option.id) >= 0;
  }

  private safeCount(option: ReplyVoteOption): number {
    return Number.isFinite(option.count) && option.count > 0 ? option.count : 0;
  }

  private percentage(card: ReplyVoteCard, option: ReplyVoteOption): number {
    let total: number = 0;
    for (const value of card.options) total += this.safeCount(value);
    // 官方投票页以所有选项的总选择次数为分母，多选也使用这个口径。
    return total > 0 && Number.isFinite(total) ? Math.round(this.safeCount(option) / total * 100) : 0;
  }

  private canChoose(card: ReplyVoteCard): boolean {
    return card.loaded && !card.deleted && !this.ended(card) && !this.hasVoted(card) && !this.ownVote(card) &&
      !this.voteState.loading && !this.voteState.submitting;
  }

  private choose(optionId: number): void {
    if (!this.destroyed) this.controller.toggle(optionId);
  }

  private submit(): void {
    if (!this.destroyed) this.controller.submit();
  }

  private viewResults(): void {
    if (!this.destroyed) this.controller.viewResults();
  }

  private login(): void {
    if (this.destroyed) return;
    this.onNavigate(() => AppNavStack.pushPathByName(NAV_LOGIN, null));
  }

  private voteAction(card: ReplyVoteCard, action: () => void): () => void {
    const generation: number = this.actionGeneration;
    const account: number = AuthSession.version;
    const voteId: string = card.id;
    const kind: string = card.kind;
    const sourceKey: string = this.source.sourceKey;
    const oid: number = this.source.oid;
    const type: number = this.source.type;
    const rpid: number = this.source.rpid;
    return (): void => {
      const current: ReplyVoteCard | null = this.card();
      if (this.destroyed || this.actionGeneration !== generation || AuthSession.version !== account || current === null ||
        current.id !== voteId || current.kind !== kind || this.source.sourceKey !== sourceKey ||
        this.source.oid !== oid || this.source.type !== type || this.source.rpid !== rpid) return;
      action();
    };
  }

  private optionAction(card: ReplyVoteCard, optionId: number): () => void {
    return this.voteAction(card, (): void => this.choose(optionId));
  }

  private optionKey(card: ReplyVoteCard, option: ReplyVoteOption): string {
    // 选择、结果或选项变化时重建原生 ForEach 的选项结构。
    return this.source.sourceKey + ':' + card.kind + ':' + card.id + ':' + String(option.id) + ':' + option.text + ':' +
      String(option.count) + ':' + String(this.percentage(card, option)) + ':' + String(this.selected(card, option)) + ':' +
      String(this.showResults(card)) + ':' + String(this.voteState.loading) + ':' + String(this.voteState.submitting);
  }

  @Builder
  // 原生局部更新保留 Builder 入参；getter 必须读取当前状态，不能传初次卡片的快照。
  Option(getCard: () => ReplyVoteCard, getOption: () => ReplyVoteOption) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(this.selected(getCard(), getOption()) ? (getCard().maxSelect > 1 || this.hasVoted(getCard()) ? '✓' : '●') :
            (getCard().maxSelect > 1 ? '□' : '○'))
            .fontSize(15).fontColor(this.selected(getCard(), getOption()) ? this.accent : '#9499A0')
          if (getOption().imageUrl.length > 0) {
            Image(getOption().imageUrl).width(48).height(36).objectFit(ImageFit.Cover).borderRadius(4)
          }
          Text(getOption().text)
            .fontSize(13).lineHeight(18)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C').layoutWeight(1)
          if (this.showResults(getCard())) {
            Text(String(this.percentage(getCard(), getOption())) + '%')
              .fontSize(12).fontColor(this.isDark ? '#CCCCCC' : '#61666D').width(36).textAlign(TextAlign.End)
          }
        }
        .width('100%')
        if (this.showResults(getCard())) {
          Progress({ value: this.percentage(getCard(), getOption()), total: 100, type: ProgressType.Linear })
            .width('100%').height(4)
            .color(this.selected(getCard(), getOption()) ? this.accent : '#A8ACB5')
            .backgroundColor(this.isDark ? '#40434A' : '#E2E5EA')
            .style({ strokeWidth: 4, enableSmoothEffect: false })
            .hitTestBehavior(HitTestMode.None)
          Text(formatCount(this.safeCount(getOption())) + ' 票')
            .fontSize(10).fontColor('#9499A0').width('100%')
        }
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
    .width('100%').constraintSize({ minHeight: 44 })
    .padding(10).borderRadius(8)
    .backgroundColor(this.selected(getCard(), getOption()) ? (this.isDark ? '#332A2028' : '#FFF0F5') :
      (this.isDark ? '#303238' : '#F1F2F5'))
    .border({ width: this.selected(getCard(), getOption()) ? 1 : 0, color: this.accent })
    .accessibilityText('评论投票选项' + String(getOption().id))
    .accessibilityDescription(getOption().text)
    .enabled(this.canChoose(getCard()))
    .onClick(this.optionAction(getCard(), getOption().id))
  }

  @Builder
  Card(getCard: () => ReplyVoteCard) {
    Column({ space: 10 }) {
      Text(getCard().title.length > 0 ? getCard().title : '评论投票')
        .fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C').width('100%')
      Text(formatCount(getCard().count) + ' 人参与' + (getCard().maxSelect > 1 ? ' · 最多选 ' + String(getCard().maxSelect) + ' 项' : ' · 单选'))
        .fontSize(11).fontColor('#9499A0').width('100%')
      if (getCard().deleted) {
        Text('投票已失效').fontSize(12).fontColor('#9499A0')
      } else {
        if (this.ended(getCard())) {
          Text('投票已结束').fontSize(12).fontColor('#9499A0')
        } else if (this.ownVote(getCard())) {
          Text('你发布的投票').fontSize(12).fontColor('#9499A0')
        } else if (this.hasVoted(getCard())) {
          Text('已投票').fontSize(12).fontColor(this.accent)
        }
        if (getCard().options.length > 0) {
          Column({ space: 8 }) {
            ForEach(getCard().options, (option: ReplyVoteOption) => this.Option(getCard,
              (): ReplyVoteOption => getCard().options.find((current: ReplyVoteOption): boolean => current.id === option.id) ?? new ReplyVoteOption()),
              (option: ReplyVoteOption) => this.optionKey(getCard(), option))
          }
          .width('100%')
        }
        if (getCard().loaded && !this.ended(getCard()) && !this.hasVoted(getCard()) && !this.ownVote(getCard())) {
          if (!UserStore.isLogin) {
            Button('登录后参与投票', { type: ButtonType.Normal })
              .width('100%').height(34).fontSize(12).fontColor(this.accent)
              .backgroundColor(this.isDark ? '#303238' : '#F1F2F5').borderRadius(8)
              .accessibilityText('登录参与评论投票').onClick(this.voteAction(getCard(), (): void => this.login()))
          } else {
            Button(this.voteState.submitting ? '提交中…' : '提交投票', { type: ButtonType.Normal })
              .width('100%').height(34).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor(this.accent).borderRadius(8)
              .accessibilityText('提交评论投票')
              .enabled(!this.voteState.loading && !this.voteState.submitting && this.voteState.selectedOptionIds.length > 0)
              .onClick(this.voteAction(getCard(), (): void => this.submit()))
          }
        }
        if (getCard().options.length > 0) {
          Button(this.showResults(getCard()) ? '刷新结果' : '查看结果', { type: ButtonType.Normal })
            .height(30).fontSize(12).fontColor(this.accent).backgroundColor('#00000000')
            .accessibilityText('查看评论投票结果')
            .enabled(!this.voteState.loading && !this.voteState.submitting)
            .onClick(this.voteAction(getCard(), (): void => this.viewResults()))
        }
      }
      if (this.voteState.loading) {
        Row({ space: 6 }) {
          LoadingProgress().width(16).height(16).color(this.accent)
          Text('加载投票…').fontSize(11).fontColor('#9499A0')
        }
      }
      if (this.voteState.message.length > 0) {
        Text(this.voteState.message).fontSize(12)
          .fontColor(this.isDark ? '#CCCCCC' : '#61666D').width('100%')
      }
      if (!this.voteState.loading && !this.voteState.submitting && !getCard().loaded && !getCard().deleted) {
        Button('重新加载投票', { type: ButtonType.Normal })
          .height(30).fontSize(12).fontColor(this.accent).backgroundColor('#00000000')
          .accessibilityText('重新加载评论投票').onClick(this.voteAction(getCard(), (): void => { this.controller.load(); }))
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding(12).borderRadius(10)
    .backgroundColor(this.isDark ? '#24262B' : '#F8F9FB')
    .border({ width: 0.5, color: this.isDark ? '#36383D' : '#E6E9EE' })
  }

  build() {
    Column() {
      if (this.card() !== null) this.Card((): ReplyVoteCard => this.card() ?? new ReplyVoteCard())
    }
    .width('100%')
  }
}
