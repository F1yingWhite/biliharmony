import { BiliEmotePackage, ReplyItem } from '../model/Models';
import { formatCount } from '../common/Utils';
import { LayoutTokens } from '../common/LayoutTokens';
import { ReplyCard } from './ReplyCard';
import { ReplyComposer } from './ReplyComposer';
import { buildReplyTree, ReplyTreeMeta, ReplyTreeSnapshot } from '../common/ReplyTree';
import { CommentLog } from '../common/CommentLog';

/** 动态、视频等业务可复用的回复详情容器；业务页只负责接口与状态。 */
@Component
export struct ReplyThreadPanel {
  @Prop @Watch('onRootChanged') root: ReplyItem = new ReplyItem();
  @Prop @Watch('onRepliesChanged') replies: Array<ReplyItem> = [];
  @Prop loading: boolean = false;
  @Prop hasMore: boolean = false;
  @Prop version: number = 0;
  @Prop draft: string = '';
  @Prop sending: boolean = false;
  @Prop replyTargetName: string = '';
  @Prop focusTick: number = 0;
  @Prop focusId: string = 'thread_reply_composer_editor';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  /** 楼主（动态/稿件作者）mid，用于标注"UP主"。 */
  @Prop upMid: number = 0;
  @Prop showEmoteButton: boolean = false;
  @Prop emoteOpen: boolean = false;
  @Prop emotePackages: Array<BiliEmotePackage> = [];
  onClose: () => void = () => {};
  onLike: (item: ReplyItem) => void = () => {};
  onDislike: (item: ReplyItem) => void = () => {};
  onShare: (item: ReplyItem) => void = () => {};
  onSelectReply: (item: ReplyItem) => void = () => {};
  onDeleted: (item: ReplyItem) => void = () => {};
  onLoadMore: () => void = () => {};
  onDraftChange: (value: string) => void = () => {};
  onSend: () => void = () => {};
  onToggleEmote: () => void = () => {};
  onRequestKeyboard: () => void = () => {};
  onFocusChange: (focused: boolean) => void = () => {};
  onNavigate: (action: () => void) => void = (action: () => void) => action();
  @BuilderParam emotePanel: () => void = this.EmptyPanel;
  @State visibleReplies: Array<ReplyItem> = [];
  @State treeVersion: number = 0;
  private collapsed: Set<number> = new Set<number>();
  private metaMap: Map<number, ReplyTreeMeta> = new Map<number, ReplyTreeMeta>();
  private nameMap: Map<number, string> = new Map<number, string>();

  aboutToAppear(): void {
    this.rebuildTree();
  }

  onRepliesChanged(): void {
    this.rebuildTree();
  }

  onRootChanged(): void {
    this.collapsed.clear();
    this.rebuildTree();
  }

  @Builder
  EmptyPanel() {
  }

  private rebuildTree(): void {
    const snapshot: ReplyTreeSnapshot = buildReplyTree(this.root.rpid, this.replies, this.collapsed);
    this.metaMap = snapshot.meta;
    this.nameMap = snapshot.names;
    this.visibleReplies = snapshot.visible;
    this.treeVersion++;
    CommentLog.info('tree.rebuild', 'root=' + String(this.root.rpid) + ' input=' +
      String(this.replies.length) + ' visible=' + String(snapshot.visible.length) + ' meta=' +
      String(snapshot.meta.size) + ' collapsed=' + String(this.collapsed.size) +
      ' version=' + String(this.treeVersion));
  }

  private meta(item: ReplyItem): ReplyTreeMeta {
    const value: ReplyTreeMeta | undefined = this.metaMap.get(item.rpid);
    return value !== undefined ? value : new ReplyTreeMeta();
  }

  private parentName(item: ReplyItem): string {
    if (item.parentRpid === this.root.rpid) return this.root.uname;
    const value: string | undefined = this.nameMap.get(item.parentRpid);
    return value !== undefined ? value : '';
  }

