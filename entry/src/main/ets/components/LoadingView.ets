/**
 * 通用状态组件：加载中 / 空内容 / 错误重试
 */
@Component
export struct LoadingView {
  loading: boolean = true;
  empty: boolean = false;
  emptyText: string = '暂无内容';
  errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  onRetry: () => void = () => {
  };

  build() {
    Column() {
      if (this.loading) {
        // B 站经典小电视抖天线加载动画
        Image($r('app.media.bilix_loading_tv'))
          .width(72)
          .height(72)
          .margin({ top: 40 })
        Text('加载中...')
          .fontSize(13)
          .fontColor('#999999')
          .margin({ top: 12 })
      } else if (this.empty) {
        Column() {
          // 22 娘空箱插图
          Image($r('app.media.bilix_empty_2233'))
            .width(200)
            .aspectRatio(560 / 316)
            .margin({ top: 40 })
          Text(this.emptyText)
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 10 })
        }
        .width('100%')
      } else if (this.errorText.length > 0) {
        Column() {
          // 2233 断网插图
          Image($r('app.media.bilix_error_2233'))
            .width(200)
            .aspectRatio(560 / 316)
            .margin({ top: 40 })
          Text('加载失败')
            .fontSize(15)
            .fontColor('#666666')
            .margin({ top: 10 })
          Text(this.errorText)
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 8 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('重试')
            .fontSize(13)
            .fontColor(this.accent)
            .backgroundColor('#00000000')
            .margin({ top: 14 })
            .onClick(() => {
              this.onRetry();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
  }
}
