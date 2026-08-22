/**
 * 播放器长按 2x 倍速控制器：负责临时倍速切换与状态同步。
 * 从 PlayerView 抽离，把“按住 2x、松手还原”独立成类。
 */
export class PlayerSpeedController {
  private active: boolean = false;
  private previousRate: number = 1;
  private applyRate: (rate: number) => void;
  private onActiveChange: (active: boolean) => void;

  constructor(applyRate: (rate: number) => void, onActiveChange: (active: boolean) => void) {
    this.applyRate = applyRate;
    this.onActiveChange = onActiveChange;
  }

  beginHold(rate: number): void {
    if (this.active) return;
    this.previousRate = rate;
    this.active = true;
    this.onActiveChange(true);
    this.applyRate(2);
  }

  endHold(): void {
    if (!this.active) return;
    this.active = false;
    this.onActiveChange(false);
    this.applyRate(this.previousRate);
  }
}
