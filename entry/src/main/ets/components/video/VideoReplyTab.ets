/**
 * 视频详情页「评论」Tab：排序栏 + 懒加载评论列表 + 输入栏 + 表情面板 + 加载更多。
 * 从 VideoDetail 页拆出；滚动-播放器联动仍由页面传入的 replyScroller 与 onScrollFrame 回调驱动。
 */
import { ReplyItem, BiliEmote, BiliEmotePackage } from '../../model/Models';
import { formatCount } from '../../common/Utils';
import { LoadingView } from '../LoadingView';
import { BasicDataSource } from '../../common/BasicDataSource';
import { ReplyCard } from '../reply/ReplyCard';
import { ReplyComposer } from '../reply/ReplyComposer';
import { ReplyEmotePanel } from '../reply/ReplyEmotePanel';
import { ReplySortChips } from '../reply/ReplySortChips';

/** 「加载更多」底部块参数：对象字面量按引用传入，状态变化才能驱动 @Builder 刷新。 */
interface LoadMoreFooterOptions {
  loading: boolean;
  hasMore: boolean;
  moreText: string;
  endText: string;
  onTap: () => void;
}
@Component
export struct VideoReplyTab {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @Prop replyCount: number = 0;
  @Prop upMid: number = 0;
  @Prop sortMode: number = 3;
  @Prop loading: boolean = false;
  @Prop hasMore: boolean = false;
  @Prop errorText: string = '';
  @Prop version: number = 0;
  @Prop draft: string = '';
  @Prop sending: boolean = false;
  @Prop placeholder: string = '发一条友善的评论';
  @Prop emoteOpen: boolean = false;
  @Prop focusTick: number = 0;
  @Prop emotePackages: Array<BiliEmotePackage> = [];
  @Prop emotePackageIndex: number = 0;
  @Prop emoteLoading: boolean = false;
  @Prop emotePanelHeight: number = 300;
  @Prop screenWidth: number = 0;
  // 数据源与滚动器按引用传入（BasicDataSource 自身 notify 驱动列表刷新）。
  source: BasicDataSource<ReplyItem> = new BasicDataSource<ReplyItem>();
  scroller: Scroller = new Scroller();
  onSortChange: (mode: number) => void = () => {};
  onLoadMore: (reset: boolean) => void = () => {};
  onLike: (item: ReplyItem) => void = () => {};
  onDislike: (item: ReplyItem) => void = () => {};
  onShare: (item: ReplyItem) => void = () => {};
  onSelectReply: (item: ReplyItem) => void = () => {};
  onOpenThread: (item: ReplyItem) => void = () => {};
  onDeleted: (item: ReplyItem) => void = () => {};
  onDraftChange: (value: string) => void = () => {};
  onSend: () => void = () => {};
  onToggleEmote: () => void = () => {};
  onRequestKeyboard: () => void = () => {};
  onFocusChange: (focused: boolean) => void = () => {};
  onEmoteSelect: (item: BiliEmote) => void = () => {};
  onEmotePackageChange: (index: number) => void = () => {};
  onScrollFrame: (offset: number, scroller: Scroller, state: ScrollState) => number =
    (offset: number) => offset;

  build() {
    Column() {
      this.sortBar()
      if (this.source.isEmpty()) {
        Column() {
          LoadingView({
            loading: this.loading,
            // 错误与真实空列表互斥；LoadingView 的空态优先级高于错误态。
            empty: !this.loading && this.errorText.length === 0,
            emptyText: '还没有评论，快来抢沙发～',
            errorText: this.errorText,
            onRetry: () => {
              this.onLoadMore(true);
            },
          })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List({ scroller: this.scroller }) {
          LazyForEach(this.source, (item: ReplyItem) => {
            ListItem() {
              ReplyCard({
                item: item,
                showPreview: true,
                version: this.version,
                upMid: this.upMid,
                onLike: (reply: ReplyItem) => this.onLike(reply),
                onDislike: (reply: ReplyItem) => this.onDislike(reply),
                onShare: (reply: ReplyItem) => this.onShare(reply),
                // 主评论列表：底部“回复”直接选中该楼层并聚焦下方输入栏；
                // “共 N 条回复”预览条才进入楼中楼详情。
                onSelectReply: (reply: ReplyItem) => this.onSelectReply(reply),
                onOpenThread: (reply: ReplyItem) => this.onOpenThread(reply),
                onDeleted: (reply: ReplyItem) => this.onDeleted(reply),
              })
            }
            // 保持稳定 key，让 ReplyCard 的 @State 镜像原地更新；把 rev 放进 key 会销毁并
            // 重建整张卡片，造成闪烁，触摸尚未结束时还可能再次命中新卡。
          }, (item: ReplyItem) => String(item.rpid))
          ListItem() {
            this.loadMoreFooter({
              loading: this.loading,
              hasMore: this.hasMore,
              moreText: '继续加载更多评论',
              endText: '—— 评论到底啦 ——',
              onTap: () => {
                if (this.hasMore && !this.loading) this.onLoadMore(false);
              },
            })
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .onScrollFrameBegin((offset: number, state: ScrollState) => {
          return { offsetRemain: this.onScrollFrame(offset, this.scroller, state) };
        })
        .onReachEnd(() => {
          if (this.hasMore) {
            this.onLoadMore(false);
          }
        })
      }
      this.inputBar()
      if (this.emoteOpen) this.emotePanel()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private sortBar() {
    Row({ space: 8 }) {
      Text('评论 ' + formatCount(this.replyCount))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
      // 排序切换与动态/番剧详情共用 chips 样式（最热 mode=3 / 最新 mode=2）。
      ReplySortChips({
        mode: this.sortMode,
        onChange: (mode: number) => {
          this.onSortChange(mode);
        },
      })
    }
    .width('100%')
    .height(42)
    .padding({ left: 14, right: 14 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  private inputBar() {
    ReplyComposer({
      text: this.draft,
      emotePackages: this.emotePackages,
      placeholder: this.placeholder,
      sending: this.sending,
      emoteOpen: this.emoteOpen,
      focusTick: this.focusTick,
      onChange: (value: string) => {
        this.onDraftChange(value);
      },
      onSend: () => this.onSend(),
      onToggleEmote: () => this.onToggleEmote(),
      onRequestKeyboard: () => this.onRequestKeyboard(),
      onFocusChange: (focused: boolean) => this.onFocusChange(focused),
    })
  }

  @Builder
  private emotePanel() {
    ReplyEmotePanel({
      packages: this.emotePackages,
      currentIndex: this.emotePackageIndex,
      loading: this.emoteLoading,
      panelHeight: this.emotePanelHeight,
      screenWidth: this.screenWidth,
      onPackageChange: (index: number) => this.onEmotePackageChange(index),
      onSelect: (item: BiliEmote) => this.onEmoteSelect(item),
    })
  }

  // 「加载更多」底部块：loading / 继续加载 / 到底啦 三分支。
  @Builder
  private loadMoreFooter(options: LoadMoreFooterOptions) {
    Row() {
      if (options.loading) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.accent)
      } else if (options.hasMore) {
        Text(options.moreText)
          .fontSize(12)
          .fontColor(this.accent)
      } else {
        Text(options.endText)
          .fontSize(12)
          .fontColor('#9499A0')
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 16 })
    .onClick(() => {
      options.onTap();
    })
  }
}
