/** 专栏阅读页：应用内 Web 加载 B 站文章，避免跳到外部浏览器。 */
import { webview } from '@kit.ArkWeb';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { ArticlePageParam } from '../common/AppRouter';

@Component
export struct ArticlePage {
  param: ArticlePageParam = { id: 0, title: '' };
  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    Column() {
      PageHeader({ title: this.param.title.length > 0 ? this.param.title : '专栏' })
      if (this.param.id > 0) {
        Web({
          src: 'https://www.bilibili.com/read/cv' + String(this.param.id),
          controller: this.controller,
        })
          .width('100%')
          .layoutWeight(1)
      } else {
        Column() {
          Text('文章参数无效').fontSize(14).fontColor('#9499A0')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor('#FFFFFF')
  }
}
