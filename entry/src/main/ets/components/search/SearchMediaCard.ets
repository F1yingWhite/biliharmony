import { KeywordSpans } from '../KeywordSpans';
import { AppTheme } from '../../common/AppTheme';
import { PgcSearchItem } from '../../model/Models';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { AppNavStack, BangumiDetailParam, NAV_BANGUMI_DETAIL } from '../../common/AppRouter';

@Component
export struct SearchMediaCard {
  @Prop item: PgcSearchItem = new PgcSearchItem();
  @Prop keyword: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image(biliImageThumbnail(this.item.cover, 320))
          .width(84)
          .height(112)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.placeholder_cover'))
        if (this.item.seasonTypeName.length > 0) {
          Text(this.item.seasonTypeName)
            .fontSize(9)
            .fontColor(AppTheme.onAccent(this.accent))
            .backgroundColor(this.accent)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius({ topLeft: 6, bottomRight: 6 })
        }
      }
      .width(84)
      .height(112)
      .clip(true)
      .borderRadius(6)
      Column({ space: 5 }) {
        Text() { KeywordSpans({ text: this.item.title, keyword: this.keyword, isDark: this.isDark }) }
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          if (this.item.scoreText().length > 0) {
            Text(this.item.scoreText())
              .fontSize(11)
              .fontColor(this.accent)
          }
          if (this.item.indexShow.length > 0) {
            Text(this.item.indexShow)
              .fontSize(11)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        if (this.item.areas.length > 0 || this.item.styles.length > 0) {
          Text((this.item.areas.length > 0 ? this.item.areas : '') +
            (this.item.areas.length > 0 && this.item.styles.length > 0 ? ' · ' : '') + this.item.styles)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.item.desc.length > 0) {
          Text() { KeywordSpans({ text: this.item.desc, keyword: this.keyword, isDark: this.isDark }) }
            .fontSize(11)
            .fontColor('#B0B3B8')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .onClick(() => {
      const param: BangumiDetailParam = { seasonId: this.item.seasonId, epId: 0, title: this.item.title };
      AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
    })
  }

}
