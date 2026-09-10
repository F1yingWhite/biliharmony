/** 登录用户的观看历史。 */
import { HistoryPager } from '../../services/library/HistoryPager';
import { AuthSession } from '../../services/auth/AuthSession';
import { AppTheme } from '../../common/AppTheme';
import { Immersive } from '../../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../../common/AppRouter';
import { ActionResult } from '../../api/BiliApi';
import { HistoryVideoItem } from '../../model/Models';
import { UserStore } from '../../services/auth/UserStore';
import { formatDuration, formatRelativeTime } from '../../common/Utils';
import { LoadingView } from '../../components/LoadingView';
import { LoadMoreFooter } from '../../components/LoadMoreFooter';
import { PageHeader } from '../../components/PageHeader';
import { VideoRowCard } from '../../components/video/VideoRowCard';
import { BasicDataSource } from '../../common/BasicDataSource';
import { HistoryApi } from '../../api/HistoryApi';

@Component
export struct HistoryPage {
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State itemCount: number = 0;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVersion: number = 0;
  private pager: HistoryPager = new HistoryPager();
  private itemsSource: BasicDataSource<HistoryVideoItem> = this.pager.source;
  private destroyed: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    this.loading = false;
    this.prepareAndLoad();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.pager.cancel();
  }

  private onLoginChanged(): void {
    this.pager.cancel();
    this.itemsSource.clear();
    if (this.destroyed) return;
    this.itemCount = 0;
    this.loading = false;
    this.prepareAndLoad();
  }

  private async prepareAndLoad(): Promise<void> {
    const session: number = AuthSession.version;
    try {
      await UserStore.ensureLoaded();
      if (this.destroyed || session !== AuthSession.version) return;
      if (!UserStore.isLogin) {
        this.errorText = '登录后才能加载观看历史';
        return;
      }
      await this.load(true);
    } catch (e) {
      if (!this.destroyed && session === AuthSession.version) this.errorText = '历史记录加载失败，请检查网络后重试';
    }
  }

  private syncPager(): void {
    this.loading = this.pager.loading;
    this.hasMore = this.pager.hasMore;
    this.errorText = this.pager.error;
    this.itemCount = this.itemsSource.totalCount();
  }

  async load(reset: boolean): Promise<void> {
    if (this.destroyed) return;
    const session: number = AuthSession.version;
    const task: Promise<void> = this.pager.load(reset);
    this.syncPager();
    await task;
    if (!this.destroyed && session === AuthSession.version) this.syncPager();
  }

  private async retryLoad(): Promise<void> {
    if (this.destroyed) return;
    const session: number = AuthSession.version;
    const task: Promise<void> = this.pager.retry();
    this.syncPager();
    await task;
    if (!this.destroyed && session === AuthSession.version) this.syncPager();
  }

  build() {
    Column() {
      PageHeader({
        title: '历史记录',
        trailing: (): void => {
          this.ClearHistoryAction()
        },
      })
      if (this.itemCount === 0) {
        LoadingView({ loading: this.loading, empty: !this.loading && this.errorText.length === 0,
          emptyText: '暂无观看历史', errorText: this.errorText,
          onRetry: () => this.prepareAndLoad().catch(() => {
          }) })
      } else {
        List() {
          LazyForEach(this.itemsSource, (item: HistoryVideoItem) => {
            ListItem() {
              VideoRowCard({
                cover: item.video.cover,
                title: item.video.title,
                upName: item.video.upName,
                overlayText: item.progress > 0 && item.video.duration > 0 ?
                  formatDuration(item.progress) + ' / ' + formatDuration(item.video.duration) : '',
                extraText: formatRelativeTime(item.viewAt) + '看过',
                titleDarkColor: '#F2F2F4',
                onTap: () => {
                  const param: VideoDetailParam = { bvid: item.video.bvid, aid: item.video.aid, title: item.video.title };
                  AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                },
              })
                .gesture(
                  LongPressGesture({ repeat: false })
                    .onAction(() => this.confirmDeleteHistory(item))
                )
            }
          }, (item: HistoryVideoItem) => item.video.bvid + String(item.viewAt))
          ListItem() {
            LoadMoreFooter({
              loading: this.loading,
              hasMore: this.errorText.length > 0 || this.hasMore,
              moreText: this.errorText.length > 0 ? this.errorText + ' · 点击重试' : '继续加载',
              endText: '—— 到底啦 ——',
              loadingText: '加载中…',
              accentLoadingText: true,
              padTop: 18,
              padBottom: 18,
              onLoadMore: () => {
                (this.errorText.length > 0 ? this.retryLoad() : this.load(false)).catch(() => {
                });
              },
            })
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .cachedCount(5)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          if (this.errorText.length > 0) return;
          this.load(false).catch(() => {
          });
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  /** 长按删除单条历史：二次确认。 */
  private confirmDeleteHistory(item: HistoryVideoItem): void {
    const session: number = AuthSession.version;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除历史',
        message: '删除后无法找回，确定删除这条观看记录吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '删除', color: AppTheme.DANGER },
        ],
      }).then((dialogResult) => {
        if (this.destroyed || session !== AuthSession.version || Number(dialogResult.index) !== 1) return;
        HistoryApi.deleteHistoryItem(item.video.bvid)
          .then((r: ActionResult) => {
            if (this.destroyed || session !== AuthSession.version) return;
            if (r.ok) {
              this.pager.remove(item.video.bvid);
              this.syncPager();
              this.getUIContext().getPromptAction().showToast({ message: '已删除' });
            } else {
              this.getUIContext().getPromptAction().showToast({ message: r.message });
            }
          })
          .catch(() => {
            if (this.destroyed || session !== AuthSession.version) return;
            this.getUIContext().getPromptAction().showToast({ message: '删除失败，请稍后重试' });
          });
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  /** 页头右侧「清空」按钮（@BuilderParam 必须传 @Builder 方法，内联组件会崩）。 */
  @Builder
  ClearHistoryAction() {
    Text('清空')
      .fontSize(13)
      .fontColor(this.itemsSource.totalCount() > 0 ? AppTheme.DANGER : '#9499A0')
      .padding({ left: 18, right: 2, top: 8, bottom: 8 })
      .onClick(() => {
        if (this.itemsSource.totalCount() > 0) this.confirmClearHistory();
      })
  }

  /** 清空全部历史：二次确认。 */
  private confirmClearHistory(): void {
    const session: number = AuthSession.version;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '清空历史',
        message: '将删除全部观看历史，此操作不可恢复。确定清空吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '清空', color: AppTheme.DANGER },
        ],
      }).then((dialogResult) => {
        if (this.destroyed || session !== AuthSession.version || Number(dialogResult.index) !== 1) return;
        HistoryApi.clearHistory()
          .then((r: ActionResult) => {
            if (this.destroyed || session !== AuthSession.version) return;
            if (r.ok) {
              this.pager.clear();
              this.syncPager();
              this.getUIContext().getPromptAction().showToast({ message: '历史已清空' });
            } else {
              this.getUIContext().getPromptAction().showToast({ message: r.message });
            }
          })
          .catch(() => {
            if (this.destroyed || session !== AuthSession.version) return;
            this.getUIContext().getPromptAction().showToast({ message: '清空失败，请稍后重试' });
          });
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }
}
