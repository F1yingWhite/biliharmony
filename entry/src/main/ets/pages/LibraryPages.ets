/** 登录用户的观看历史与收藏夹。 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { BiliApi } from '../api/BiliApi';
import { FavoriteFolderItem, FavoriteVideoPageData, HistoryPageData, HistoryVideoItem, VideoItem } from '../model/Models';
import { UserStore } from '../common/UserStore';
import { formatCount, formatDuration, formatRelativeTime } from '../common/Utils';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { PageHeader } from '../components/PageHeader';
import { VideoRowCard } from '../components/VideoRowCard';
import { BasicDataSource } from '../common/BasicDataSource';

@Component
export struct HistoryPage {
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State cursorMax: number = 0;
  @State cursorViewAt: number = 0;
  @State itemCount: number = 0;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private itemsSource: BasicDataSource<HistoryVideoItem> = new BasicDataSource<HistoryVideoItem>();

  aboutToAppear(): void {
    this.prepareAndLoad();
  }

  private async prepareAndLoad(): Promise<void> {
    try {
      await UserStore.ensureLoaded();
      if (!UserStore.isLogin) {
        this.errorText = '登录后才能加载观看历史';
        return;
      }
      await this.load(true);
    } catch (e) {
      this.errorText = '历史记录加载失败，请检查网络后重试';
    }
  }

  async load(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    this.loading = true;
    this.errorText = '';
    try {
      const data: HistoryPageData = await BiliApi.getHistory(reset ? 0 : this.cursorMax, reset ? 0 : this.cursorViewAt);
      if (reset) {
        this.itemsSource.reset(data.items);
      } else {
        this.itemsSource.append(this.mergeNew(data.items));
      }
      this.cursorMax = data.max;
      this.cursorViewAt = data.viewAt;
      this.hasMore = data.hasMore;
      this.itemCount = this.itemsSource.totalCount();
    } catch (e) {
      if (this.itemsSource.isEmpty()) this.errorText = '历史记录加载失败，请检查网络后重试';
    } finally {
      this.loading = false;
    }
  }

  /** 追加前按 bvid+观看时间去重，游标翻页边界可能重复返回同一条记录。 */
  private mergeNew(incoming: Array<HistoryVideoItem>): Array<HistoryVideoItem> {
    const keys: Set<string> = new Set<string>();
    const base: Array<HistoryVideoItem> = this.itemsSource.getAll();
    for (let i: number = 0; i < base.length; i++) {
      keys.add(base[i].video.bvid + ':' + String(base[i].viewAt));
    }
    const result: Array<HistoryVideoItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      const key: string = incoming[i].video.bvid + ':' + String(incoming[i].viewAt);
      if (!keys.has(key)) {
        keys.add(key);
        result.push(incoming[i]);
      }
    }
    return result;
  }

  build() {
    Column() {
      PageHeader({ title: '历史记录' })
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
            }
          }, (item: HistoryVideoItem) => item.video.bvid + String(item.viewAt))
          ListItem() {
            LoadMoreFooter({
              loading: this.loading,
              hasMore: this.hasMore,
              moreText: '继续加载',
              endText: '—— 到底啦 ——',
              loadingText: '加载中…',
              accentLoadingText: true,
              padTop: 18,
              padBottom: 18,
              onLoadMore: () => {
                this.load(false).catch(() => {
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
}

@Component
export struct FavoritesPage {
  @State selected: FavoriteFolderItem = new FavoriteFolderItem();
  @State category: number = 0; // 0 收藏夹 / 1 收藏集
  @State folderPage: number = 0;
  @State collectionPage: number = 0;
  @State videoPage: number = 0;
  @State hasMore: boolean = true;
  @State loading: boolean = false;
  @State collectionHasMore: boolean = true;
  @State collectionLoading: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private foldersSource: BasicDataSource<FavoriteFolderItem> = new BasicDataSource<FavoriteFolderItem>();
  private collectionsSource: BasicDataSource<FavoriteFolderItem> = new BasicDataSource<FavoriteFolderItem>();
  private videosSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();

  aboutToAppear(): void {
    this.initFavorites().catch(() => {
    });
  }

  async initFavorites(): Promise<void> {
    await UserStore.ensureLoaded();
    this.loadFolders(true).catch(() => {
    });
    this.loadCollections(true).catch(() => {
    });
  }

  async loadCollections(reset: boolean): Promise<void> {
    if (this.collectionLoading || (!reset && !this.collectionHasMore)) return;
    const user = UserStore.current;
    if (user === null) return;
    this.collectionLoading = true;
    try {
      const page: number = reset ? 1 : this.collectionPage + 1;
      const data = await BiliApi.getCollectedFolders(user.mid, page);
      if (reset) {
        this.collectionsSource.reset(data.folders);
      } else {
        this.collectionsSource.append(data.folders);
      }
      this.collectionPage = page;
      this.collectionHasMore = data.hasMore;
    } catch (e) {
    } finally {
      this.collectionLoading = false;
    }
  }

  async loadFolders(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    const user = UserStore.current;
    if (user === null) return;
    this.loading = true;
    try {
      const page: number = reset ? 1 : this.folderPage + 1;
      const data = await BiliApi.getFavoriteFolders(user.mid, page);
      if (reset) {
        this.foldersSource.reset(data.folders);
      } else {
        this.foldersSource.append(data.folders);
      }
      this.folderPage = page;
      this.hasMore = data.hasMore;
    } catch (e) {
    } finally {
      this.loading = false;
    }
  }

  async openFolder(folder: FavoriteFolderItem): Promise<void> {
    if (this.category === 1 && folder.type === 0) folder.type = 21;
    this.selected = folder;
    this.videosSource.clear();
    this.videoPage = 0;
    this.hasMore = true;
    await this.loadVideos(true);
  }

  async loadVideos(reset: boolean): Promise<void> {
    if (this.loading || this.selected.id === 0 || (!reset && !this.hasMore)) return;
    this.loading = true;
    try {
      const page: number = reset ? 1 : this.videoPage + 1;
      const data: FavoriteVideoPageData = this.selected.type === 21 ?
        await BiliApi.getCollectionVideos(this.selected.id, page) : await BiliApi.getFavoriteVideos(this.selected.id, page);
      if (reset) {
        this.videosSource.reset(data.videos);
      } else {
        this.videosSource.append(data.videos);
      }
      this.videoPage = page;
      this.hasMore = data.hasMore;
    } catch (e) {
    } finally {
      this.loading = false;
    }
  }

  goBack(): void {
    if (this.selected.id > 0) {
      this.selected = new FavoriteFolderItem();
      this.videosSource.clear();
      this.hasMore = this.folderPage > 0;
    } else {
      AppNavStack.pop();
    }
  }

  /** 当前列表的分页加载入口（footer 点击与触底共用） */
  private loadMore(): void {
    if (this.selected.id > 0) {
      this.loadVideos(false).catch(() => {
      });
    } else if (this.category === 1) {
      this.loadCollections(false).catch(() => {
      });
    } else {
      this.loadFolders(false).catch(() => {
      });
    }
  }

  /** 收藏集 Tab 有自己的加载/到底状态，footer 需要按当前列表切换。 */
  private footerLoading(): boolean {
    return this.selected.id === 0 && this.category === 1 ? this.collectionLoading : this.loading;
  }

  private footerHasMore(): boolean {
    return this.selected.id === 0 && this.category === 1 ? this.collectionHasMore : this.hasMore;
  }

  @Builder
  FolderRow(item: FavoriteFolderItem) {
    Row({ space: 12 }) {
      Image(item.cover)
        .width(104)
        .height(68)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
      Column({ space: 7 }) {
        Row({ space: 6 }) {
          Text(item.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.type === 21) {
            Text('合集').fontSize(9).fontColor('#FFFFFF').backgroundColor(this.accent)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(4)
          }
        }
        Text(item.type === 21 ?
          ('创建者：' + item.upperName + ' · ' + formatCount(item.count) + ' 个视频 · ' + formatCount(item.viewCount) + ' 播放') :
          (formatCount(item.count) + ' 个内容' + (item.isPublic ? ' · 公开' : ' · 私密')))
          .fontSize(11)
          .fontColor('#9499A0')
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#B4B6BA')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => this.openFolder(item))
  }

  build() {
    Column() {
      PageHeader({
        title: this.selected.id > 0 ? this.selected.title : '我的收藏',
        onBack: () => this.goBack(),
      })
      if (this.selected.id === 0) {
        Row() {
          Text('收藏夹')
            .layoutWeight(1).height(42).textAlign(TextAlign.Center).fontSize(14)
            .fontWeight(this.category === 0 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.category === 0 ? this.accent : '#9499A0')
            .onClick(() => this.category = 0)
          Text('收藏集')
            .layoutWeight(1).height(42).textAlign(TextAlign.Center).fontSize(14)
            .fontWeight(this.category === 1 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.category === 1 ? this.accent : '#9499A0')
            .onClick(() => this.category = 1)
        }
        .width('100%')
        .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
      }
      if (this.loading && this.foldersSource.isEmpty() && this.videosSource.isEmpty()) {
        LoadingView({ loading: true })
      } else {
        List() {
          if (this.selected.id === 0) {
            if (this.category === 0) {
              LazyForEach(this.foldersSource, (item: FavoriteFolderItem) => {
                ListItem() { this.FolderRow(item) }
              }, (item: FavoriteFolderItem) => String(item.id))
            } else {
              LazyForEach(this.collectionsSource, (item: FavoriteFolderItem) => {
                ListItem() { this.FolderRow(item) }
              }, (item: FavoriteFolderItem) => 'collection-' + String(item.id))
            }
          } else {
            LazyForEach(this.videosSource, (item: VideoItem) => {
              ListItem() {
                VideoRowCard({
                  cover: item.cover,
                  title: item.title,
                  upName: item.upName,
                  extraText: formatCount(item.play) + ' 播放',
                  contentSpace: 7,
                  titleDarkColor: '#FFFFFF',
                  onTap: () => {
                    const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
                    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                  },
                })
              }
            }, (item: VideoItem) => item.bvid + String(item.aid))
          }
          ListItem() {
            LoadMoreFooter({
              loading: this.footerLoading(),
              hasMore: this.footerHasMore(),
              moreText: '继续加载',
              endText: this.selected.id === 0 && this.category === 1 ? '—— 收藏集到底啦 ——' : '—— 到底啦 ——',
              loadingText: '加载中…',
              accentLoadingText: true,
              padTop: 18,
              padBottom: 18,
              onLoadMore: () => this.loadMore(),
            })
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .cachedCount(5)
        .scrollBar(BarState.Off)
        .onReachEnd(() => this.loadMore())
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
