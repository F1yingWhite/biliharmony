import { HotSearchItem } from '../../model/Models';
import { LayoutTokens } from '../../common/LayoutTokens';
import { formatCount } from '../../common/Utils';
import { SearchDiscoveryView } from './SearchDiscoveryController';

@Component
export struct SearchDiscoveryContent {
  @Prop view: SearchDiscoveryView = new SearchDiscoveryView();
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onSearch: (keyword: string) => void = (): void => {};
  onRemoveHistory: (keyword: string) => void = (): void => {};
  onClearHistory: () => void = (): void => {};

  @Builder
  SearchHistory() {
    Column({ space: 8 }) {
      Row() {
        Text('搜索历史')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
        Text('清空')
          .fontSize(12)
          .fontColor('#9499A0')
          .onClick(() => {
            this.onClearHistory();
          })
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.view.history, (word: string) => {
          Row({ space: 5 }) {
            Text(word)
              .fontSize(12)
              .fontColor(this.isDark ? '#E6E6E6' : '#454A50')
              .maxLines(1)
              .constraintSize({ maxWidth: 150 })
              .onClick(() => {
                this.onSearch(word);
              })
            Image($r('app.media.ic_close'))
              .width(10)
              .height(10)
              .fillColor('#9499A0')
              .onClick(() => {
                this.onRemoveHistory(word);
              })
          }
          .padding({ left: 10, right: 8, top: 6, bottom: 6 })
          .margin({ right: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor(this.isDark ? '#2E3136' : '#E9EBEE')
        }, (word: string) => word)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 2 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  HotList() {
    Column() {
      List() {
        ListItemGroup({ header: this.HotSectionHeader('热搜榜') }) {
          ForEach(this.view.hot, (item: HotSearchItem, index: number) => {
            ListItem() {
              this.HotRow(item, index)
            }
          }, (item: HotSearchItem) => 'hot' + item.keyword)
        }
        if (this.view.trending.length > 0) {
          ListItemGroup({ header: this.HotSectionHeader('趋势榜') }) {
            ForEach(this.view.trending, (item: HotSearchItem, index: number) => {
              ListItem() {
                this.HotRow(item, index)
              }
            }, (item: HotSearchItem) => 'trend' + item.keyword)
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
      .alignSelf(ItemAlign.Center)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  HotSectionHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 6 })
  }

  @Builder
  HotRow(item: HotSearchItem, index: number) {
    Row({ space: 10 }) {
      Text(String(index + 1))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(index < 3 ? this.accent : '#9499A0')
        .width(24)
        .textAlign(TextAlign.Center)
      if (item.icon.length > 0) {
        Image(item.icon)
          .width(16)
          .height(16)
      }
      Text(item.showName)
        .fontSize(14)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(item.heatScore > 0 ? formatCount(item.heatScore) + ' 热度' : '')
        .fontSize(11)
        .fontColor('#9499A0')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .onClick(() => {
      this.onSearch(item.keyword);
    })
  }

  @Builder
  SuggestList() {
    Column() {
      ForEach(this.view.suggests, (s: string) => {
        Row({ space: 8 }) {
          Image($r('app.media.ic_search'))
            .width(18)
            .height(18)
            .fillColor(this.accent)
          Text(s)
            .fontSize(14)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          this.onSearch(s);
        })
      }, (s: string) => s)
    }
    .width('100%')
    .backgroundColor(this.isDark ? '#2A2C31' : '#FFFFFF')
    .borderRadius(10)
    .margin({ left: 10, right: 10 })
  }

  build() {
    Column() {
      if (this.view.suggests.length > 0) {
        this.SuggestList()
      } else {
        if (this.view.history.length > 0) {
          this.SearchHistory()
        }
        this.HotList()
      }
    }.width('100%').height('100%')
  }
}
