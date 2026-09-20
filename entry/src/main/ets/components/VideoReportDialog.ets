import { VideoReportApi, VideoReportReason } from '../api/VideoReportApi';
import { ActionResult } from '../api/internal/ApiCommon';

@CustomDialog
export struct VideoReportDialog {
  controller?: CustomDialogController;
  aid: number = 0;
  title: string = '';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @State reasons: Array<VideoReportReason> = [];
  @State selected: number = -1;
  @State description: string = '';
  @State loading: boolean = true;
  @State submitting: boolean = false;
  @State error: string = '';
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    this.loadReasons();
  }

  aboutToDisappear(): void { this.alive = false; }

  private async loadReasons(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const reasons: Array<VideoReportReason> = await VideoReportApi.reasons();
      if (this.alive) this.reasons = reasons;
    } catch (_) {
      if (this.alive) this.error = '举报原因加载失败，请重试';
    } finally {
      if (this.alive) this.loading = false;
    }
  }

  private async submit(): Promise<void> {
    if (this.submitting || this.selected < 0 || this.selected >= this.reasons.length ||
      this.description.trim().length === 0) return;
    this.submitting = true;
    this.error = '';
    try {
      const result: ActionResult = await VideoReportApi.submit(this.aid,
        this.reasons[this.selected].id, this.description);
      if (!this.alive) return;
      if (result.ok) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
        this.controller?.close();
      } else {
        this.error = result.message;
      }
    } catch (_) {
      if (this.alive) this.error = '提交失败，请检查网络后重试';
    } finally {
      if (this.alive) this.submitting = false;
    }
  }

  build() {
    Column({ space: 14 }) {
      Text('举报视频').fontColor(this.isDark ? '#F1F2F4' : '#18191C').fontSize(20).fontWeight(FontWeight.Bold)
      Text(this.title).fontSize(13).fontColor('#9499A0').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.loading) {
        LoadingProgress().width(32).height(32)
      } else if (this.reasons.length > 0) {
        Select(this.reasons.map((reason: VideoReportReason): SelectOption => ({ value: reason.name })))
          .value(this.selected >= 0 ? this.reasons[this.selected].name : '请选择举报原因').selected(this.selected).width('100%')
          .enabled(!this.submitting)
          .onSelect((index: number) => { this.selected = index; this.error = ''; })
        TextArea({ text: this.description, placeholder: this.selected >= 0 ?
          this.reasons[this.selected].hint : '请描述具体问题及出现时间，例如 01:20' })
          .height(130).maxLength(500).enabled(!this.submitting)
          .onChange((value: string) => { this.description = value; })
      }
      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor('#F56C6C')
      }
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).enabled(!this.submitting)
          .onClick(() => this.controller?.close())
        if (!this.loading && this.reasons.length === 0) {
          Button('重试').layoutWeight(1).backgroundColor(this.accent).onClick(() => { this.loadReasons(); })
        } else {
          Button(this.submitting ? '提交中…' : '提交举报').layoutWeight(1).backgroundColor(this.accent)
            .enabled(!this.loading && !this.submitting && this.selected >= 0 && this.description.trim().length > 0)
            .onClick(() => { this.submit(); })
        }
      }
    }
    .padding(24).width('90%').constraintSize({ maxWidth: 480 })
    .backgroundColor(this.isDark ? '#26272B' : '#FFFFFF').borderRadius(24)

  }
}
