import { formatCount, formatDuration } from '../../common/Utils';
import { VideoItem } from '../../model/Models';

@Component
export struct PlayerEndScreen {
  @Prop landscape: boolean = false;
  @Prop accent: string = '#FB7299';
  @Prop title: string = '';
  @Prop cover: string = '';
  @Prop upName: string = '';
  @Prop upFace: string = '';
  @Prop playText: string = '';
  @Prop duration: number = 0;
  @Prop recommendations: Array<VideoItem> = [];
  @Prop following: boolean = false;
  @Prop liked: boolean = false;
  @Prop disliked: boolean = false;
  @Prop coined: boolean = false;
  @Prop favorited: boolean = false;
  onClose: () => void = () => {};
  onBack: () => void = () => {};
  onReplay: () => void = () => {};
  onPlayNow: () => void = () => {};
  onFollow: () => void = () => {};
  onLike: () => void = () => {};
  onDislike: () => void = () => {};
  onCoin: () => void = () => {};
  onFavorite: () => void = () => {};
  onShare: () => void = () => {};
  onOpenRecommendation: (item: VideoItem) => void = (_item: VideoItem) => {};

  @Builder
  private ActionCell(icon: Resource, label: string, tint: string, action: () => void) {
    Column({ space: 5 }) {
      Image(icon).width(24).height(24).renderMode(ImageRenderMode.Template).fillColor(tint)
      Text(label).fontSize(12).fontColor('#DDE0E4')
    }
    .alignItems(HorizontalAlign.Center)
    .padding(4)
    .onClick(action)
  }

