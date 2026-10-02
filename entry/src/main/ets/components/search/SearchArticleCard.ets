import { KeywordSpans } from '../KeywordSpans';
import { ArticleSearchItem } from '../../model/Models';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { formatCount } from '../../common/Utils';
import { AppNavStack, ArticlePageParam, NAV_ARTICLE } from '../../common/AppRouter';

@Component
export struct SearchArticleCard {
  @Prop item: ArticleSearchItem = new ArticleSearchItem();
  @Prop keyword: string = '';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private openArticle(item: ArticleSearchItem): void {
    const param: ArticlePageParam = { id: item.id, title: item.title };
    AppNavStack.pushPathByName(NAV_ARTICLE, param);
  }

  build() {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Text() { KeywordSpans({ text: this.item.title, keyword: this.keyword, isDark: this.isDark }) }
          .fontSize(13)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
        if (this.item.desc.length > 0) {
          Text() { KeywordSpans({ text: this.item.desc, keyword: this.keyword, isDark: this.isDark }) }
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text((this.item.upName.length > 0 ? this.item.upName + ' · ' : '') +
          formatCount(this.item.view) + '阅读 · ' + formatCount(this.item.reply) + '评论')
          .fontSize(11)
          .fontColor('#B0B3B8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.item.cover.length > 0) {
        Image(biliImageThumbnail(this.item.cover, 360))
          .width(110)
          .height(74)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
          .alt($r('app.media.placeholder_cover'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .onClick(() => {
      this.openArticle(this.item);
    })
  }

}
