import { VideoReportApi, VideoReportReason } from '../api/VideoReportApi';
import { ActionResult } from '../api/internal/ApiCommon';
import { common } from '@kit.AbilityKit';

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
  private generation: number = 0;

  aboutToAppear(): void {
    this.alive = true;
    this.generation += 1;
    this.submitting = false;
    this.selected = -1;
    this.reasons = [];
    this.description = '';
    this.loadReasons();
  }

  aboutToDisappear(): void { this.alive = false; this.generation += 1; }

  private isCurrent(generation: number): boolean {
    return this.alive && this.generation === generation;
  }

  private selectedReason(): VideoReportReason | undefined {
    return this.selected >= 0 && this.selected < this.reasons.length ? this.reasons[this.selected] : undefined;
  }

  private needsOfficialForm(): boolean {
    const reason: VideoReportReason | undefined = this.selectedReason();
    return reason !== undefined && reason.officialUrl.length > 0;
  }

  private canSubmit(): boolean {
    const reason: VideoReportReason | undefined = this.selectedReason();
    return !this.loading && !this.submitting && reason !== undefined &&
      (reason.officialUrl.length > 0 || reason.canSubmit(this.description));
  }

  private async loadReasons(): Promise<void> {
    const generation: number = ++this.generation;
    this.loading = true;
    this.error = '';
    try {
      const reasons: Array<VideoReportReason> = await VideoReportApi.reasons(this.aid);
      if (this.isCurrent(generation)) this.reasons = reasons;
    } catch (_) {
      if (this.isCurrent(generation)) this.error = '举报原因加载失败，请重试';
    } finally {
      if (this.isCurrent(generation)) this.loading = false;
    }
  }

  private async submit(): Promise<void> {
    const reason: VideoReportReason | undefined = this.selectedReason();
    if (!this.alive || !this.canSubmit() || reason === undefined) return;
    const generation: number = this.generation;
    const aid: number = this.aid;
    const description: string = this.description;
    this.submitting = true;
    this.error = '';
    try {
      if (reason.officialUrl.length > 0) {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.openLink(reason.officialUrl);
        if (this.isCurrent(generation)) this.controller?.close();
        return;
      }
      const result: ActionResult = await VideoReportApi.submit(aid, reason, description);
      if (!this.isCurrent(generation)) return;
      if (result.ok) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
        this.controller?.close();
      } else {
        this.error = result.message;
      }
    } catch (_) {
      if (this.isCurrent(generation)) this.error = reason.officialUrl.length > 0 ?
        '官方申诉页面打开失败，请重试' : '提交失败，请检查网络后重试';
    } finally {
      if (this.isCurrent(generation)) this.submitting = false;
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
        if (this.needsOfficialForm()) {
          Text('此类型需在官方申诉页面填写专用材料，点击下方按钮继续。')
            .fontSize(13).fontColor('#9499A0')
        } else {
          Text('详细描述（必填）').fontSize(13).fontColor(this.isDark ? '#F1F2F4' : '#18191C')
          TextArea({ text: this.description, placeholder: this.selected >= 0 ?
            this.reasons[this.selected].hint : '请描述具体问题及出现时间，例如 01:20' })
            .height(130).maxLength(500).enabled(!this.submitting)
            .onChange((value: string) => { this.description = value; })
        }
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
          Button(this.submitting ? (this.needsOfficialForm() ? '打开中…' : '提交中…') :
            (this.needsOfficialForm() ? '前往官方申诉' : '提交举报')).layoutWeight(1).backgroundColor(this.accent)
            .enabled(this.canSubmit())
            .onClick(() => { this.submit(); })
        }
      }
    }
    .padding(24).width('90%').constraintSize({ maxWidth: 480 })
    .backgroundColor(this.isDark ? '#26272B' : '#FFFFFF').borderRadius(24)

  }
}
