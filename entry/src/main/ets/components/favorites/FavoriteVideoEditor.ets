import { FavoriteApi } from '../../api/FavoriteApi';
import { ActionResult } from '../../api/internal/ApiCommon';
import { RequestEpoch } from '../../common/RequestEpoch';
import { FavoriteFolderItem } from '../../model/library/LibraryModels';
import { VideoItem } from '../../model/video/VideoModels';
import { FavoriteLibrarySession, FavoriteSessionToken } from './FavoriteLibrarySession';
import { FavoriteEditState } from './FavoriteLibraryState';
import { FavoriteVideoList } from './FavoriteVideoList';

export interface FavoriteSelection {
  session: FavoriteSessionToken;
  edit: number;
  folderId: number;
  aids: Array<number>;
}

/** 编辑事务只操作捕获的收藏夹/资源ID；排序草稿与已确认的服务端结果分别提交。 */
export class FavoriteVideoEditor {
  view: FavoriteEditState = new FavoriteEditState();
  onChange: () => void = (): void => {};
  onToast: (message: string) => void = (): void => {};
  private session: FavoriteLibrarySession;
  private videos: FavoriteVideoList;
  private edits: RequestEpoch = new RequestEpoch();
  private activeEdit: number = 0;
  private actions: RequestEpoch = new RequestEpoch();
  private moves: RequestEpoch = new RequestEpoch();

  constructor(session: FavoriteLibrarySession, videos: FavoriteVideoList) {
    this.session = session;
    this.videos = videos;
  }

  reset(): void {
    this.edits.invalidate();
    this.actions.invalidate();
    this.moves.invalidate();
    this.publish(new FavoriteEditState());
  }

  async toggleEdit(): Promise<void> {
    if (this.view.busy || this.session.capture() === null || this.videos.selected.id <= 0 || this.videos.selected.type === 21) return;
    this.closeMoveSheet();
    if (this.view.editing && this.view.orderDirty) {
      await this.saveOrder();
      return;
    }
    this.videos.invalidate();
    const view: FavoriteEditState = new FavoriteEditState();
    view.editing = !this.view.editing;
    this.activeEdit = this.edits.next();
    this.publish(view);
    // LazyForEach 的编辑控件取决于行上下文，显式通知现有行切换选择/排序控件。
    this.notifyRows();
  }

  isChecked(aid: number): boolean { return this.view.checkedAids.indexOf(aid) >= 0; }

  toggleChecked(aid: number, index: number): void {
    if (!this.view.editing || this.view.busy || this.session.capture() === null) return;
    if (index < 0 || index >= this.videos.source.totalCount() || this.videos.source.getData(index).aid !== aid) return;
    this.closeMoveSheet();
    const view: FavoriteEditState = this.view.copy();
    view.checkedAids = this.isChecked(aid) ? view.checkedAids.filter((id: number) => id !== aid) : view.checkedAids.concat([aid]);
    this.publish(view);
    this.videos.source.notifyItemChanged(index);
  }

  moveVideo(index: number, delta: number): void {
    if (!this.view.editing || this.view.busy || this.session.capture() === null) return;
    const source: Array<VideoItem> = this.videos.source.getAll();
    const target: number = index + delta;
    if (index < 0 || index >= source.length || target < 0 || target >= source.length || target === index) return;
    this.videos.invalidate();
    const reordered: Array<VideoItem> = source.slice();
    const item: VideoItem = reordered.splice(index, 1)[0];
    reordered.splice(target, 0, item);
    this.videos.source.reset(reordered);
    const view: FavoriteEditState = this.view.copy();
    view.orderDirty = true;
    this.publish(view);
  }

  selection(): FavoriteSelection | null {
    const session: FavoriteSessionToken | null = this.session.capture();
    if (session === null || !this.view.editing || this.videos.selected.id <= 0) return null;
    return { session: session, edit: this.activeEdit, folderId: this.videos.selected.id, aids: this.view.checkedAids.slice() };
  }

  isCurrent(selection: FavoriteSelection): boolean {
    return this.session.current(selection.session) && this.edits.isCurrent(selection.edit) &&
      this.view.editing && this.videos.selected.id === selection.folderId;
  }

  closeMoveSheet(): void {
    this.moves.invalidate();
    const view: FavoriteEditState = this.view.copy();
    view.moveVisible = false;
    view.moveLoading = false;
    view.moveTargets = [];
    this.publish(view);
  }

