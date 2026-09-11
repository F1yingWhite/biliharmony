import { RequestEpoch } from '../../common/RequestEpoch';
/** 登录用户的稍后再看。 */
import { AppTheme } from '../../common/AppTheme';
import { Immersive } from '../../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, NAV_FAV_SORT, FavSortParam, VideoDetailParam } from '../../common/AppRouter';
import { BiliApi, ActionResult } from '../../api/BiliApi';
import { FavoriteFolderItem, FavoriteVideoPageData, HistoryPageData, HistoryVideoItem, VideoItem, WatchLaterItem } from '../../model/Models';
import { UserStore } from '../../services/auth/UserStore';
import { formatCount, formatDuration, formatRelativeTime } from '../../common/Utils';
import { LoadingView } from '../../components/LoadingView';
import { LoadMoreFooter } from '../../components/LoadMoreFooter';
import { PageHeader } from '../../components/PageHeader';
import { VideoRowCard } from '../../components/video/VideoRowCard';
import { BasicDataSource } from '../../common/BasicDataSource';
import { FavoriteApi } from '../../api/FavoriteApi';
import { HistoryApi } from '../../api/HistoryApi';

@Component
export struct WatchLaterPage {
  @State loading: boolean = false;
  @State preparing: boolean = true;
  @State itemCount: number = 0;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private itemsSource: BasicDataSource<WatchLaterItem> = new BasicDataSource<WatchLaterItem>();
  private actionBusy: boolean = false;
  private listEpoch: RequestEpoch = new RequestEpoch();
  private prepareEpoch: RequestEpoch = new RequestEpoch();
  private destroyed: boolean = false;

  aboutToDisappear(): void {
    this.destroyed = true;
    this.listEpoch.invalidate();
    this.prepareEpoch.invalidate();
  }

  aboutToAppear(): void {
    this.destroyed = false;
    this.loading = false;
    this.prepareAndLoad();
  }

  /** 统一 toast：用 UIContext 版 PromptAction，避开全局 promptAction 的废弃告警。 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // toast 失败不影响业务流程
    }
  }

  private async prepareAndLoad(): Promise<void> {
    const epoch: number = this.prepareEpoch.next();
    this.preparing = true;
    try {
      await UserStore.ensureLoaded();
      if (this.destroyed || !this.prepareEpoch.isCurrent(epoch)) return;
      if (!UserStore.isLogin) {
        this.errorText = '登录后才能查看稍后再看';
        return;
      }
      await this.load();
    } catch (e) {
      if (!this.destroyed && this.prepareEpoch.isCurrent(epoch)) this.errorText = '稍后再看加载失败，请检查网络后重试';
    } finally {
      if (!this.destroyed && this.prepareEpoch.isCurrent(epoch)) this.preparing = false;
    }
  }

  async load(): Promise<void> {
    if (this.destroyed || this.loading || this.actionBusy) return;
    const epoch: number = this.listEpoch.next();
    this.loading = true;
    this.errorText = '';
    try {
      const items: Array<WatchLaterItem> = await HistoryApi.getWatchLaterList();
      if (!this.listEpoch.isCurrent(epoch)) return;
      this.itemsSource.reset(items);
      this.itemCount = items.length;
    } catch (e) {
      if (!this.listEpoch.isCurrent(epoch)) return;
      if (this.itemsSource.isEmpty()) this.errorText = '稍后再看加载失败，请检查网络后重试';
    } finally {
      if (this.listEpoch.isCurrent(epoch)) this.loading = false;
    }
  }

  /** 删除单条：接口成功后本地移除并重载列表。 */
  private async removeItem(item: WatchLaterItem): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await HistoryApi.delWatchLater([item.video.aid]);
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.listEpoch.invalidate();
      this.loading = false;
      this.errorText = '';
      this.toast('已移除');
      this.itemsSource.reset(this.itemsSource.getAll().filter((v: WatchLaterItem) => v.video.aid !== item.video.aid));
      this.itemCount = this.itemsSource.totalCount();
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  private confirmClear(): void {
    if (this.itemCount === 0 || this.actionBusy) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '清空稍后再看',
        message: '确定要清空全部稍后再看吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '清空', color: this.accent },
        ],
      }).then((dialogResult) => {
        if (dialogResult.index === 1) {
          this.clearAll().catch(() => {
          });
        }
      });
    } catch (e) {
      // 弹窗失败不阻塞页面
    }
  }

  private async clearAll(): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await HistoryApi.clearWatchLater();
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.listEpoch.invalidate();
      this.loading = false;
      this.errorText = '';
      this.toast('已清空稍后再看');
      this.itemsSource.clear();
      this.itemCount = 0;
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  @Builder
  ClearAction() {
    if (this.itemCount > 0) {
      Text('清空')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => this.confirmClear())
    }
  }

  @Builder
  SwipeDelete(item: WatchLaterItem) {
    Row() {
      Text('删除')
        .fontSize(14)
        .fontColor('#FFFFFF')
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppTheme.DANGER)
    .onClick(() => {
      this.removeItem(item).catch(() => {
      });
    })
  }

  build() {
    Column() {
      PageHeader({
        title: '稍后再看',
        trailing: (): void => {
          this.ClearAction()
        },
      })
      if (this.itemCount === 0) {
        LoadingView({ skeleton: 'list', loading: this.loading || this.preparing, empty: !this.loading && this.errorText.length === 0,
          emptyText: '暂无稍后再看内容', errorText: this.errorText,
          onRetry: () => this.prepareAndLoad().catch(() => {
          }) })
      } else {
        List() {
          LazyForEach(this.itemsSource, (item: WatchLaterItem) => {
            ListItem() {
              VideoRowCard({
                cover: item.video.cover,
                title: item.video.title,
                upName: item.video.upName,
                overlayText: item.video.duration > 0 ? formatDuration(item.video.duration) : '',
                extraText: item.progress > 0 && item.video.duration > 0 ?
                  '已看到 ' + formatDuration(item.progress) : formatCount(item.video.play) + ' 播放',
                titleDarkColor: '#F2F2F4',
                onTap: () => {
                  const param: VideoDetailParam = { bvid: item.video.bvid, aid: item.video.aid, title: item.video.title };
                  AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                },
              })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.SwipeDelete(item)
                },
              },
            })
          }, (item: WatchLaterItem) => String(item.video.aid))
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .cachedCount(5)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
