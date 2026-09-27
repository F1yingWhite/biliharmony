/**
 * 「继续观看」服务卡片（2x2 / 2x4）：展示最近观看的封面、标题与进度，
 * 点击直达应用内该视频详情页续播。
 * 卡片环境禁用网络图片？——Image 支持网络图但卡片刷新受限，优先用已缓存的
 * 封面 URL（系统图片栈会走磁盘缓存）；无封面时显示站标占位。
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
        angle: 270,
        colors: [['#00000000', 0], ['#99000000', 0.75], ['#CC000000', 1]]
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
