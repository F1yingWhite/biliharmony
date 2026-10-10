import { KeywordSpans } from '../KeywordSpans';
import { AppTheme } from '../../common/AppTheme';
import { VideoItem, UserSearchItem } from '../../model/Models';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { formatCount, formatDuration, formatRelativeTime } from '../../common/Utils';
import { AppNavStack, UserSpaceParam, LiveRoomParam, VideoDetailParam,
  NAV_USER_SPACE, NAV_LIVE_ROOM, NAV_VIDEO_DETAIL } from '../../common/AppRouter';

@Component
export struct SearchUserCard {
  @Prop item: UserSearchItem = new UserSearchItem();
  @Prop keyword: string = '';
  @Prop expanded: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  private openUserSpace(item: UserSearchItem): void {
    const param: UserSpaceParam = { mid: item.mid };
    AppNavStack.pushPathByName(NAV_USER_SPACE, param);
  }

  private openUserLive(item: UserSearchItem): void {
    if (item.liveStatus !== 1 || item.liveRoomId <= 0) {
      this.openUserSpace(item);
      return;
    }
    const param: LiveRoomParam = {
      roomId: item.liveRoomId, uid: item.mid, title: '', uname: item.uname, face: item.face, cover: '',
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  private openVideo(item: VideoItem): void {
    const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  @Builder
  CompactCard(item: UserSearchItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(item.face.length > 0 ? item.face : $r('app.media.placeholder_avatar_noface'))
          .width(52)
          .height(52)
          .borderRadius(26)
          .objectFit(ImageFit.Cover)
        if (item.liveStatus === 1 && item.liveRoomId > 0) {
          Text('直播')
            .width(38).height(17).textAlign(TextAlign.Center)
            .fontSize(10).fontWeight(FontWeight.Medium).fontColor(AppTheme.onAccent(this.accent))
            .backgroundColor(this.accent).borderRadius(9)
        }
      }
      .width(56).height(58)
      .onClick(() => this.openUserLive(item))
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text() { KeywordSpans({ text: item.uname, keyword: this.keyword, isDark: this.isDark }) }
            .fontSize(14)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 150 })
          Text('Lv' + item.level)
            .fontSize(10)
            .fontColor(this.accent)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor(this.isDark ? '#33FB7299' : '#1AFB7299')
            .borderRadius(3)
          if (item.verifyDesc.length > 0) {
            Text(item.verifyDesc)
              .fontSize(10)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        Text('粉丝 ' + formatCount(item.fans) + ' · 视频 ' + formatCount(item.videos))
          .fontSize(11)
          .fontColor('#9499A0')
        if (item.usign.length > 0) {
          Text() { KeywordSpans({ text: item.usign, keyword: this.keyword, isDark: this.isDark }) }
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => this.openUserSpace(item))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  }

  @Builder
  AllUserRecentVideo(item: VideoItem) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(biliImageThumbnail(item.cover, 640))
          .width('100%')
          .aspectRatio(1.6)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.placeholder_cover'))
        Row({ space: 4 }) {
          if (item.play > 0) {
            Image($r('app.media.ic_play'))
              .width(11).height(11)
              .renderMode(ImageRenderMode.Template)
              .fillColor('#FFFFFF')
            Text(formatCount(item.play))
              .fontSize(10).fontColor('#FFFFFF').maxLines(1)
          }
          Blank()
          if (item.duration > 0) {
            Text(formatDuration(item.duration))
              .fontSize(10).fontColor('#FFFFFF').maxLines(1)
          }
        }
        .width('100%')
        .height(28)
        .padding({ left: 6, right: 6 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#66000000')
      }
      .width('100%')
      .aspectRatio(1.6)
      .clip(true)
      .borderRadius(5)
      Text() { KeywordSpans({ text: item.title, keyword: this.keyword, isDark: this.isDark }) }
        .width('100%')
        .fontSize(12)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(formatRelativeTime(item.pubdate))
        .width('100%')
        .fontSize(10)
        .fontColor('#9499A0')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('31.5%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.openVideo(item))
  }

  @Builder
  AllUserCard(user: UserSearchItem) {
    Column() {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.Bottom }) {
          Image(user.face.length > 0 ? user.face : $r('app.media.placeholder_avatar_noface'))
            .width(58)
            .height(58)
            .borderRadius(29)
            .objectFit(ImageFit.Cover)
          if (user.liveStatus === 1 && user.liveRoomId > 0) {
            Text('直播')
              .width(40).height(18).textAlign(TextAlign.Center)
              .fontSize(10).fontWeight(FontWeight.Medium).fontColor(AppTheme.onAccent(this.accent))
              .backgroundColor(this.accent).borderRadius(9)
          }
        }
        .width(62).height(62)
        .onClick(() => this.openUserLive(user))
        Column({ space: 4 }) {
          Row({ space: 5 }) {
            Text() { KeywordSpans({ text: user.uname, keyword: this.keyword, isDark: this.isDark }) }
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.accent)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (user.level > 0) {
              Text('LV' + user.level)
                .fontSize(9).fontWeight(FontWeight.Bold).fontColor(AppTheme.onAccent(this.accent))
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .backgroundColor(this.accent).borderRadius(2)
            }
          }
          Text(formatCount(user.fans) + '粉丝 · ' + String(user.videos) + '个视频')
            .fontSize(11).fontColor('#9499A0')
          Text(user.verifyDesc.length > 0 ? user.verifyDesc : user.usign)
            .fontSize(11).fontColor('#9499A0').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => this.openUserSpace(user))
        Text('查看主页 ›')
          .fontSize(11)
          .fontColor(this.isDark ? '#B8B8BE' : '#61666D')
          .padding({ left: 8, right: 2, top: 10, bottom: 10 })
          .onClick(() => this.openUserSpace(user))
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 10 })
      if (user.recentVideos.length > 0) {
        Row() {
          ForEach(user.recentVideos.slice(0, 3), (video: VideoItem) => {
            this.AllUserRecentVideo(video)
          }, (video: VideoItem) => video.bvid + String(video.aid))
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Top)
        .padding({ left: 14, right: 14, bottom: 10 })
        Row() {
          Text('查看全部' + String(user.videos) + '个视频')
            .fontSize(12)
            .fontColor(this.isDark ? '#D6D7DB' : '#3A3B3F')
          Text('›').fontSize(17).fontColor('#9499A0')
        }
        .width('100%')
        .height(36)
        .justifyContent(FlexAlign.Center)
        .border({ width: { top: 0.5 }, color: this.isDark ? '#34363B' : '#E3E5E7' })
        .onClick(() => this.openUserSpace(user))
      }
    }
    .width('100%')
  }


  build() {
    Column() {
      if (this.expanded) {
        this.AllUserCard(this.item)
      } else {
        this.CompactCard(this.item)
      }
    }.width('100%')
  }
}
