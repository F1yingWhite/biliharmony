/**
 * 消息中心通知列表：回复我的 / @我 / 收到的赞 / 系统通知共用一套列表与分页逻辑。
 * 头像跳用户空间；能解析出视频 aid/bvid 的通知点击跳视频详情，否则不跳。
 */
import { BiliApi } from '../api/BiliApi';
import { AppNavStack, NAV_USER_SPACE, NAV_VIDEO_DETAIL, UserSpaceParam, VideoDetailParam } from '../common/AppRouter';
import { BasicDataSource } from '../common/BasicDataSource';
import { MsgUnreadStore } from '../common/MsgUnreadStore';
import { colorWithAlpha, formatRelativeTime } from '../common/Utils';
import { MsgNotifyItem, MsgNotifyPageData } from '../model/Models';
import { LoadingView } from './LoadingView';
import { LoadMoreFooter } from './LoadMoreFooter';

@Component
export struct MsgNotifyList {
  /** reply | at | like | sys */
  tab: string = 'reply';
  @State loading: boolean = false;
  @State error: string = '';
  @State hasMore: boolean = true;
  @State itemCount: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private source: BasicDataSource<MsgNotifyItem> = new BasicDataSource<MsgNotifyItem>();
  private cursorId: string = '';
  private cursorTime: string = '';
  private sysCursor: string = '';
  private sysReadReported: boolean = false;

  aboutToAppear(): void {
    // 首次进入该分类即在本地清零头栏角标；系统通知在首屏拉取成功后向服务端上报已读游标。
    MsgUnreadStore.clearCategory(this.tab);
    this.load(true).catch(() => {
    });
  }

  async load(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    this.loading = true;
    try {
      const data: MsgNotifyPageData = this.tab === 'sys' ?
        await BiliApi.getSysNotifications(reset ? '' : this.sysCursor) :
        await BiliApi.getMsgFeedNotify(this.tab, reset ? '' : this.cursorId, reset ? '' : this.cursorTime);
      if (data.error.length > 0) {
        // 失败不清空已有列表；首次加载失败时由 LoadingView 展示原因与重试。
        if (reset) this.error = data.error;
        return;
      }
      this.error = '';
      if (reset) {
        this.source.reset(data.items);
      } else {
        this.source.append(this.dedup(data.items));
      }
      this.itemCount = this.source.totalCount();
      this.hasMore = data.hasMore;
      this.cursorId = data.cursorId;
      this.cursorTime = data.cursorTime;
      this.sysCursor = data.sysCursor;
      if (this.tab === 'sys' && !this.sysReadReported && data.items.length > 0) {
        this.sysReadReported = true;
        BiliApi.updateSysMsgCursor(data.items[0].sysCursor).catch(() => {
        });
      }
    } finally {
      this.loading = false;
    }
  }

  /** 分页去重：「收到的赞」latest/total 可能重叠，翻页边界处也可能重复返回同一条。 */
  private dedup(incoming: Array<MsgNotifyItem>): Array<MsgNotifyItem> {
    const seen: Set<number> = new Set<number>();
    const all: Array<MsgNotifyItem> = this.source.getAll();
    for (let i: number = 0; i < all.length; i++) {
      seen.add(all[i].id);
    }
    const out: Array<MsgNotifyItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      if (incoming[i].id > 0 && seen.has(incoming[i].id)) continue;
      seen.add(incoming[i].id);
      out.push(incoming[i]);
    }
    return out;
  }

  private openItem(item: MsgNotifyItem): void {
    if (item.bvid.length === 0 && item.aid <= 0) return;
    const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.text };
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  private openUser(item: MsgNotifyItem): void {
    if (item.mid <= 0) return;
    const param: UserSpaceParam = { mid: item.mid };
    AppNavStack.pushPathByName(NAV_USER_SPACE, param);
  }

  private emptyText(): string {
    if (this.tab === 'reply') return '暂无回复';
    if (this.tab === 'at') return '暂无@我的消息';
    if (this.tab === 'like') return '暂无收到的赞';
    return '暂无系统通知';
  }

  @Builder
  NotifyRow(item: MsgNotifyItem) {
    Row({ space: 12 }) {
      if (this.tab === 'sys') {
        // 系统通知无触发用户头像，用消息图标占位。
        Stack() {
          Image($r('app.media.ic_message'))
            .width(22).height(22)
            .fillColor(this.accent)
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(colorWithAlpha(this.accent, '26'))
      } else if (item.avatar.length > 0) {
        Image(item.avatar)
          .width(44).height(44).borderRadius(22).objectFit(ImageFit.Cover)
          .onClick(() => this.openUser(item))
      } else {
        Circle().width(44).height(44).fill(colorWithAlpha(this.accent, '33'))
          .onClick(() => this.openUser(item))
      }
      Column({ space: 5 }) {
        Row() {
          Text(item.nickname)
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.accent)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.action)
            .fontSize(13).fontColor(this.isDark ? '#C8C8CC' : '#61666D')
            .maxLines(1).layoutWeight(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.timeText.length > 0 ? item.timeText : formatRelativeTime(item.timestamp))
            .fontSize(10).fontColor('#B0B3B8')
        }
        .width('100%')
        if (item.text.length > 0) {
          Text(item.text)
            .fontSize(14).fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        if (item.source.length > 0) {
          Text('| ' + item.source)
            .fontSize(12).fontColor('#9499A0')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (item.image.length > 0) {
        Image(item.image)
          .width(44).height(44).borderRadius(8).objectFit(ImageFit.Cover)
      }
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .onClick(() => this.openItem(item))
  }

  build() {
    Column() {
      if (this.itemCount === 0) {
        LoadingView({
          loading: this.loading,
          empty: !this.loading && this.error.length === 0,
          emptyText: this.emptyText(),
          errorText: this.error,
          onRetry: () => this.load(true).catch(() => {
          }),
        })
      } else {
        List() {
          LazyForEach(this.source, (item: MsgNotifyItem) => {
            ListItem() { this.NotifyRow(item) }
          }, (item: MsgNotifyItem, index: number) => this.tab + '-' + String(item.id) + '-' + String(index))
          ListItem() {
            LoadMoreFooter({
              loading: this.loading,
              hasMore: this.hasMore,
              moreText: '',
              endText: '',
              fixedHeight: this.loading ? 48 : 1,
            })
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .cachedCount(5)
        .onReachEnd(() => {
          this.load(false).catch(() => {
          });
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
