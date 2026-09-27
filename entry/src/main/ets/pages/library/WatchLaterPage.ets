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
  @State selecting: boolean = false;
  @State selectedAids: Set<number> = new Set<number>();
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

  private toggleSelect(aid: number): void {
    const next: Set<number> = new Set<number>(this.selectedAids);
    if (next.has(aid)) next.delete(aid);
    else next.add(aid);
    this.selectedAids = next;
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedAids = new Set<number>();
  }

  private confirmRemoveSelected(): void {
    if (this.selectedAids.size === 0 || this.actionBusy) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除所选',
        message: '确定删除选中的 ' + String(this.selectedAids.size) + ' 个视频吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '删除', color: this.accent },
        ],
      }).then((dialogResult) => {
        if (dialogResult.index === 1) this.removeSelected().catch(() => {
        });
      });
    } catch (e) {
      // 弹窗失败不阻塞页面
    }
  }

  /** 批量删除：delWatchLater 本就接受 aid 数组，一次请求完成。 */
  private async removeSelected(): Promise<void> {
    if (this.actionBusy) return;
    const aids: Array<number> = Array.from(this.selectedAids);
    this.actionBusy = true;
    try {
      const result: ActionResult = await HistoryApi.delWatchLater(aids);
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.toast('已删除 ' + String(aids.length) + ' 个视频');
      this.exitSelecting();
      await this.load();
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  @Builder
  HeaderSelectAction() {
    if (this.selecting) {
      Text('取消')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => this.exitSelecting())
    } else if (this.itemCount > 0) {
      Text('多选')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => {
          this.selecting = true;
        })
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
        title: this.selecting ? '已选 ' + String(this.selectedAids.size) + ' 项' : '稍后再看',
        trailing: (): void => {
          if (this.selecting) this.HeaderSelectAction()
          else this.ClearAction()
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
              Stack({ alignContent: Alignment.Start }) {
              VideoRowCard({
                cover: item.video.cover,
                title: item.video.title,
                upName: item.video.upName,
                overlayText: item.video.duration > 0 ? formatDuration(item.video.duration) : '',
                extraText: item.progress > 0 && item.video.duration > 0 ?
                  '已看到 ' + formatDuration(item.progress) : formatCount(item.video.play) + ' 播放',
                titleDarkColor: '#F2F2F4',
                onTap: () => {
                  if (this.selecting) {
                    this.toggleSelect(item.video.aid);
                    return;
                  }
                  const param: VideoDetailParam = { bvid: item.video.bvid, aid: item.video.aid, title: item.video.title };
                  AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                },
              })
              if (this.selecting) {
                Row({ space: 4 }) {
                  Text(this.selectedAids.has(item.video.aid) ? '✓' : '')
                    .fontSize(13)
                    .fontColor('#FFFFFF')
                    .width(22)
                    .height(22)
                    .textAlign(TextAlign.Center)
                    .borderRadius(11)
                    .backgroundColor(this.selectedAids.has(item.video.aid) ? this.accent : '#66FFFFFF')
                    .border({ width: 1.5, color: '#FFFFFF' })
                }
                .width('100%')
                .height('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: 16 })
                .onClick(() => this.toggleSelect(item.video.aid))
              }
              }
            }
            .swipeAction(this.selecting ? undefined : {
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
        .blur(this.selecting ? 0 : undefined)
      }
      if (this.selecting) {
        Row({ space: 12 }) {
          Blank()
          Button('删除所选（' + String(this.selectedAids.size) + '）')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(this.selectedAids.size > 0 ? AppTheme.DANGER : '#999999')
            .padding({ left: 18, right: 18, top: 9, bottom: 9 })
            .onClick(() => this.confirmRemoveSelected())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.isDark ? '#26272B' : '#F5F6F7')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