  private toggleBranch(item: ReplyItem): void {
    const meta: ReplyTreeMeta = this.meta(item);
    if (!meta.hasChildren) {
      CommentLog.warn('tree.toggle.skip', 'rpid=' + String(item.rpid) + ' reason=no-children');
      return;
    }
    if (this.collapsed.has(item.rpid)) this.collapsed.delete(item.rpid);
    else this.collapsed.add(item.rpid);
    CommentLog.info('tree.toggle', 'root=' + String(this.root.rpid) + ' rpid=' + String(item.rpid) +
      ' collapsed=' + String(this.collapsed.has(item.rpid)));
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseInOut }, () => this.rebuildTree());
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('‹').fontSize(26).fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('回复详情')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
        Text(formatCount(this.root.count) + ' 条')
          .fontSize(11)
          .fontColor('#9499A0')
      }
      .width('100%')
      .height(46)
      .padding({ left: 12, right: 16 })
      .onClick(() => this.onClose())

      List() {
        ListItem() {
          ReplyCard({
            item: this.root,
            version: this.version,
            upMid: this.upMid,
            onLike: (item: ReplyItem) => this.onLike(item),
            onDislike: (item: ReplyItem) => this.onDislike(item),
            onShare: (item: ReplyItem) => this.onShare(item),
            onSelectReply: (item: ReplyItem) => this.onSelectReply(item),
            onDeleted: (item: ReplyItem) => this.onDeleted(item),
            onNavigate: (action: () => void) => this.onNavigate(action),
          })
        }
        ListItem() {
          Row({ space: 5 }) {
            Text('相关回复')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            Text('共 ' + formatCount(this.root.count) + ' 条').fontSize(11).fontColor('#9499A0')
          }
          .width('100%')
          .height(42)
          .border({ width: { top: 0.5 }, color: this.isDark ? '#36383D' : '#E7E9EC' })
        }
        ForEach(this.visibleReplies, (item: ReplyItem) => {
          ListItem() {
            ReplyCard({
              item: item,
              showPreview: false,
              threadDepth: this.meta(item).depth,
              threadGuides: this.meta(item).guides,
              threadHasChildren: this.meta(item).hasChildren,
              threadCollapsed: this.meta(item).collapsed,
              parentLabel: this.parentName(item),
              version: this.version + this.treeVersion,
              upMid: this.upMid,
              onLike: (reply: ReplyItem) => this.onLike(reply),
              onDislike: (reply: ReplyItem) => this.onDislike(reply),
              onShare: (reply: ReplyItem) => this.onShare(reply),
              onSelectReply: (reply: ReplyItem) => this.onSelectReply(reply),
              onToggleThread: (reply: ReplyItem) => this.toggleBranch(reply),
              onDeleted: (reply: ReplyItem) => this.onDeleted(reply),
              onNavigate: (action: () => void) => this.onNavigate(action),
            })
          }
          // 稳定 key 保留组件，由 ReplyCard 的 @State 镜像原地刷新点赞态与计数。
        }, (item: ReplyItem) => String(item.rpid))
        ListItem() {
          Row() {
            if (this.loading) {
              LoadingProgress().width(22).height(22).color(this.accent)
            } else if (this.hasMore) {
              Text('继续加载更多回复').fontSize(12).fontColor(this.accent)
            } else {
              Text('—— 回复到底啦 ——').fontSize(12).fontColor('#9499A0')
            }
          }
          .width('100%')
          .height(48)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            if (!this.loading && this.hasMore) this.onLoadMore();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12 })
      // 折叠会删除当前分支的子项；让 List 原生维持可见内容锚点，
      // 避免旧偏移被钳制到新的最大偏移后直接跳到底部。
      .maintainVisibleContentPosition(true)
      .cachedCount(3)
      .scrollBar(BarState.Off)
      .onReachEnd(() => {
        if (!this.loading && this.hasMore) this.onLoadMore();
      })

      ReplyComposer({
        text: this.draft,
        emotePackages: this.emotePackages,
        placeholder: this.replyTargetName.length > 0 ? '回复 @' + this.replyTargetName : '回复这条评论',
        sending: this.sending,
        emoteOpen: this.emoteOpen,
        focusTick: this.focusTick,
        focusId: this.focusId,
        showEmoteButton: this.showEmoteButton,
        onChange: (value: string) => this.onDraftChange(value),
        onSend: () => this.onSend(),
        onToggleEmote: () => this.onToggleEmote(),
        onRequestKeyboard: () => this.onRequestKeyboard(),
        onFocusChange: (focused: boolean) => this.onFocusChange(focused),
      })
      if (this.emoteOpen) this.emotePanel()
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
    .alignSelf(ItemAlign.Center)
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
