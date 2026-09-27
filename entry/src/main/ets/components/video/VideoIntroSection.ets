import { BasicDataSource } from '../../common/BasicDataSource';
import { colorWithAlpha, formatCount, formatDate } from '../../common/Utils';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { UgcSeasonEpisode, VideoDetail, VideoItem, VideoPage } from '../../model/Models';
import { VideoTagInfo } from '../../api/BiliApi';
import { pasteboard } from '@kit.BasicServicesKit';
import { RelatedVideoRow } from './VideoRelatedRow';
import { VideoActionItem } from './VideoActionItem';

@Component
export struct VideoIntroSection {
  @Prop detail: VideoDetail = new VideoDetail();
  @Prop accent: string = '#FB7299';
  @Prop isDark: boolean = false;
  @Prop upStats: string = '';
  @Prop followLoading: boolean = false;
  @Prop following: boolean = false;
  @Prop playerOnlineTotal: string = '';
  @Prop likeCount: number = 0;
  @Prop coinCount: number = 0;
  @Prop favoriteCount: number = 0;
  @Prop liked: boolean = false;
  @Prop disliked: boolean = false;
  @Prop coinCountByMe: number = 0;
  @Prop favorited: boolean = false;
  @Prop actionBusy: boolean = false;
  @Prop descExpanded: boolean = false;
  @Prop descNeedsExpand: boolean = false;
  @Prop currentCid: number = 0;
  @Prop pageSwitchingCid: number = 0;
  @Prop ugcPanelOpen: boolean = false;
  @Prop ugcCount: number = 0;
  /** 全视频空降标签（如「商业推广」）：显示在标题前；空串不显示。 */
  @Prop tags: Array<VideoTagInfo> = [];
  onTagTap: (tag: VideoTagInfo) => void = () => {};
  @Prop sponsorTag: string = '';
  @Prop sponsorTagColor: string = '#008A5C';
  /** 相关推荐行数：relatedSource 是普通属性（父组件持有），空态/尾footer 依赖此响应式计数。 */
  @Prop relatedCount: number = 0;
  @Prop relatedLoading: boolean = false;
  @Prop relatedLoadError: string = '';
  scroller: Scroller = new Scroller();
  ugcSource: BasicDataSource<UgcSeasonEpisode> = new BasicDataSource<UgcSeasonEpisode>();
  /** 相关推荐懒加载数据源：无限追加的推荐行必须虚拟化，Scroll+ForEach 全量常驻会随页数线性吃满内存。 */
  relatedSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  onOpenUp: () => void = () => {};
  onFollow: () => void = () => {};
  onLike: () => void = () => {};
  onTriple: () => void = () => {};
  onDislike: () => void = () => {};
  onCoin: () => void = () => {};
  onFavorite: () => void = () => {};
  onFavoritePick: () => void = () => {};
  onShare: () => void = () => {};
  onDescAreaChange: (width: Length) => void = (_width: Length) => {};
  onToggleDescription: () => void = () => {};
  onSwitchPage: (page: VideoPage, index: number) => void = (_page: VideoPage, _index: number) => {};
  onToggleUgc: () => void = () => {};
  onOpenUgc: (episode: UgcSeasonEpisode) => void = (_episode: UgcSeasonEpisode) => {};
  onOpenRelated: (item: VideoItem) => void = (_item: VideoItem) => {};
  onReportRelated: (item: VideoItem) => void = (_item: VideoItem) => {};
  onHideRelated: (item: VideoItem) => void = (_item: VideoItem) => {};
  onLoadMoreRelated: () => void = () => {};
  onScrollFrame: (offset: number, scroller: Scroller, state: ScrollState) => number =
    (offset: number, _scroller: Scroller, _state: ScrollState): number => offset;

