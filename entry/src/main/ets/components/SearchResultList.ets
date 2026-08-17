/**
 * 搜索页结果列表通用壳：统一 loading / 空态 / LazyForEach 列表 / 触底加载 / footer。
 * 内容通过 @BuilderParam 注入，调用方只需提供数据源 LazyForEach，避免 7 个结果 Tab 各自复制同一截骨架。
 */
import { LoadingView } from './LoadingView';
import { LoadMoreFooter } from './LoadMoreFooter';

@Component
export struct SearchResultList {
  @Prop loading: boolean = false;
  @Prop loadingMore: boolean = false;
  @Prop count: number = 0;
  @Prop emptyText: string = '没有找到相关内容';
  /** 列表项间距（直播双列用 10，其余默认 0） */
  @Prop listSpace: number = 0;
  /** 列表列数：直播双列为 2，其余 1 */
  @Prop lanes: number = 1;
  /** 直播双列的左右内边距，其余列表为 0 */
  @Prop horizontalPadding: number = 0;
  onRetry: () => void = () => {};
  onLoadMore: () => void = () => {};
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
  }

  build() {
    Column() {
      if (this.loading) {
        LoadingView({ loading: true })
      } else if (this.count === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: this.emptyText,
          onRetry: this.onRetry,
        })
      } else {
        List({ space: this.listSpace }) {
          this.content()
          ListItem() {
            LoadMoreFooter({
              loading: this.loadingMore,
              hasMore: true,
              moreText: this.loadingMore ? '' : '上滑加载更多',
              endText: '',
              fixedHeight: 44,
              onLoadMore: this.onLoadMore,
            })
          }
        }
        .width('100%')
        .height('100%')
        .lanes(this.lanes)
        .padding(this.horizontalPadding > 0 ? { left: this.horizontalPadding, right: this.horizontalPadding } : 0)
        .cachedCount(5)
        .scrollBar(BarState.Off)
        .onReachEnd((): void => {
          this.onLoadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
