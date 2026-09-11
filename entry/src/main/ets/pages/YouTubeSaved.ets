import { YouTubeVideo } from '../api/YouTubeApi';
import { YouTubeLocalVideo } from '../common/YouTubeLocalStore';
import { YouTubeHistoryStore } from '../common/YouTubeHistoryStore';
import { YouTubeWatchLaterStore } from '../common/YouTubeWatchLaterStore';
import { PageHeader } from '../components/PageHeader';
import { AppNavStack, NAV_YOUTUBE_DETAIL } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';

/**
 * 本地列表页：稍后观看（mode=later）与观看历史（mode=history）共用同一套行与操作。
 *
 * 两个列表都不需要账号，只保存视频 ID 与公开元数据；播放交给官方客户端/官方播放器，
 * 不涉及取流。与哔哩哔哩的稍后观看/历史（服务端数据）互不相干。
 */
@Component
export struct YouTubeSavedPage {
  /** later | history；非法值按稍后观看处理。 */
  mode: string = 'later';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('windowStatusBarHeight') statusInset: number = 0;
  @State items: Array<YouTubeLocalVideo> = [];
  @State loading: boolean = true;
  /** 封面 → 本地文件：ArkUI Image() 不读应用代理，统一走应用自己的缓存管线。 */
  @State thumbLocal: Map<string, string> = new Map<string, string>();

  private isHistory(): boolean {
    return this.mode === 'history';
  }

  private title(): string {
    return this.isHistory() ? '观看历史' : '稍后观看';
  }

  private emptyText(): string {
    return this.isHistory()
      ? '还没有观看记录\n打开任意视频详情就会记录在这里，只存在本机。'
      : '还没有保存的视频\n在视频详情页点「稍后观看」就会出现在这里；\n列表只存在本机，不需要登录。';
  }

  private loaded(list: Array<YouTubeLocalVideo>): void {
    this.items = list;
    this.loading = false;
    this.primeThumbs(list);
  }

  aboutToAppear(): void {
    if (this.isHistory()) {
      YouTubeHistoryStore.ensureLoaded().then((list: Array<YouTubeLocalVideo>) => {
        this.loaded(list);
      }).catch(() => {
        this.loading = false;
      });
      return;
    }
    YouTubeWatchLaterStore.ensureLoaded().then((list: Array<YouTubeLocalVideo>) => {
      this.loaded(list);
    }).catch(() => {
      this.loading = false;
    });
  }

  private localImage(url: string): string {
    const local: string | undefined = this.thumbLocal.get(url);
    return local !== undefined && local.length > 0 ? local : url;
  }

  private primeThumbs(list: Array<YouTubeLocalVideo>): void {
    const hits: Map<string, string> = new Map<string, string>();
    const pending: Array<string> = [];
    for (const item of list) {
      const url: string = item.thumbnail;
      if (url.length === 0 || this.thumbLocal.has(url) || hits.has(url)) continue;
      const cached: string = RemoteAssetCache.cachedThumbnail(url);
      if (cached !== url) hits.set(url, cached);
      else pending.push(url);
    }
    if (hits.size > 0) {
      const merged: Map<string, string> = new Map<string, string>(this.thumbLocal);
      hits.forEach((value: string, key: string) => merged.set(key, value));
      this.thumbLocal = merged;
    }
    for (const url of pending) {
      RemoteAssetCache.ensureThumbnail(url).then((local: string) => {
        if (local === url || this.thumbLocal.get(url) === local) return;
        const next: Map<string, string> = new Map<string, string>(this.thumbLocal);
        next.set(url, local);
        this.thumbLocal = next;
      }).catch(() => {
      });
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 组件销毁后调用会抛异常，忽略。
    }
  }

  private open(item: YouTubeLocalVideo): void {
    const video: YouTubeVideo = new YouTubeVideo();
    video.id = item.id;
    video.title = item.title;
    video.channel = item.channel;
    video.thumbnail = item.thumbnail;
    video.duration = item.duration;
    video.views = item.views;
    video.published = item.published;
    AppNavStack.pushPathByName(NAV_YOUTUBE_DETAIL, video);
  }

  private removeList(): Array<YouTubeLocalVideo> {
    return this.isHistory() ? YouTubeHistoryStore.list() : YouTubeWatchLaterStore.list();
  }

  private removeItem(item: YouTubeLocalVideo): void {
    this.items = this.isHistory()
      ? YouTubeHistoryStore.remove(item.id)
      : YouTubeWatchLaterStore.remove(item.id);
    this.toast(this.isHistory() ? '已从观看历史移除' : '已从稍后观看移除');
  }

  private clearAll(): void {
    if (this.isHistory()) YouTubeHistoryStore.clear();
    else YouTubeWatchLaterStore.clear();
    this.items = [];
    this.toast(this.isHistory() ? '已清空观看历史' : '已清空稍后观看');
  }

  @Builder
  SavedRow(item: YouTubeLocalVideo) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.localImage(item.thumbnail))
          .width(120).height(68)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
          .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
          .draggable(false).syncLoad(false)
        if (item.duration.length > 0) {
          Text(item.duration)
            .fontSize(10).fontColor('#FFFFFF')
            .backgroundColor('#88000000')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(3).maxLines(1)
            .margin({ right: 4, bottom: 4 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(120).height(68).clip(true)
      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(13).fontWeight(FontWeight.Medium).lineHeight(17)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Row({ space: 6 }) {
          Text(item.channel)
            .fontSize(11).fontColor('#9499A0').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (item.views.length > 0) {
            Text(item.views).fontSize(11).fontColor('#9499A0').maxLines(1)
          }
        }
        .width('100%').alignItems(VerticalAlign.Center)
      }
      .height(68).alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Top)
    .onClick(() => this.open(item))
    .gesture(LongPressGesture({ repeat: false }).onAction(() => this.removeItem(item)))
  }

  build() {
    Column() {
      PageHeader({ title: this.title(), onBack: () => AppNavStack.pop() })
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(32).height(32).color(AppTheme.DANGER)
          Text('正在读取本地列表…').fontSize(13).fontColor('#9499A0')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
          Text(this.isHistory() ? '还没有观看记录' : '还没有保存的视频')
            .fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Text(this.emptyText()).fontSize(13).textAlign(TextAlign.Center).fontColor('#9499A0')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Text('共 ' + String(this.items.length) + ' 个视频 · 长按可移除')
            .fontSize(12).fontColor('#9499A0')
          Blank()
          Text('清空')
            .fontSize(12).fontColor(AppTheme.DANGER)
            .onClick(() => this.clearAll())
        }
        .width('100%').height(40).padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)

        List({ space: 0 }) {
          ForEach(this.items, (item: YouTubeLocalVideo) => {
            ListItem() {
              this.SavedRow(item)
            }
          }, (item: YouTubeLocalVideo) => item.id)
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .contentEndOffset(Immersive.bottomInset() + 24)
      }
    }
    .width('100%').height('100%')
    .padding({ top: this.statusInset })
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
