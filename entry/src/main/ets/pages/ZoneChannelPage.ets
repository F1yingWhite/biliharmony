/**
 * 分区频道页：展示 B 站主要视频分区（关卡/动画/…），点击进该分区排行列表。
 * 数据复用 getRankVideos(rid)——rid 即分区 id，一个无端到新端点的轻量频道浏览。
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { VIDEO_ZONE_OPTIONS, SearchNumOption, VideoItem } from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { LoadingView } from '../components/LoadingView';
import { PageHeader } from '../components/PageHeader';
import { VideoRowCard } from '../components/VideoRowCard';
import { BasicDataSource } from '../common/BasicDataSource';
import { LayoutTokens } from '../common/LayoutTokens';
import { colorWithAlpha, formatCount } from '../common/Utils';
import { SearchApi } from '../api/SearchApi';

@Component
export struct ZoneChannelPage {
  @State zoneId: number = -1;     // -1 = 频道网格；>= 0 = 被选中的分区
  @State zoneLabel: string = '';
  @State loading: boolean = false;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private videoSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();

  /** 去掉"不限",只留真实分区入口 */
  private zones(): Array<SearchNumOption> {
    const out: Array<SearchNumOption> = [];
    for (let i: number = 0; i < VIDEO_ZONE_OPTIONS.length; i++) {
      if (VIDEO_ZONE_OPTIONS[i].value !== 0) out.push(VIDEO_ZONE_OPTIONS[i]);
    }
    return out;
  }

  @Builder
  ZoneGrid() {
    Column({ space: 2 }) {
      ForEach(this.zones(), (z: SearchNumOption) => {
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle()
              .width(38)
              .height(38)
              .fill(colorWithAlpha(this.accent, '22'))
            Text(z.label.charAt(0))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.accent)
          }
          .width(48)
          Text(z.label)
            .fontSize(15)
            .fontColor(this.isDark ? '#F0F0F2' : '#18191C')
          Blank()
          Text('›')
            .fontSize(18)
            .fontColor('#9499A0')
        }
        .width('100%')
        .height(54)
        .padding({ left: 14, right: 14 })
        .borderRadius(10)
        .backgroundColor(this.isDark ? '#26272B' : '#FFFFFF')
        .onClick(() => {
          this.zoneId = z.value;
          this.zoneLabel = z.label;
          this.load(true).catch(() => {
          });
        })
        .animation({ duration: 120 })
      }, (z: SearchNumOption) => String(z.value))
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
    .alignSelf(ItemAlign.Center)
  }

  async load(reset: boolean): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const list: Array<VideoItem> = await SearchApi.getRankVideos(this.zoneId);
      if (list.length === 0 && reset) {
        this.errorText = '该分区暂无可展示视频，请稍后再试';
      }
      this.videoSource.reset(list);
    } catch (e) {
      if (this.videoSource.isEmpty()) {
        this.errorText = '加载失败，请检查网络后重试';
      }
    } finally {
      this.loading = false;
    }
  }

  @Builder
  ZoneVideos() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .onClick(() => {
            this.zoneId = -1;
            this.zoneLabel = '';
            this.videoSource.clear();
          })
        Text(this.zoneLabel + ' 排行')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 12 })

      if (this.videoSource.isEmpty() && this.loading) {
        LoadingView({ loading: true })
          .margin({ top: 60 })
      } else if (this.videoSource.isEmpty() && this.errorText.length > 0) {
        LoadingView({ loading: false, empty: true, emptyText: this.errorText,
          onRetry: () => {
            this.load(true).catch(() => {
            });
          } })
          .margin({ top: 60 })
      } else {
        List() {
          LazyForEach(this.videoSource, (item: VideoItem) => {
            ListItem() {
              VideoRowCard({
                cover: item.cover,
                title: item.title,
                upName: item.upName,
                extraText: formatCount(item.play) + '播放',
                onTap: () => {
                  const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
                  AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                },
              })
            }
          }, (item: VideoItem) => item.bvid)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      PageHeader({ title: this.zoneId < 0 ? '分区频道' : this.zoneLabel })
      if (this.zoneId < 0) {
        this.ZoneGrid()
      } else {
        this.ZoneVideos()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#141519' : '#F6F7F9')
  }
}