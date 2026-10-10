import { FilterChip } from '../FilterChip';
import { SearchOption, VIDEO_ORDER_OPTIONS, USER_TYPE_OPTIONS, USER_ORDER_OPTIONS, LIVE_ORDER_OPTIONS } from '../../model/Models';
import { SearchCategory, SearchQuery } from './SearchQuery';

@Component
export struct SearchSortBar {
  @Prop query: SearchQuery = new SearchQuery();
  @Prop tab: SearchCategory = SearchCategory.All;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onChange: (query: SearchQuery) => void = (): void => {};
  onFilter: () => void = (): void => {};

  @Builder
  VideoSortRow() {
    Row() {
      Scroll() {
        Row() {
          ForEach(VIDEO_ORDER_OPTIONS, (opt: SearchOption) => {
            FilterChip({
              label: opt.label,
              selected: this.query.videoOrder === opt.value,
              bottomMargin: 8,
              onTap: () => {
                const query: SearchQuery = this.query.copy();
                query.videoOrder = opt.value;
                this.onChange(query);
              },
            })
          }, (opt: SearchOption) => opt.value)
        }
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)

      Button({ type: ButtonType.Normal }) {
      Row({ space: 3 }) {
        Image($r('app.media.ic_filter'))
          .width(13)
          .height(13)
          .fillColor(this.query.hasVideoFilter() ? this.accent : (this.isDark ? '#C6C7CB' : '#61666D'))
        Text('筛选')
          .fontSize(12)
          .fontColor(this.query.hasVideoFilter() ? this.accent : (this.isDark ? '#C6C7CB' : '#61666D'))
      }
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.isDark ? '#2E3136' : '#ECEEF0')
      .borderRadius(14)
      }
      .constraintSize({ minWidth: 44, minHeight: 44 }).padding(0)
      .backgroundColor(Color.Transparent).borderRadius(22)
      .margin({ left: 4, bottom: 8 })
      .accessibilityGroup(true).accessibilityText('筛选视频')
      .accessibilityDescription(this.query.hasVideoFilter() ? '已应用筛选' : '')
      .onClick(() => {
        this.onFilter();
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2 })
  }

  // ===== 结果态：用户类型筛选 + 排序 =====
  @Builder
  UserSortRow() {
    Column({ space: 8 }) {
      Row() {
        ForEach(USER_TYPE_OPTIONS, (opt: SearchOption) => {
          FilterChip({
            label: opt.label,
            selected: this.query.userType === Number(opt.value),
            bottomMargin: 0,
            onTap: () => {
              const query: SearchQuery = this.query.copy();
              query.userType = Number(opt.value);
              this.onChange(query);
            },
          })
        }, (opt: SearchOption) => 'ut' + opt.label)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })
      Row() {
        ForEach(USER_ORDER_OPTIONS, (opt: SearchOption) => {
          FilterChip({
            label: opt.label,
            selected: this.query.userOrder === opt.value,
            bottomMargin: 8,
            onTap: () => {
              const query: SearchQuery = this.query.copy();
              query.userOrder = opt.value;
              this.onChange(query);
            },
          })
        }, (opt: SearchOption) => opt.label)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })
    }
    .width('100%')
  }

  // ===== 结果态：直播排序行（人气 / 最新开播） =====
  @Builder
  LiveSortRow() {
    Row() {
      ForEach(LIVE_ORDER_OPTIONS, (opt: SearchOption) => {
        FilterChip({
          label: opt.label,
          selected: this.query.liveOrder === opt.value,
          bottomMargin: 8,
          onTap: () => {
            const query: SearchQuery = this.query.copy();
            query.liveOrder = opt.value;
            this.onChange(query);
          },
        })
      }, (opt: SearchOption) => opt.value)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2 })
  }

  build() {
    Column() {
      if (this.tab === SearchCategory.All || this.tab === SearchCategory.Video) {
        this.VideoSortRow()
      } else if (this.tab === SearchCategory.User) {
        this.UserSortRow()
      } else if (this.tab === SearchCategory.Live) {
        this.LiveSortRow()
      }
    }.width('100%')
  }
}
