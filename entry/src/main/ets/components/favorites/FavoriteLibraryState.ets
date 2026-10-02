import { FavoriteFolderItem } from '../../model/library/LibraryModels';

export class FavoritePageState {
  page: number = 0;
  loading: boolean = false;
  hasMore: boolean = true;
  error: string = '';
  count: number = 0;

  copy(): FavoritePageState {
    const next: FavoritePageState = new FavoritePageState();
    next.page = this.page;
    next.loading = this.loading;
    next.hasMore = this.hasMore;
    next.error = this.error;
    next.count = this.count;
    return next;
  }
}

export class FavoriteEditState {
  editing: boolean = false;
  checkedAids: Array<number> = [];
  orderDirty: boolean = false;
  busy: boolean = false;
  moveLoading: boolean = false;
  moveVisible: boolean = false;
  moveTargets: Array<FavoriteFolderItem> = [];

  copy(): FavoriteEditState {
    const next: FavoriteEditState = new FavoriteEditState();
    next.editing = this.editing;
    next.checkedAids = this.checkedAids.slice();
    next.orderDirty = this.orderDirty;
    next.busy = this.busy;
    next.moveLoading = this.moveLoading;
    next.moveVisible = this.moveVisible;
    next.moveTargets = this.moveTargets;
    return next;
  }
}

export class FavoriteFolderDialogState {
  visible: boolean = false;
  isEdit: boolean = false;
  input: string = '';
  busy: boolean = false;
}

export class FavoriteLibraryView {
  category: number = 0;
  selected: FavoriteFolderItem = new FavoriteFolderItem();
  folders: FavoritePageState = new FavoritePageState();
  collections: FavoritePageState = new FavoritePageState();
  videos: FavoritePageState = new FavoritePageState();
  current: FavoritePageState = new FavoritePageState();
  edit: FavoriteEditState = new FavoriteEditState();
  dialog: FavoriteFolderDialogState = new FavoriteFolderDialogState();
}

/** 列表记录与编辑目标不能共享可写对象，尤其收藏集类型归一化不能修改根列表记录。 */
export function copyFavoriteFolder(folder: FavoriteFolderItem): FavoriteFolderItem {
  const copy: FavoriteFolderItem = new FavoriteFolderItem();
  copy.id = folder.id;
  copy.title = folder.title;
  copy.cover = folder.cover;
  copy.count = folder.count;
  copy.type = folder.type;
  copy.upperName = folder.upperName;
  copy.upperMid = folder.upperMid;
  copy.intro = folder.intro;
  copy.viewCount = folder.viewCount;
  copy.isPublic = folder.isPublic;
  copy.favorited = folder.favorited;
  return copy;
}
