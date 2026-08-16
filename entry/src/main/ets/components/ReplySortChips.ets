/**
 * 评论区排序切换 chips：最热（mode=3）/ 最新（mode=2）。
 * 视频详情、动态详情、番剧详情共用；切换后由父组件清空列表并重新拉第一页。
 */
import { FilterChip } from './FilterChip';

@Component
export struct ReplySortChips {
  @Prop mode: number = 3;
  onChange: (mode: number) => void = () => {
  };

  build() {
    Row() {
      FilterChip({
        label: '最热',
        selected: this.mode === 3,
        onTap: () => {
          this.onChange(3);
        },
      })
      FilterChip({
        label: '最新',
        selected: this.mode === 2,
        onTap: () => {
          this.onChange(2);
        },
      })
    }
  }
}