  @Builder
  private RecommendationCard(item: VideoItem) {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(item.cover).width('100%').height('100%').objectFit(ImageFit.Cover)
        Column().width('100%').height(20)
          .linearGradient({ angle: 90, colors: [['#00000000', 0.0], ['#CC000000', 1.0]] })
        Row({ space: 8 }) {
          Row({ space: 3 }) {
            Image($r('app.media.ic_play')).width(9).height(9)
              .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF')
            Text(item.playText.length > 0 ? item.playText : formatCount(item.play))
              .fontSize(10).fontColor('#FFFFFF')
          }
          if (item.reply > 0) {
            Text(formatCount(item.reply)).fontSize(10).fontColor('#F2FFFFFF')
          }
          Blank()
          if (item.duration > 0) {
            Text(formatDuration(item.duration)).fontSize(10).fontColor('#FFFFFF')
              .backgroundColor('#99000000').borderRadius(3).padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
        }
        .width('100%').padding({ left: 6, right: 6, bottom: 5 })
      }
      .width(190).height(84).clip(true).borderRadius(6)
      Text(item.title.length > 0 ? item.title : '为你推荐')
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        .maxLines(2).lineHeight(19).textOverflow({ overflow: TextOverflow.Ellipsis }).width(190)
      if (item.upName.length > 0) {
        Text(item.upName).fontSize(11).fontColor('#C0C4CC')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width(190)
      }
    }
    .width(190).alignItems(HorizontalAlign.Start)
    .onClick(() => this.onOpenRecommendation(item))
  }

  @Builder
  private PortraitContent() {
    Column() {
      Text('推荐视频').fontSize(13).fontColor('#8E9399').width('100%').margin({ bottom: 8 })
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.cover).width(96).height(54).objectFit(ImageFit.Cover)
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_play')).width(22).height(22)
              .renderMode(ImageRenderMode.Template).fillColor('#E6FFFFFF')
          }
          .width('100%').height('100%')
          if (this.duration > 0) {
            Text(formatDuration(this.duration)).fontSize(10).fontColor('#FFFFFF')
              .backgroundColor('#88000000').padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(3).margin({ right: 5, bottom: 5 })
          }
        }
        .width(96).height(54).clip(true).borderRadius(6).onClick(this.onPlayNow)
        Column({ space: 4 }) {
          Text(this.title.length > 0 ? this.title : '为你推荐')
            .fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(this.title.length > 0 ? '#FFFFFF' : this.accent)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).lineHeight(16).width('100%')
          if (this.upName.length > 0) {
            Text(this.upName).fontSize(11).fontColor('#C0C4CC').maxLines(1)
          }
          if (this.playText.length > 0) {
            Text(this.playText).fontSize(10).fontColor('#C0C4CC')
          }
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(this.onPlayNow)
        Text('立即播放').fontSize(12).fontColor('#FFFFFF')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(13).backgroundColor('#33FFFFFF').onClick(this.onPlayNow)
      }
      .width('100%').alignItems(VerticalAlign.Center)
      Row({ space: 28 }) {
        Row({ space: 6 }) {
          Image($r('app.media.ic_video_replay')).width(18).height(18)
            .renderMode(ImageRenderMode.Template).fillColor('#E6E6E6')
          Text('重播').fontSize(14).fontColor('#E6E6E6')
        }.onClick(this.onReplay)
        Row({ space: 6 }) {
          Image($r('app.media.ic_share')).width(18).height(18)
            .renderMode(ImageRenderMode.Template).fillColor('#E6E6E6')
          Text('分享').fontSize(14).fontColor('#E6E6E6')
        }.onClick(this.onShare)
      }
      .width('100%').margin({ top: 16 })
    }
    .width('100%').height('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor('#E6000000').onClick(this.onClose)
  }

  @Builder
  private LandscapeContent() {
    Column() {
      Blank().onClick(this.onClose)
      Row() {
        Image($r('app.media.ic_back')).width(24).height(24)
          .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF').onClick(this.onBack)
        if (this.upFace.length > 0) {
          Image(this.upFace).width(80).height(80).borderRadius(40)
        }
        Column({ space: 8 }) {
          Text(this.upName.length > 0 ? this.upName : 'UP 主')
            .fontSize(19).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').maxLines(1)
          Text(this.following ? '已关注' : '+ 关注').fontSize(12).fontColor('#FFFFFF')
            .backgroundColor(this.following ? '#2EFFFFFF' : this.accent)
            .borderRadius(14).padding({ left: 12, right: 12, top: 5, bottom: 5 }).onClick(this.onFollow)
        }.margin({ left: 18 }).alignItems(HorizontalAlign.Start)
        Blank().onClick(this.onClose)
        Row({ space: 30 }) {
          this.ActionCell($r('app.media.ic_refresh'), '重播', '#DDE0E4', this.onReplay)
          this.ActionCell(this.liked ? $r('app.media.ic_like_fill') : $r('app.media.ic_like'), '点赞',
            this.liked ? this.accent : '#DDE0E4', this.onLike)
          this.ActionCell($r('app.media.bilix_icon_dislike'), '不喜欢',
            this.disliked ? this.accent : '#DDE0E4', this.onDislike)
          this.ActionCell($r('app.media.ic_coin'), '投币', this.coined ? this.accent : '#DDE0E4', this.onCoin)
          this.ActionCell(this.favorited ? $r('app.media.ic_favorite_fill') : $r('app.media.ic_favorite'), '收藏',
            this.favorited ? this.accent : '#DDE0E4', this.onFavorite)
          this.ActionCell($r('app.media.ic_share'), '分享', '#DDE0E4', this.onShare)
        }
      }
      .width('100%').alignItems(VerticalAlign.Center).padding({ left: 44, right: 96 })
      Text('相关推荐').fontSize(15).fontColor('#9499A0').width('100%')
        .padding({ left: 44, right: 96 }).margin({ top: 14, bottom: 10 })
      List({ space: 24 }) {
        ForEach(this.recommendations, (item: VideoItem) => {
          ListItem() { this.RecommendationCard(item) }
        }, (item: VideoItem) => item.bvid.length > 0 ? item.bvid : 'aid_' + String(item.aid))
      }
      .listDirection(Axis.Horizontal).scrollBar(BarState.Off).height(160).width('100%')
      .padding({ left: 44, right: 32 })
      Blank().onClick(this.onClose)
    }
    .width('100%').height('100%').backgroundColor('#FF000000')
  }

  build() {
    if (this.landscape) this.LandscapeContent()
    else this.PortraitContent()
  }
}