  async openMoveSheet(): Promise<void> {
    const selection: FavoriteSelection | null = this.selection();
    if (selection === null || this.view.busy || this.view.moveLoading) return;
    if (selection.aids.length === 0) { this.onToast('请先选择视频'); return; }
    const request: number = this.moves.next();
    const pending: FavoriteEditState = this.view.copy();
    pending.moveLoading = true;
    this.publish(pending);
    try {
      const all: Array<FavoriteFolderItem> = await FavoriteApi.getAllFavoriteFolders(selection.session.mid);
      if (!this.moves.isCurrent(request) || !this.isCurrent(selection)) return;
      const view: FavoriteEditState = this.view.copy();
      view.moveTargets = all.filter((folder: FavoriteFolderItem) => folder.id !== selection.folderId);
      view.moveVisible = view.moveTargets.length > 0;
      this.publish(view);
      if (!view.moveVisible) this.onToast('没有其他收藏夹可移动');
    } catch (error) {
      if (this.moves.isCurrent(request) && this.isCurrent(selection)) this.onToast('收藏夹列表加载失败，请稍后重试');
    } finally {
      if (this.moves.isCurrent(request) && this.isCurrent(selection)) {
        const view: FavoriteEditState = this.view.copy();
        view.moveLoading = false;
        this.publish(view);
      }
    }
  }

  async deleteChecked(confirmed: FavoriteSelection | null = null): Promise<void> {
    const selection: FavoriteSelection | null = confirmed ?? this.selection();
    if (selection === null || !this.isCurrent(selection) || this.view.busy) return;
    if (selection.aids.length === 0) { this.onToast('请先选择视频'); return; }
    const request: number = this.beginAction();
    try {
      const result: ActionResult = await FavoriteApi.delFavoriteResources(selection.folderId, selection.aids);
      if (!this.actionCurrent(request, selection)) return;
      this.onToast(result.ok ? '已移除' : result.message);
      if (result.ok) this.removeSubmitted(selection.aids);
    } catch (error) {
      if (this.actionCurrent(request, selection)) this.onToast('网络异常，请稍后重试');
    } finally {
      this.finishAction(request, selection);
    }
  }

  async moveCheckedTo(target: FavoriteFolderItem): Promise<void> {
    const selection: FavoriteSelection | null = this.selection();
    if (selection === null || selection.aids.length === 0 || this.view.busy || target.id <= 0 || target.id === selection.folderId) return;
    const targetId: number = target.id;
    const targetTitle: string = target.title;
    this.closeMoveSheet();
    const request: number = this.beginAction();
    try {
      const result: ActionResult = await FavoriteApi.moveFavoriteResources(selection.folderId, targetId, selection.aids);
      if (!this.actionCurrent(request, selection)) return;
      this.onToast(result.ok ? '已移动到「' + targetTitle + '」' : result.message);
      if (result.ok) {
        this.removeSubmitted(selection.aids);
        // 移动不能丢弃其他视频尚未提交的排序草稿。
        if (!this.view.orderDirty) this.finishEditing();
      }
    } catch (error) {
      if (this.actionCurrent(request, selection)) this.onToast('网络异常，请稍后重试');
    } finally {
      this.finishAction(request, selection);
    }
  }

  private async saveOrder(): Promise<void> {
    const selection: FavoriteSelection | null = this.selection();
    if (selection === null || this.view.busy) return;
    const aids: Array<number> = this.videos.source.getAll().map((video: VideoItem) => video.aid);
    const request: number = this.beginAction();
    try {
      if (aids.length >= 2) {
        const result: ActionResult = await FavoriteApi.sortFavoriteVideos(selection.folderId, aids);
        if (!this.actionCurrent(request, selection)) return;
        if (!result.ok) { this.onToast(result.message); return; }
        this.onToast('视频排序已保存');
      }
      if (this.actionCurrent(request, selection)) this.finishEditing();
    } catch (error) {
      if (this.actionCurrent(request, selection)) this.onToast('排序保存失败，请重试');
    } finally {
      this.finishAction(request, selection);
    }
  }

  private beginAction(): number {
    this.videos.invalidate();
    const request: number = this.actions.next();
    const view: FavoriteEditState = this.view.copy();
    view.busy = true;
    this.publish(view);
    return request;
  }

  private actionCurrent(request: number, selection: FavoriteSelection): boolean {
    return this.actions.isCurrent(request) && this.isCurrent(selection);
  }

  private finishAction(request: number, selection: FavoriteSelection): void {
    if (!this.actions.isCurrent(request) || !this.session.current(selection.session)) return;
    const view: FavoriteEditState = this.view.copy();
    view.busy = false;
    this.publish(view);
  }

  private removeSubmitted(aids: Array<number>): void {
    this.videos.remove(aids);
    const view: FavoriteEditState = this.view.copy();
    view.checkedAids = view.checkedAids.filter((aid: number) => aids.indexOf(aid) < 0);
    this.publish(view);
  }

  private finishEditing(): void {
    this.edits.invalidate();
    this.moves.invalidate();
    const view: FavoriteEditState = new FavoriteEditState();
    view.busy = this.view.busy;
    this.publish(view);
    this.notifyRows();
  }

  private notifyRows(): void {
    for (let index: number = 0; index < this.videos.source.totalCount(); index++) this.videos.source.notifyItemChanged(index);
  }

  private publish(view: FavoriteEditState): void { this.view = view; this.onChange(); }
}
