import { RequestEpoch } from '../../common/RequestEpoch';
import { AuthSession } from '../../services/auth/AuthSession';
import { FavoriteFolderItem } from '../../model/library/LibraryModels';
import { FavoriteLibrarySession } from './FavoriteLibrarySession';
import { FavoriteLibraryView } from './FavoriteLibraryState';
import { FavoriteFolderCatalog } from './FavoriteFolderCatalog';
import { FavoriteVideoList } from './FavoriteVideoList';
import { FavoriteVideoEditor } from './FavoriteVideoEditor';
import { FavoriteFolderEditor } from './FavoriteFolderEditor';

/** 收藏库导航与账号生命周期协调；各列表游标与编辑事务仍由所属领域持有。 */
export class FavoriteLibraryController {
  readonly session: FavoriteLibrarySession = new FavoriteLibrarySession();
  readonly folders: FavoriteFolderCatalog = new FavoriteFolderCatalog(this.session, false);
  readonly collections: FavoriteFolderCatalog = new FavoriteFolderCatalog(this.session, true);
  readonly videos: FavoriteVideoList = new FavoriteVideoList(this.session);
  readonly editor: FavoriteVideoEditor = new FavoriteVideoEditor(this.session, this.videos);
  readonly folderEditor: FavoriteFolderEditor = new FavoriteFolderEditor(this.session);
  view: FavoriteLibraryView = new FavoriteLibraryView();
  onChange: (view: FavoriteLibraryView) => void = (): void => {};
  onToast: (message: string) => void = (): void => {};
  private category: number = 0;
  private account: number = -1;
  private disposed: boolean = true;
  private activations: RequestEpoch = new RequestEpoch();

  constructor() {
    this.folders.onChange = (): void => this.publish();
    this.collections.onChange = (): void => this.publish();
    this.videos.onChange = (): void => this.publish();
    this.editor.onChange = (): void => this.publish();
    this.folderEditor.onChange = (): void => this.publish();
    this.editor.onToast = (message: string): void => this.onToast(message);
    this.folderEditor.onToast = (message: string): void => this.onToast(message);
    this.videos.canLoad = (): boolean => !this.editor.view.busy && !this.editor.view.orderDirty;
    this.folderEditor.onSaved = (deletedId: number): void => {
      if (deletedId > 0 && this.videos.selected.id === deletedId) {
        this.editor.reset();
        this.videos.clear();
      }
      this.folders.load(true).catch(() => {});
    };
  }

  async activate(): Promise<void> {
    this.disposed = false;
    const request: number = this.activations.next();
    if (this.account !== AuthSession.version) this.clearAccount();
    else {
      // 同账号重新进入也会建立新可见期；旧事务失效时必须同步解除其本地锁。
      this.editor.reset();
      this.folderEditor.reset();
      this.folders.invalidate();
      this.collections.invalidate();
      this.videos.invalidate();
    }
    try {
      const ready: boolean = await this.session.activate();
      if (this.disposed || !this.activations.isCurrent(request)) return;
      if (!ready) {
        if (this.account !== AuthSession.version) this.clearAccount();
        return;
      }
      this.account = AuthSession.version;
      await Promise.all([this.folders.load(true), this.collections.load(true),
        this.videos.selected.id > 0 ? this.videos.load(true) : Promise.resolve()]);
    } catch (error) {
      if (!this.disposed && this.activations.isCurrent(request)) this.onToast('收藏内容加载失败，请稍后重试');
    }
    if (!this.disposed && this.activations.isCurrent(request)) this.publish();
  }

  async accountChanged(): Promise<void> {
    if (!this.disposed) await this.activate();
  }

  dispose(): void {
    this.disposed = true;
    this.activations.invalidate();
    this.session.invalidate();
    this.folders.invalidate();
    this.collections.invalidate();
    this.videos.invalidate();
    this.editor.reset();
    this.folderEditor.reset();
  }

  setCategory(category: number): void {
    if (this.videos.selected.id > 0 || (category !== 0 && category !== 1)) return;
    this.category = category;
    this.publish();
  }

  async openFolder(folder: FavoriteFolderItem): Promise<void> {
    if (this.session.capture() === null || this.editor.view.busy || this.folderEditor.view.busy) return;
    this.editor.reset();
    await this.videos.open(folder, this.category === 1);
  }

  /** 返回 false 表示库内没有可关闭的上下文，此时由页面弹出导航。 */
  back(): boolean {
    if (this.editor.view.busy || this.folderEditor.view.busy) return true;
    if (this.folderEditor.view.visible) { this.folderEditor.close(); return true; }
    if (this.editor.view.moveVisible) { this.editor.closeMoveSheet(); return true; }
    if (this.editor.view.editing) { this.editor.toggleEdit().catch(() => {}); return true; }
    if (this.videos.selected.id > 0) {
      this.editor.reset();
      this.videos.clear();
      return true;
    }
    return false;
  }

  async loadMore(): Promise<void> {
    if (this.videos.selected.id > 0) await this.videos.load(false);
    else if (this.category === 1) await this.collections.load(false);
    else await this.folders.load(false);
  }

  async retry(): Promise<void> {
    const reset: boolean = this.view.current.count === 0;
    if (this.videos.selected.id > 0) await this.videos.load(reset);
    else if (this.category === 1) await this.collections.load(reset);
    else await this.folders.load(reset);
  }

  private clearAccount(): void {
    this.session.invalidate();
    this.category = 0;
    this.editor.reset();
    this.folderEditor.reset();
    this.folders.clear();
    this.collections.clear();
    this.videos.clear();
  }

  private publish(): void {
    if (this.disposed) return;
    const view: FavoriteLibraryView = new FavoriteLibraryView();
    view.category = this.category;
    view.selected = this.videos.selected;
    view.folders = this.folders.view;
    view.collections = this.collections.view;
    view.videos = this.videos.view;
    view.current = this.videos.selected.id > 0 ? this.videos.view :
      (this.category === 1 ? this.collections.view : this.folders.view);
    view.edit = this.editor.view;
    view.dialog = this.folderEditor.view;
    this.view = view;
    this.onChange(view);
  }
}
