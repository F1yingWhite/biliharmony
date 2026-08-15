import { curves } from '@kit.ArkUI';

/** 视频点赞/投币/收藏/分享共用的主题色与弹性反馈按钮。 */
@Component
export struct VideoActionItem {
  @Prop icon: Resource = $r('app.media.bilix_icon_like');
  @Prop value: string = '';
  @Prop active: boolean = false;
  @Prop busy: boolean = false;
  onTap: () => void = () => {};
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State iconScale: number = 1;
  private destroyed: boolean = false;
  private timers: Set<number> = new Set<number>();

  aboutToAppear(): void {
    this.destroyed = false;
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.timers.forEach((id: number) => clearTimeout(id));
    this.timers.clear();
  }

  private scheduleTimeout(callback: () => void, delayMs: number): void {
    const id: number = setTimeout(() => {
      this.timers.delete(id);
      if (!this.destroyed) callback();
    }, delayMs);
    this.timers.add(id);
  }

  build() {
    Column({ space: 4 }) {
      Image(this.icon)
        .width(22)
        .height(22)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.active ? this.accent : (this.isDark ? '#C8C8CC' : '#5A5F66'))
        .scale({ x: this.iconScale, y: this.iconScale })
      Text(this.value)
        .fontSize(11)
        .fontColor(this.active ? this.accent : (this.isDark ? '#C8C8CC' : '#5A5F66'))
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      if (this.busy) return;
      // 颜色由父页乐观更新驱动（active 即时翻转）；这里只做两段式弹性反馈：
      // 选中先放大再回落，取消先缩小再回弹，两个方向都有完整动画。
      const activating: boolean = !this.active;
      animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
        this.iconScale = activating ? 1.3 : 0.78;
      });
      this.scheduleTimeout(() => {
        animateTo({ curve: curves.springMotion(0.35, 0.6) }, () => {
          this.iconScale = 1;
        });
      }, 120);
      this.onTap();
    })
  }
}
