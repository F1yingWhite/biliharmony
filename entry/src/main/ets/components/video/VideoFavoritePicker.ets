import { ActionResult } from '../../api/BiliApi';
import { FavoriteApi } from '../../api/FavoriteApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { FavoriteFolderItem } from '../../model/Models';
import { UserStore } from '../../services/auth/UserStore';

export class VideoFavoritePickerState {
  open: boolean = false;
  folders: Array<FavoriteFolderItem> = [];
  checked: Array<number> = [];
  loading: boolean = false;
  saving: boolean = false;
}

export interface VideoFavoritePickerAccess {
  isDestroyed: () => boolean;
  ensureLogin: () => boolean;
  getAid: () => number;
  isActionBusy: () => boolean;
  setActionBusy: (busy: boolean) => void;
  setFavorited: (favorited: boolean) => void;
  toast: (message: string) => void;
  publish: (state: VideoFavoritePickerState) => void;
}

/** 收藏夹多选的加载、选择与差集提交；页面只展示快照并转发用户操作。 */
export class VideoFavoritePicker {
  private readonly access: VideoFavoritePickerAccess;
  private state: VideoFavoritePickerState = new VideoFavoritePickerState();
  private loads: RequestEpoch = new RequestEpoch();
  private saves: RequestEpoch = new RequestEpoch();

  constructor(access: VideoFavoritePickerAccess) {
    this.access = access;
  }

  dispose(): void {
    this.loads.invalidate();
    this.saves.invalidate();
    this.state = new VideoFavoritePickerState();
  }

  /** 页面实例复用时清空上次抽屉；旧请求的完成不会影响新的选择。 */
  reset(): void {
    this.dispose();
    this.publish();
  }

  setOpen(open: boolean): void {
    if (this.access.isDestroyed() || this.state.saving) return;
    if (!open) {
      this.loads.invalidate();
      this.state = new VideoFavoritePickerState();
    }
    this.state.open = open;
    this.publish();
  }

  async open(): Promise<void> {
    if (this.access.isDestroyed() || this.state.saving || this.state.loading ||
      !this.access.ensureLogin() || this.access.isActionBusy()) return;
    const request: number = this.loads.next();
    this.state = new VideoFavoritePickerState();
    this.state.loading = true;
    this.state.open = true;
    this.publish();
    try {
      const selfMid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      const folders: Array<FavoriteFolderItem> = await FavoriteApi.getFavoriteFoldersForVideo(this.access.getAid(), selfMid);
      if (!this.isCurrent(request, this.loads)) return;
      this.state.folders = folders;
      this.state.checked = folders.filter((folder: FavoriteFolderItem) => folder.favorited)
        .map((folder: FavoriteFolderItem) => folder.id);
    } catch (e) {
      if (this.isCurrent(request, this.loads)) {
        this.state.open = false;
        this.access.toast('收藏夹加载失败，请稍后重试');
      }
    } finally {
      if (this.isCurrent(request, this.loads)) {
        this.state.loading = false;
        this.publish();
      }
    }
  }

  toggle(id: number): void {
    if (this.access.isDestroyed() || !this.state.open || this.state.loading || this.state.saving ||
      !this.state.folders.some((folder: FavoriteFolderItem) => folder.id === id)) return;
    this.state.checked = this.state.checked.indexOf(id) >= 0 ?
      this.state.checked.filter((checked: number) => checked !== id) : this.state.checked.concat([id]);
    this.publish();
  }

  async save(): Promise<void> {
    if (this.access.isDestroyed() || !this.state.open || this.state.loading || this.state.saving ||
      this.state.folders.length === 0 || this.access.isActionBusy() || !this.access.ensureLogin()) return;
    const checked: Array<number> = this.state.checked.slice();
    this.access.setActionBusy(true);
    this.state.saving = true;
    const request: number = this.saves.next();
    this.publish();
    try {
      const previous: Array<number> = this.state.folders.filter((folder: FavoriteFolderItem) => folder.favorited)
        .map((folder: FavoriteFolderItem) => folder.id);
      const keep: Array<number> = checked.filter((id: number) => previous.indexOf(id) < 0);
      const drop: Array<number> = previous.filter((id: number) => checked.indexOf(id) < 0);
      const result: ActionResult = await FavoriteApi.modifyVideoFavorite(this.access.getAid(), keep, drop);
      if (!this.isCurrent(request, this.saves)) return;
      if (!result.ok) {
        this.access.toast(result.message);
        return;
      }
      this.access.setFavorited(checked.length > 0);
      this.state.open = false;
      this.access.toast('收藏已更新');
    } catch (e) {
      if (this.isCurrent(request, this.saves)) this.access.toast('保存失败，请稍后重试');
    } finally {
      if (this.isCurrent(request, this.saves)) {
        this.state.saving = false;
        this.access.setActionBusy(false);
        this.publish();
      }
    }
  }

  private isCurrent(request: number, epoch: RequestEpoch): boolean {
    return !this.access.isDestroyed() && epoch.isCurrent(request);
  }

  private publish(): void {
    const snapshot: VideoFavoritePickerState = new VideoFavoritePickerState();
    snapshot.open = this.state.open;
    snapshot.folders = this.state.folders;
    snapshot.checked = this.state.checked;
    snapshot.loading = this.state.loading;
    snapshot.saving = this.state.saving;
    this.access.publish(snapshot);
  }
}
