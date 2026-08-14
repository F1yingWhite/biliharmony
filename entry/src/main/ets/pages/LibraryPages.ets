/** 登录用户的观看历史与收藏夹。 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { BiliApi } from '../api/BiliApi';
import { FavoriteFolderItem, FavoriteVideoPageData, HistoryPageData, HistoryVideoItem, VideoItem } from '../model/Models';
import { UserStore } from '../common/UserStore';
import { formatCount, formatDuration, formatRelativeTime } from '../common/Utils';
import { LoadingView } from '../components/LoadingView';

@Component
export struct HistoryPage {
  @State items: Array<HistoryVideoItem> = [];
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State cursorMax: number = 0;
  @State cursorViewAt: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToAppear(): void {
    this.load(true);
  }

  async load(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    this.loading = true;
    const data: HistoryPageData = await BiliApi.getHistory(reset ? 0 : this.cursorMax, reset ? 0 : this.cursorViewAt);
    this.items = reset ? data.items : this.merge(this.items, data.items);
    this.cursorMax = data.max;
    this.cursorViewAt = data.viewAt;
    this.hasMore = data.hasMore;
    this.loading = false;
  }

  private merge(base: Array<HistoryVideoItem>, incoming: Array<HistoryVideoItem>): Array<HistoryVideoItem> {
    const keys: Set<string> = new Set<string>();
    const result: Array<HistoryVideoItem> = [];
    for (let i: number = 0; i < base.length; i++) {
      keys.add(base[i].video.bvid + ':' + String(base[i].viewAt));
      result.push(base[i]);
    }
    for (let i: number = 0; i < incoming.length; i++) {
      const key: string = incoming[i].video.bvid + ':' + String(incoming[i].viewAt);
      if (!keys.has(key)) result.push(incoming[i]);
    }
    return result;
  }

  @Builder
  Header(title: string) {
    Row({ space: 10 }) {
      Text('‹')
        .fontSize(28)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .width(34)
        .onClick(() => AppNavStack.pop())
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 14 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  HistoryRow(item: HistoryVideoItem) {
    Row({ space: 11 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.video.cover)
          .width(132)
          .height(74)
          .objectFit(ImageFit.Cover)
          .borderRadius(7)
        if (item.progress > 0 && item.video.duration > 0) {
          Text(formatDuration(item.progress) + ' / ' + formatDuration(item.video.duration))
            .fontSize(9)
            .fontColor('#FFFFFF')
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .backgroundColor('#99000000')
            .borderRadius(3)
            .margin(4)
        }
      }
      Column({ space: 6 }) {
        Text(item.video.title)
          .fontSize(14)
          .fontColor(this.isDark ? '#F2F2F4' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.video.upName)
          .fontSize(11)
          .fontColor('#9499A0')
          .maxLines(1)
        Text(formatRelativeTime(item.viewAt) + '看过')
          .fontSize(11)
          .fontColor('#B0B3B8')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      const param: VideoDetailParam = { bvid: item.video.bvid, aid: item.video.aid, title: item.video.title };
      AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
    })
  }

  build() {
    Column() {
      this.Header('历史记录')
      if (this.items.length === 0) {
        LoadingView({ loading: this.loading, empty: !this.loading, emptyText: '暂无观看历史', onRetry: () => this.load(true) })
      } else {
        List() {
          ForEach(this.items, (item: HistoryVideoItem) => {
            ListItem() { this.HistoryRow(item) }
          }, (item: HistoryVideoItem) => item.video.bvid + String(item.viewAt))
          ListItem() {
            Text(this.loading ? '加载中…' : (this.hasMore ? '继续加载' : '—— 到底啦 ——'))
              .fontSize(12)
              .fontColor(this.hasMore ? this.accent : '#9499A0')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(18)
              .onClick(() => this.load(false))
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .onReachEnd(() => this.load(false))
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
  @State folders: Array<FavoriteFolderItem> = [];
  @State collections: Array<FavoriteFolderItem> = [];
  @State videos: Array<VideoItem> = [];
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

  aboutToAppear(): void {
    this.initFavorites();
  }

  async initFavorites(): Promise<void> {
    await UserStore.ensureLoaded();
    this.loadFolders(true);
    this.loadCollections(true);
  }

  async loadCollections(reset: boolean): Promise<void> {
    if (this.collectionLoading || (!reset && !this.collectionHasMore)) return;
    const user = UserStore.current;
    if (user === null) return;
    this.collectionLoading = true;
    const page: number = reset ? 1 : this.collectionPage + 1;
    const data = await BiliApi.getCollectedFolders(user.mid, page);
    this.collections = reset ? data.folders : this.collections.concat(data.folders);
    this.collectionPage = page;
    this.collectionHasMore = data.hasMore;
    this.collectionLoading = false;
  }

  async loadFolders(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    const user = UserStore.current;
    if (user === null) return;
    this.loading = true;
    const page: number = reset ? 1 : this.folderPage + 1;
    const data = await BiliApi.getFavoriteFolders(user.mid, page);
    this.folders = reset ? data.folders : this.folders.concat(data.folders);
    this.folderPage = page;
    this.hasMore = data.hasMore;
    this.loading = false;
  }

  async openFolder(folder: FavoriteFolderItem): Promise<void> {
    if (this.category === 1 && folder.type === 0) folder.type = 21;
    this.selected = folder;
    this.videos = [];
    this.videoPage = 0;
    this.hasMore = true;
    await this.loadVideos(true);
  }

  async loadVideos(reset: boolean): Promise<void> {
    if (this.loading || this.selected.id === 0 || (!reset && !this.hasMore)) return;
    this.loading = true;
    const page: number = reset ? 1 : this.videoPage + 1;
    const data: FavoriteVideoPageData = this.selected.type === 21 ?
      await BiliApi.getCollectionVideos(this.selected.id, page) : await BiliApi.getFavoriteVideos(this.selected.id, page);
    this.videos = reset ? data.videos : this.videos.concat(data.videos);
    this.videoPage = page;
    this.hasMore = data.hasMore;
    this.loading = false;
  }

  goBack(): void {
    if (this.selected.id > 0) {
      this.selected = new FavoriteFolderItem();
      this.videos = [];
      this.hasMore = this.folderPage > 0;
    } else {
      AppNavStack.pop();
    }
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Text('‹')
        .fontSize(28)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .width(34)
      Text(this.selected.id > 0 ? this.selected.title : '我的收藏')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 14 })
    .onClick(() => this.goBack())
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
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

  @Builder
  VideoRow(item: VideoItem) {
    Row({ space: 11 }) {
      Image(item.cover).width(132).height(74).objectFit(ImageFit.Cover).borderRadius(7)
      Column({ space: 7 }) {
        Text(item.title).fontSize(14).fontColor(this.isDark ? '#FFFFFF' : '#18191C').maxLines(2)
        Text(item.upName).fontSize(11).fontColor('#9499A0').maxLines(1)
        Text(formatCount(item.play) + ' 播放').fontSize(11).fontColor('#B0B3B8')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
      AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
    })
  }

  build() {
    Column() {
      this.Header()
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
      if (this.loading && this.folders.length === 0 && this.videos.length === 0) {
        LoadingView({ loading: true })
      } else {
        List() {
          if (this.selected.id === 0) {
            if (this.category === 0) {
              ForEach(this.folders, (item: FavoriteFolderItem) => {
                ListItem() { this.FolderRow(item) }
              }, (item: FavoriteFolderItem) => String(item.id))
            } else {
              ForEach(this.collections, (item: FavoriteFolderItem) => {
                ListItem() { this.FolderRow(item) }
              }, (item: FavoriteFolderItem) => 'collection-' + String(item.id))
            }
          } else {
            ForEach(this.videos, (item: VideoItem) => {
              ListItem() { this.VideoRow(item) }
            }, (item: VideoItem) => item.bvid + String(item.aid))
          }
          ListItem() {
            Text(this.selected.id === 0 && this.category === 1 ?
              (this.collectionLoading ? '加载中…' : (this.collectionHasMore ? '继续加载' : '—— 收藏集到底啦 ——')) :
              (this.loading ? '加载中…' : (this.hasMore ? '继续加载' : '—— 到底啦 ——')))
              .fontSize(12).fontColor((this.category === 1 ? this.collectionHasMore : this.hasMore) ? this.accent : '#9499A0')
              .width('100%').textAlign(TextAlign.Center).padding(18)
              .onClick(() => this.selected.id > 0 ? this.loadVideos(false) :
                (this.category === 1 ? this.loadCollections(false) : this.loadFolders(false)))
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .onReachEnd(() => this.selected.id > 0 ? this.loadVideos(false) :
          (this.category === 1 ? this.loadCollections(false) : this.loadFolders(false)))
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
