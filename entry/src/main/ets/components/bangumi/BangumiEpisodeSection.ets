import { LengthMetrics } from '@kit.ArkUI';
import { BangumiEpisode, BangumiSeason } from '../../model/Models';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { formatDuration } from '../../common/Utils';
import { LayoutTokens } from '../../common/LayoutTokens';
import { BangumiEpisodeCatalog } from './BangumiEpisodeCatalog';

/** 选集展示与自适应列数；页面决定播放导航和评论切换。 */
@Component
export struct BangumiEpisodeSection {
  @Prop season: BangumiSeason = new BangumiSeason();
  @Prop currentEpId: number = 0;
  @Prop viewportWidth: number = 360;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  onPlay: (episode: BangumiEpisode) => void = () => {};

  private cellWidth(): number {
    const content: number = Math.min(this.viewportWidth, LayoutTokens.pageMaxWidth) - 28;
    const cols: number = this.viewportWidth >= 820 ? 4 : (this.viewportWidth >= 560 ? 3 : 2);
    return (content - 8 * (cols - 1)) / cols;
  }

  @Builder
  EpisodeCell(ep: BangumiEpisode) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        // 占位底色：封面加载失败/未返回时保持格子形状
        Column()
          .width('100%')
          .aspectRatio(16 / 10)
          .borderRadius(6)
          .backgroundColor(this.isDark ? '#26272B' : '#E3E5E7')
        if (ep.cover.length > 0) {
          Image(biliImageThumbnail(ep.cover, 480))
            .width('100%')
            .aspectRatio(16 / 10)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
        }
        // 底部压暗渐变 + 集数/时长
        Column()
          .width('100%')
          .aspectRatio(16 / 10)
          .borderRadius(6)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.55], ['#73000000', 1.0]],
          })
          .hitTestBehavior(HitTestMode.None)
        Column() {
          Row() {
            Text(ep.title)
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Blank()
            if (ep.duration > 0) {
              Text(formatDuration(ep.duration))
                .fontSize(10)
                .fontColor('#FFFFFF')
            }
          }
          .width('100%')
          .padding({ left: 8, right: 8, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.None)
        if (ep.badge.length > 0) {
          Text(ep.badge)
            .fontSize(9)
            .fontColor('#FFFFFF')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(this.accent)
            .margin(6)
        }
        // 当前集高亮描边
        Column()
          .width('100%')
          .aspectRatio(16 / 10)
          .borderRadius(6)
          .border({ width: ep.epId === this.currentEpId ? 1.5 : 0, color: this.accent, radius: 6 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%').aspectRatio(16 / 10).clip(true)
      Text(ep.longTitle.length > 0 ? ep.longTitle : BangumiEpisodeCatalog.fullTitle(this.season, ep))
        .fontSize(11)
        .fontColor(ep.epId === this.currentEpId ? this.accent : (this.isDark ? '#D8D8DC' : '#303236'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(this.cellWidth())
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onPlay(ep);
    })
  }

  @Builder
  EpisodeSection() {
    if (this.season.episodes.length > 0) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('选集')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          if (this.season.total > 0) {
            Text('共 ' + String(this.season.total) + ' ' + BangumiEpisodeCatalog.episodeUnit(this.season))
              .fontSize(12)
              .fontColor('#9499A0')
          }
          if (this.season.newEpDesc.length > 0) {
            Text(this.season.newEpDesc)
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(10) } }) {
          ForEach(this.season.episodes, (ep: BangumiEpisode) => {
            this.EpisodeCell(ep)
          }, (ep: BangumiEpisode) => String(ep.epId))
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    this.EpisodeSection()
  }
}