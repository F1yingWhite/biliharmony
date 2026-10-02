import { FavoriteApi } from '../../api/FavoriteApi';
import { ActionResult } from '../../api/internal/ApiCommon';
import { RequestEpoch } from '../../common/RequestEpoch';
import { FavoriteFolderItem } from '../../model/library/LibraryModels';
import { FavoriteLibrarySession, FavoriteSessionToken } from './FavoriteLibrarySession';
import { FavoriteFolderDialogState, copyFavoriteFolder } from './FavoriteLibraryState';

/** 收藏夹创建/重命名草稿和提交锁不由页面布尔字段拼装。 */
export class FavoriteFolderEditor {
  view: FavoriteFolderDialogState = new FavoriteFolderDialogState();
  onChange: () => void = (): void => {};
  onToast: (message: string) => void = (): void => {};
  onSaved: (deletedId: number) => void = (): void => {};
  private session: FavoriteLibrarySession;
  private requests: RequestEpoch = new RequestEpoch();
  private target: FavoriteFolderItem = new FavoriteFolderItem();

  constructor(session: FavoriteLibrarySession) { this.session = session; }

  reset(): void {
    this.requests.invalidate();
    this.target = new FavoriteFolderItem();
    this.publish(new FavoriteFolderDialogState());
  }

  open(isEdit: boolean, folder: FavoriteFolderItem | null = null): void {
    if (this.view.busy || this.session.capture() === null || (isEdit && (folder === null || folder.id <= 0))) return;
    this.reset();
    this.target = folder === null ? new FavoriteFolderItem() : copyFavoriteFolder(folder);
    const view: FavoriteFolderDialogState = new FavoriteFolderDialogState();
    view.visible = true;
    view.isEdit = isEdit;
    view.input = isEdit ? this.target.title : '';
    this.publish(view);
  }

  setInput(value: string): void {
    if (this.view.busy) return;
    const view: FavoriteFolderDialogState = this.copy();
    view.input = value;
    this.publish(view);
  }

  close(): void { this.reset(); }

  async submit(): Promise<void> {
    const session: FavoriteSessionToken | null = this.session.capture();
    if (session === null || this.view.busy || !this.view.visible) return;
    const title: string = this.view.input.trim();
    if (title.length === 0) { this.onToast('收藏夹名称不能为空'); return; }
    const edit: boolean = this.view.isEdit;
    const target: FavoriteFolderItem = copyFavoriteFolder(this.target);
    const request: number = this.begin();
    try {
      const result: ActionResult = edit ?
        await FavoriteApi.editFavoriteFolder(target.id, title, target.isPublic, target.intro) : await FavoriteApi.addFavoriteFolder(title);
      if (!this.current(request, session)) return;
      this.onToast(result.ok ? (edit ? '已重命名' : '已创建') : result.message);
      if (result.ok) {
        const view: FavoriteFolderDialogState = this.copy();
        view.visible = false;
        this.publish(view);
        this.onSaved(0);
      }
    } catch (error) {
      if (this.current(request, session)) this.onToast('网络异常，请稍后重试');
    } finally {
      this.finish(request, session);
    }
  }

  async delete(folder: FavoriteFolderItem): Promise<void> {
    const session: FavoriteSessionToken | null = this.session.capture();
    if (session === null || this.view.busy || folder.id <= 0) return;
    const folderId: number = folder.id;
    const request: number = this.begin();
    try {
      const result: ActionResult = await FavoriteApi.delFavoriteFolder([folderId]);
      if (!this.current(request, session)) return;
      this.onToast(result.ok ? '已删除' : result.message);
      if (result.ok) this.onSaved(folderId);
    } catch (error) {
      if (this.current(request, session)) this.onToast('网络异常，请稍后重试');
    } finally {
      this.finish(request, session);
    }
  }

  private begin(): number {
    const request: number = this.requests.next();
    const view: FavoriteFolderDialogState = this.copy();
    view.busy = true;
    this.publish(view);
    return request;
  }

  private current(request: number, session: FavoriteSessionToken): boolean {
    return this.requests.isCurrent(request) && this.session.current(session);
  }

  private finish(request: number, session: FavoriteSessionToken): void {
    if (!this.current(request, session)) return;
    const view: FavoriteFolderDialogState = this.copy();
    view.busy = false;
    this.publish(view);
  }

  private copy(): FavoriteFolderDialogState {
    const view: FavoriteFolderDialogState = new FavoriteFolderDialogState();
    view.visible = this.view.visible;
    view.isEdit = this.view.isEdit;
    view.input = this.view.input;
    view.busy = this.view.busy;
    return view;
  }

  private publish(view: FavoriteFolderDialogState): void { this.view = view; this.onChange(); }
}
