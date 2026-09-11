import { inputMethod } from '@kit.IMEKit';
import { YouTubeApi, YouTubeVideo } from '../api/YouTubeApi';
import { AppNavStack, NAV_YOUTUBE_DETAIL } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { RequestEpoch } from '../common/RequestEpoch';

@Component
export struct YouTubeView {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('windowStatusBarHeight') statusInset: number = 0;
  @State query: string = '';
  @State searched: string = '';
  @State videos: Array<YouTubeVideo> = [];
  @State loading: boolean = false;
  @State error: string = '';
  private request: RequestEpoch = new RequestEpoch();
  private scroller: Scroller = new Scroller();

  aboutToDisappear(): void { this.request.invalidate(); }

  private open(video: YouTubeVideo): void {
    AppNavStack.pushPathByName(NAV_YOUTUBE_DETAIL, video);
  }

  private async search(): Promise<void> {
    const query: string = this.query.trim();
    if (query.length === 0) return;
    try { inputMethod.getController().hideTextInput().catch(() => {}); } catch (_) {}
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_) {}
    const id: string = YouTubeApi.videoId(query);
    if (id.length > 0) {
      const video: YouTubeVideo = new YouTubeVideo();
      video.id = id;
      this.open(video);
      return;
    }
    const token: number = this.request.next();
    this.loading = true;
    this.error = '';
    this.searched = query;
    this.videos = [];
    try {
      const result: Array<YouTubeVideo> = await YouTubeApi.search(query);
      if (!this.request.isCurrent(token)) return;
      this.videos = result;
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (e) {
      if (this.request.isCurrent(token)) this.error = (e as Error).message || '搜索失败，请重试';
    } finally {
      if (this.request.isCurrent(token)) this.loading = false;
    }
  }

  @Builder
  VideoCard(video: YouTubeVideo) {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(video.thumbnail).width('100%').aspectRatio(16 / 9).objectFit(ImageFit.Cover)
          .borderRadius(14).backgroundColor(this.isDark ? '#333333' : '#E8E8E8')
        if (video.duration.length > 0) {
          Text(video.duration).fontSize(12).fontColor('#FFFFFF')
            .padding({ left: 6, right: 6, top: 3, bottom: 3 }).backgroundColor('#B3000000')
            .borderRadius(4).margin(8)
        }
      }
      Text(video.title).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Text([video.channel, video.views, video.published].filter((v: string) => v.length > 0).join(' · '))
        .fontSize(12).fontColor(this.isDark ? '#AAAAAA' : '#666666').width('100%').maxLines(2)
    }.width('100%').padding({ bottom: 22 }).onClick(() => this.open(video))
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_youtube')).width(30).height(24)
        Text('YouTube').fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
      }.width('100%')
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索 YouTube 或输入视频链接', text: this.query })
          .id('youtube-search-input').layoutWeight(1).height(44).maxLength(500)
          .enterKeyType(EnterKeyType.Search).onChange((value: string) => { this.query = value; })
          .onSubmit(() => { this.search(); })
        Button('搜索').height(40).fontSize(14).backgroundColor('#E52222').fontColor('#FFFFFF')
          .id('youtube-search-button').onClick(() => { this.search(); })
      }.width('100%')
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(36).height(36).color('#E52222')
          Text('正在搜索 YouTube…').fontColor(this.isDark ? '#AAAAAA' : '#666666')
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 16 }) {
          Text(this.error).fontSize(15).fontColor(this.isDark ? '#CCCCCC' : '#666666').textAlign(TextAlign.Center)
          Button('重试').onClick(() => { this.search(); })
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.videos.length > 0) {
        List({ scroller: this.scroller }) {
          ForEach(this.videos, (video: YouTubeVideo) => {
            ListItem() { this.VideoCard(video) }
          }, (video: YouTubeVideo) => video.id)
          ListItem() {
            Text('已展示本次搜索结果，试试更具体的关键词')
              .fontSize(12).fontColor('#888888').width('100%').textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 16 })
          }
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      } else {
        Column({ space: 12 }) {
          Text(this.searched.length > 0 ? '没有找到相关视频' : '探索 YouTube')
            .fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Text(this.searched.length > 0 ? '换个关键词再试试' : '搜索感兴趣的内容，或粘贴视频链接开始观看')
            .fontSize(14).fontColor('#888888').textAlign(TextAlign.Center)
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      }
    }.width('100%').height('100%')
      .padding({ top: this.statusInset + 16, left: 16, right: 16, bottom: Immersive.bottomInset() + 84 })
      .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
  }
}
