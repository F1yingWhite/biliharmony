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
  @Prop errorText: string = '';
  @Prop moreError: string = '';
  @Prop hasMore: boolean = true;
  @Prop count: number = 0;
  @Prop emptyText: string = '没有找到相关内容';
  @Prop skeleton: string = '';
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

  @Builder
  ResultFooter() {
    LoadMoreFooter({
      loading: this.loadingMore,
      hasMore: this.hasMore,
      moreText: this.moreError.length > 0 ? '加载失败 · 点击重试' : '上滑加载更多',
      endText: '没有更多结果了',
      fixedHeight: 44,
      onLoadMore: this.onLoadMore,
    })
  }

  build() {
    Column() {
      if (this.loading) {
        LoadingView({ loading: true, skeleton: this.skeleton.length > 0 ? this.skeleton : (this.lanes > 1 ? 'grid' : 'list') })
      } else if (this.errorText.length > 0) {
        LoadingView({ loading: false, errorText: this.errorText, onRetry: this.onRetry })
      } else if (this.count === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: this.emptyText,
          onRetry: this.onRetry,
        })
      } else {
        List({ space: this.listSpace }) {
          if (this.lanes > 1) {
            ListItemGroup({ footer: this.ResultFooter(), space: this.listSpace }) {
              this.content()
            }
          } else {
            this.content()
            ListItem() { this.ResultFooter() }
          }

        }
        .width('100%')
        .height('100%')
        .lanes(this.lanes, this.lanes > 1 ? 10 : 0)
        .padding(this.horizontalPadding > 0 ? { left: this.horizontalPadding, right: this.horizontalPadding } : 0)
        .cachedCount(5)
        .scrollBar(BarState.Off)
        .onReachEnd((): void => {
          if (this.hasMore && !this.loadingMore && this.moreError.length === 0) this.onLoadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
