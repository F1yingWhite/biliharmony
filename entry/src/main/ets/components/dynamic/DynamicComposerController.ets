import { common } from '@kit.AbilityKit';
import { ActionResult } from '../../api/BiliApi';
import { DynamicApi, DynUploadedImage } from '../../api/DynamicApi';
import { DynDraftImage, DynImagePreparer } from '../../common/DynImagePreparer';
import { AuthSession } from '../../services/auth/AuthSession';

export const DYNAMIC_MAX_IMAGES: number = 9;

export class DynamicComposerState {
  text: string = '';
  images: Array<DynDraftImage> = [];
  busy: boolean = false;
  stage: string = '';
}

/** 页面持有草稿资源，面板只订阅状态；关闭再打开面板仍可继续编辑。 */
export class DynamicComposerController {
  private draft: DynamicComposerState = new DynamicComposerState();
  private operation: number = 0;
  private observer: ((state: DynamicComposerState) => void) | null = null;
  private onPublished: () => void;
  private toast: (message: string) => void;

  constructor(onPublished: () => void, toast: (message: string) => void) {
    this.onPublished = onPublished;
    this.toast = toast;
  }

  attach(observer: (state: DynamicComposerState) => void): void {
    this.observer = observer;
    this.emit();
  }

  detach(): void { this.observer = null; }

  reset(): void {
    this.operation++;
    DynImagePreparer.cleanup(this.draft.images);
    this.draft = new DynamicComposerState();
    this.emit();
  }

  setText(text: string): void {
    if (this.draft.busy) return;
    this.draft.text = text;
    this.emit();
  }

  removeImage(key: string): void {
    if (this.draft.busy) return;
    const removed: Array<DynDraftImage> = this.draft.images.filter((image: DynDraftImage) => image.key === key);
    this.draft.images = this.draft.images.filter((image: DynDraftImage) => image.key !== key);
    DynImagePreparer.cleanup(removed);
    this.emit();
  }

  async pick(context: common.Context, select: (remaining: number) => Promise<Array<string>>): Promise<void> {
    if (this.draft.busy) return;
    const remaining: number = DYNAMIC_MAX_IMAGES - this.draft.images.length;
    if (remaining <= 0) { this.toast('一条动态最多 ' + String(DYNAMIC_MAX_IMAGES) + ' 张图片'); return; }
    const operation: number = ++this.operation;
    const session: number = AuthSession.version;
    this.draft.busy = true;
    this.emit();
    try {
      const uris: Array<string> = await select(remaining);
      if (!this.isCurrent(operation, session)) return;
      this.draft.stage = '处理图片…';
      this.emit();
      let failed: number = 0;
      for (let i: number = 0; i < uris.length && this.draft.images.length < DYNAMIC_MAX_IMAGES; i++) {
        const image: DynDraftImage | null = await DynImagePreparer.prepare(context, uris[i]);
        if (!this.isCurrent(operation, session)) {
          if (image !== null) DynImagePreparer.cleanup([image]);
          return;
        }
        if (image === null) failed++;
        else { this.draft.images.push(image); this.emit(); }
      }
      if (failed > 0) this.toast(String(failed) + ' 张图片处理失败，已跳过');
    } catch (e) {
      // 用户取消相册时保留已有草稿。
    } finally {
      this.finish(operation);
    }
  }

  async submit(): Promise<void> {
    if (this.draft.busy) return;
    const text: string = this.draft.text.trim();
    const images: Array<DynDraftImage> = this.draft.images.slice();
    if (text.length === 0 && images.length === 0) return;
    if (text.length > 2000) { this.toast('动态内容过长（最多 2000 字）'); return; }
    const operation: number = ++this.operation;
    const session: number = AuthSession.version;
    this.draft.busy = true;
    this.emit();
    try {
      const uploaded: Array<DynUploadedImage> = [];
      for (let i: number = 0; i < images.length; i++) {
        this.draft.stage = '上传图片 ' + String(i + 1) + '/' + String(images.length);
        this.emit();
        const bytes: ArrayBuffer = await DynImagePreparer.readBytes(images[i].cachePath);
        if (!this.isCurrent(operation, session)) return;
        const result = await DynamicApi.uploadDynImage(bytes, images[i].fileName, images[i].mimeType);
        if (!this.isCurrent(operation, session)) return;
        if (!result.ok || result.image === null) { this.toast(result.message); return; }
        uploaded.push(result.image);
      }
      this.draft.stage = '发布中…';
      this.emit();
      const result: ActionResult = images.length > 0 ?
        await DynamicApi.publishWithImages(text, uploaded) : await DynamicApi.publish(text);
      if (!this.isCurrent(operation, session)) return;
      if (result.ok) {
        DynImagePreparer.cleanup(images);
        this.draft = new DynamicComposerState();
        this.emit();
        this.toast('发布成功');
        this.onPublished();
      } else this.toast(result.message);
    } catch (e) {
      if (this.isCurrent(operation, session)) this.toast('发布失败，请检查网络');
    } finally {
      this.finish(operation);
    }
  }

  private isCurrent(operation: number, session: number): boolean {
    return this.operation === operation && AuthSession.version === session;
  }

  private finish(operation: number): void {
    if (this.operation !== operation) return;
    this.draft.busy = false;
    this.draft.stage = '';
    this.emit();
  }

  private emit(): void {
    if (this.observer !== null) this.observer({ text: this.draft.text, images: this.draft.images.slice(),
      busy: this.draft.busy, stage: this.draft.stage });
  }
}
