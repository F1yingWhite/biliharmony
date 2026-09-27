/**
 * 「继续观看」服务卡片（2x2 / 2x4）：展示最近观看的封面、标题与进度，
 * 点击直达应用内该视频详情页续播。
 * 封面不可用时使用本地占位图；卡片宿主中的远程封面仍需通过 formImages 传输。
 */
@Entry
@Component
struct ContinueWatchCard {
  @LocalStorageProp('title') title: string = 'BiliHaromny';
  @LocalStorageProp('cover') cover: string = '';
  @LocalStorageProp('progressText') progressText: string = '去首页看看新内容吧';
  @LocalStorageProp('hasRecord') hasRecord: boolean = false;
  @LocalStorageProp('bvid') bvid: string = '';
  @LocalStorageProp('aid') aid: number = 0;

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.cover.length > 0) {
        Image(this.cover)
          .alt($r('app.media.placeholder_cover'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(14)
          .transition(TransitionEffect.OPACITY)
      } else {
        Column() {
          Image($r('app.media.bilix_logo'))
            .height(this.hasRecord ? 26 : 34)
            .objectFit(ImageFit.Contain)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [['#FF6C9E', 0], ['#FB7299', 0.55], ['#E85A88', 1]]
        })
      }

      // 底部渐变遮罩 + 文案
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(this.hasRecord ? 14 : 12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.progressText)
          .fontSize(11)
          .fontColor('#E6FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['#99000000', 0], ['#CC000000', 1]]
      })
    }
    .width('100%')
    .height('100%')
    .borderRadius(14)
    .clip(true)
    .onClick(() => {
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': { 'bvid': this.bvid, 'aid': String(this.aid), 'from': 'card' }
      });
    })
  }
}