  @Builder
  private OwnerHeader() {
    Row({ space: 10 }) {
      Row({ space: 10 }) {
        Image(this.detail.upFace).width(42).height(42).borderRadius(21).objectFit(ImageFit.Cover)
        Column({ space: 3 }) {
          Text(this.detail.upName).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.accent)
          Text(this.upStats).fontSize(11).fontColor('#9499A0').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.layoutWeight(1).onClick(this.onOpenUp)
      Text(this.followLoading ? '处理中…' : (this.following ? '已关注' : '+ 关注'))
        .fontSize(13).fontColor(this.following ? (this.isDark ? '#D0D0D4' : '#61666D') : '#FFFFFF')
        .backgroundColor(this.following ? (this.isDark ? '#333438' : '#EEF0F2') : this.accent)
        .padding({ left: 14, right: 14, top: 6, bottom: 6 }).borderRadius(15)
        .enabled(!this.followLoading).onClick(this.onFollow)
    }.width('100%')
  }

  @Builder
  private Metadata() {
    Row() {
      Image($r('app.media.ic_play')).width(13).height(13)
        .renderMode(ImageRenderMode.Template).fillColor('#9499A0')
      Text(formatCount(this.detail.view)).fontSize(12).fontColor('#9499A0').margin({ left: 4 })
      Image($r('app.media.ic_comment')).width(13).height(13)
        .renderMode(ImageRenderMode.Template).fillColor('#9499A0').margin({ left: 12 })
      Text(formatCount(this.detail.reply)).fontSize(12).fontColor('#9499A0').margin({ left: 4 })
      Image($r('app.media.ic_history')).width(13).height(13)
        .renderMode(ImageRenderMode.Template).fillColor('#9499A0').margin({ left: 12 })
      Text(formatDate(this.detail.pubdate)).fontSize(12).fontColor('#9499A0').margin({ left: 4 })
      if (this.playerOnlineTotal.length > 0) {
        Text(this.playerOnlineTotal + '人正在看').fontSize(12).fontColor('#9499A0').margin({ left: 12 })
      }
      if (this.detail.tname.length > 0) {
        Text(this.detail.tname).fontSize(12).fontColor('#9499A0').margin({ left: 12, right: 10 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  @Builder
  private Actions() {
    Row() {
      VideoActionItem({ icon: $r('app.media.ic_like'), label: '点赞', value: formatCount(this.likeCount),
        activeIcon: $r('app.media.ic_like_fill'), useActiveIcon: true, active: this.liked, busy: this.actionBusy, onTap: this.onLike, onLongPress: this.onTriple })
      VideoActionItem({ icon: $r('app.media.ic_dislike'), label: '不喜欢', value: '不喜欢',
        active: this.disliked, busy: this.actionBusy, onTap: this.onDislike })
      VideoActionItem({ icon: $r('app.media.ic_coin'), label: '投币', value: formatCount(this.coinCount),
        active: this.coinCountByMe > 0, busy: this.actionBusy, onTap: this.onCoin })
      VideoActionItem({ icon: $r('app.media.ic_favorite'), label: '收藏', value: formatCount(this.favoriteCount),
        activeIcon: $r('app.media.ic_favorite_fill'), useActiveIcon: true, active: this.favorited, busy: this.actionBusy, onTap: this.onFavorite, onLongPress: this.onFavoritePick })
      VideoActionItem({ icon: $r('app.media.ic_share'), label: '分享', value: formatCount(this.detail.share),
        active: false, busy: this.actionBusy, onTap: this.onShare })
    }.width('100%')
  }

  /** 官方版式：标题右侧 ∨/∧ 展开箭头；展开后显示 BV 号、简介与 TAG。 */
  @Builder
  private TitleBlock() {
    Row({ space: 6 }) {
      if (this.sponsorTag.length > 0) {
        Text(this.sponsorTag)
          .fontSize(11).fontColor('#FFFFFF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor(this.sponsorTagColor)
          .margin({ top: 3 })
          .flexShrink(0)
      }
      Text(this.detail.title).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C').layoutWeight(1).lineHeight(23)
        .maxLines(this.descExpanded ? 10000 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Image($r('app.media.ic_arrow_right'))
        .width(14).height(14)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.isDark ? '#8A8F99' : '#9499A0')
        .rotate({ angle: this.descExpanded ? -90 : 90 })
        .flexShrink(0)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .onClick(this.onToggleDescription)
  }

  /** 展开区：BV 号 + 简介全文 + TAG 胶囊（对齐官方「收起状态不展示简介」）。 */
  @Builder
  private ExpandedDescription() {
    Column({ space: 10 }) {
      if (this.detail.bvid.length > 0) {
        Text(this.detail.bvid).fontSize(12).fontColor(this.isDark ? '#8A8F99' : '#9499A0')
          .width('100%')
          .onClick(() => {
            const data: pasteboard.PasteData =
              pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.detail.bvid);
            pasteboard.getSystemPasteboard().setData(data).then(() => {
              this.getUIContext().getPromptAction().showToast({ message: 'BV 号已复制' });
            }).catch(() => {
            });
          })
      }
      Text(this.detail.desc.length > 0 ? this.detail.desc : 'UP主没有填写简介')
        .fontSize(13).fontColor(this.isDark ? '#B0B0B0' : '#5A5F66').width('100%').lineHeight(21)
      if (this.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tags, (tag: VideoTagInfo, index: number) => {
            Text(tag.name)
              .fontSize(12)
              .fontColor(this.isDark ? '#C9CDD4' : '#61666D')
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(15)
              .backgroundColor(this.isDark ? '#2A2C31' : '#F1F2F3')
              .margin({ right: 8, bottom: 8 })
              .onClick(() => this.onTagTap(tag))
          }, (tag: VideoTagInfo, index: number) => String(tag.tagId) + '-' + String(index))
        }
        .width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 分P / 合集选集（官方常驻，不随简介展开态变化）。 */
  @Builder
  private EpisodesSections() {
    Column({ space: 8 }) {
      if (this.detail.pages.length > 1) {
        Column() {
          ForEach(this.detail.pages, (page: VideoPage, index: number) => {
            Row() {
              Text('P' + page.page + ' ' + page.part).fontSize(13)
                .fontColor(this.isDark ? '#D0D0D0' : '#222222').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Text(page.cid === this.pageSwitchingCid ? '切换中…' : (page.cid === this.currentCid ? '播放中' : ''))
                .fontSize(11).fontColor(this.accent)
            }
            .width('100%').padding({ top: 8, bottom: 8 }).borderRadius(6)
            .backgroundColor(page.cid === this.currentCid ? colorWithAlpha(this.accent, '14') : '#00000000')
            .onClick(() => this.onSwitchPage(page, index))
          }, (page: VideoPage) => String(page.cid))
        }.width('100%').padding({ left: 10, right: 10 }).borderRadius(8)
          .backgroundColor(this.isDark ? '#2A2C31' : '#F6F7F8')
      }
      if (this.detail.ugcSeason !== null && this.detail.ugcSeason.sections.length > 0) {
        Column() {
          Row() {
            Text('合集 · ' + this.detail.ugcSeason.title).fontSize(13)
              .fontColor(this.isDark ? '#D0D0D0' : '#222222').maxLines(1).layoutWeight(1)
            Text(this.ugcPanelOpen ? '收起' : '展开').fontSize(11).fontColor(this.accent)
          }.width('100%').padding({ top: 8, bottom: 8 }).onClick(this.onToggleUgc)
          if (this.ugcPanelOpen && this.ugcCount > 0) {
            List({ space: 4 }) {
              LazyForEach(this.ugcSource, (episode: UgcSeasonEpisode) => {
                ListItem() {
                  Row({ space: 8 }) {
                    if (episode.cover.length > 0) {
                      Image(biliImageThumbnail(episode.cover, 240)).width(72).height(42).objectFit(ImageFit.Cover)
                        .borderRadius(5).alt($r('app.media.placeholder_cover'))
                    }
                    Text(episode.sectionTitle.length > 0 ? episode.sectionTitle + ' · ' + episode.title : episode.title)
                      .fontSize(12).fontColor(this.isDark ? '#D0D0D0' : '#222222').maxLines(2).layoutWeight(1)
                    Text(episode.cid === this.currentCid ? '播放中' : '').fontSize(10).fontColor(this.accent)
                  }.width('100%').padding({ top: 6, bottom: 6 }).onClick(() => this.onOpenUgc(episode))
                }
              }, (episode: UgcSeasonEpisode) => String(episode.id) + '_' + episode.bvid + '_' + String(episode.cid))
            }.width('100%').height(240).scrollBar(BarState.Off)
          }
        }.width('100%').padding({ left: 10, right: 10 }).borderRadius(8)
          .backgroundColor(this.isDark ? '#2A2C31' : '#F6F7F8')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private RelatedHeader() {
    Column({ space: 4 }) {
      Text('相关推荐').fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C').width('100%').padding({ top: 6, bottom: 4 })
      if (this.relatedCount === 0) {
        Text(this.relatedLoading ? '相关推荐加载中…' : this.relatedLoadError)
          .fontSize(12).fontColor(this.relatedLoadError.length > 0 ? this.accent : '#9499A0')
          .width('100%').padding({ top: 12, bottom: 12 })
          .onClick(() => { if (!this.relatedLoading) this.onLoadMoreRelated(); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    List({ space: 4, scroller: this.scroller }) {
      ListItem() {
        Column({ space: 12 }) {
          this.OwnerHeader()
          this.TitleBlock()
          this.Metadata()
          if (this.descExpanded) {
            this.ExpandedDescription()
          }
          this.Actions()
          this.EpisodesSections()
        }.width('100%')
      }.margin({ top: 14, bottom: 8 })

      ListItem() {
        this.RelatedHeader()
      }

      LazyForEach(this.relatedSource, (item: VideoItem) => {
        ListItem() {
          RelatedVideoRow({ item: item, onOpen: this.onOpenRelated,
            onReport: this.onReportRelated, onHide: this.onHideRelated })
        }
      }, (item: VideoItem) => item.bvid + String(item.aid))

      if (this.relatedCount > 0 && (this.relatedLoading || this.relatedLoadError.length > 0)) {
        ListItem() {
          Text(this.relatedLoading ? '正在刷新更多推荐…' : this.relatedLoadError)
            .fontSize(12).fontColor(this.relatedLoadError.length > 0 ? this.accent : '#9499A0')
            .width('100%').textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
            .onClick(this.onLoadMoreRelated)
        }
      }

      // 尾部留白对齐原 Scroll 内边距；空态时也保证"点击刷新"文案不贴底。
      ListItem() {
        Column().width('100%').height(10)
      }
    }
    .width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
    .cachedCount(4)
    .padding({ left: 14, right: 14 })
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      return { offsetRemain: this.onScrollFrame(offset, this.scroller, state) };
    })
    .onReachEnd(this.onLoadMoreRelated)
  }
}
