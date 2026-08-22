/** 登录用户的收藏夹。 */
import { AppTheme } from '../../common/AppTheme';
import { Immersive } from '../../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, NAV_FAV_SORT, FavSortParam, VideoDetailParam } from '../../common/AppRouter';
import { BiliApi, ActionResult } from '../../api/BiliApi';
import { FavoriteFolderItem, FavoriteVideoPageData, HistoryPageData, HistoryVideoItem, VideoItem, WatchLaterItem } from '../../model/Models';
import { UserStore } from '../../common/UserStore';
import { formatCount, formatDuration, formatRelativeTime } from '../../common/Utils';
import { LoadingView } from '../../components/LoadingView';
import { LoadMoreFooter } from '../../components/LoadMoreFooter';
import { PageHeader } from '../../components/PageHeader';
import { VideoRowCard } from '../../components/video/VideoRowCard';
import { BasicDataSource } from '../../common/BasicDataSource';
import { FavoriteApi } from '../../api/FavoriteApi';
import { HistoryApi } from '../../api/HistoryApi';

@Component
export struct FavoritesPage {
  @State selected: FavoriteFolderItem = new FavoriteFolderItem();
  @State category: number = 0; // 0 收藏夹 / 1 收藏集
  @State folderPage: number = 0;
  @State collectionPage: number = 0;
  @State videoPage: number = 0;
  @State hasMore: boolean = true;
  @State loading: boolean = false;
  @State videoLoading: boolean = false;
  @State collectionHasMore: boolean = true;
  @State collectionLoading: boolean = false;
  // ===== 收藏夹管理状态 =====
  @State editing: boolean = false;                 // 夹内视频编辑模式（多选 + 排序）
  @State checkedAids: Array<number> = [];          // 编辑模式勾选的视频 aid
  @State orderDirty: boolean = false;              // 排序是否有改动，退出编辑时提交
  @State folderDialogVisible: boolean = false;     // 新建/重命名弹窗
  @State folderDialogIsEdit: boolean = false;
  @State folderDialogInput: string = '';
  @State moveSheetVisible: boolean = false;        // 移动到目标收藏夹选择弹层
  @State moveTargets: Array<FavoriteFolderItem> = [];
  @State actionBusy: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private foldersSource: BasicDataSource<FavoriteFolderItem> = new BasicDataSource<FavoriteFolderItem>();
  private collectionsSource: BasicDataSource<FavoriteFolderItem> = new BasicDataSource<FavoriteFolderItem>();
  private videosSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  /** 收藏夹视频请求代际：切换/返回后，旧文件夹响应不得写入当前列表。 */
  private videoRequestGeneration: number = 0;
  /** 重命名目标收藏夹（保留 intro/公开状态，避免重命名时被重置） */
  private dialogFolder: FavoriteFolderItem = new FavoriteFolderItem();

  aboutToAppear(): void {
    this.initFavorites().catch(() => {
    });
  }

  async initFavorites(): Promise<void> {
    await UserStore.ensureLoaded();
    this.loadFolders(true).catch(() => {
    });
    this.loadCollections(true).catch(() => {
    });
  }

  async loadCollections(reset: boolean): Promise<void> {
    if (this.collectionLoading || (!reset && !this.collectionHasMore)) return;
    const user = UserStore.current;
    if (user === null) return;
    this.collectionLoading = true;
    try {
      const page: number = reset ? 1 : this.collectionPage + 1;
      const data = await FavoriteApi.getCollectedFolders(user.mid, page);
      if (reset) {
        this.collectionsSource.reset(data.folders);
      } else {
        this.collectionsSource.append(data.folders);
      }
      this.collectionPage = page;
      this.collectionHasMore = data.hasMore;
    } catch (e) {
    } finally {
      this.collectionLoading = false;
    }
  }

  async loadFolders(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    const user = UserStore.current;
    if (user === null) return;
    this.loading = true;
    try {
      const page: number = reset ? 1 : this.folderPage + 1;
      const data = await FavoriteApi.getFavoriteFolders(user.mid, page);
      if (reset) {
        this.foldersSource.reset(data.folders);
      } else {
        this.foldersSource.append(data.folders);
      }
      this.folderPage = page;
      this.hasMore = data.hasMore;
    } catch (e) {
    } finally {
      this.loading = false;
    }
  }

  async openFolder(folder: FavoriteFolderItem): Promise<void> {
    if (this.category === 1 && folder.type === 0) folder.type = 21;
    this.videoRequestGeneration++;
    this.selected = folder;
    this.videosSource.clear();
    this.videoPage = 0;
    this.hasMore = true;
    await this.loadVideos(true);
  }

  async loadVideos(reset: boolean): Promise<void> {
    if (this.selected.id === 0 || (!reset && (this.videoLoading || !this.hasMore))) return;
    const generation: number = this.videoRequestGeneration;
    const folderId: number = this.selected.id;
    const folderType: number = this.selected.type;
    this.videoLoading = true;
    try {
      const page: number = reset ? 1 : this.videoPage + 1;
      const data: FavoriteVideoPageData = folderType === 21 ?
        await FavoriteApi.getCollectionVideos(folderId, page) : await FavoriteApi.getFavoriteVideos(folderId, page);
      if (generation !== this.videoRequestGeneration || this.selected.id !== folderId) return;
      if (reset) {
        this.videosSource.reset(data.videos);
      } else {
        this.videosSource.append(data.videos);
      }
      this.videoPage = page;
      this.hasMore = data.hasMore;
    } catch (e) {
    } finally {
      if (generation === this.videoRequestGeneration) this.videoLoading = false;
    }
  }

  goBack(): void {
    if (this.editing) {
      this.editing = false;
      this.checkedAids = [];
      return;
    }
    if (this.selected.id > 0) {
      this.videoRequestGeneration++;
      this.videoLoading = false;
      this.selected = new FavoriteFolderItem();
      this.videosSource.clear();
      this.hasMore = this.folderPage > 0;
    } else {
      AppNavStack.pop();
    }
  }

  /** 统一 toast：用 UIContext 版 PromptAction，避开全局 promptAction 的废弃告警。 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // toast 失败不影响业务流程
    }
  }

  // ===== 收藏夹管理：新建 / 重命名 / 删除 =====
  private showFolderActions(folder: FavoriteFolderItem): void {
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: folder.title,
        buttons: [
          { text: '重命名', color: this.isDark ? '#E6E6E6' : '#18191C' },
          { text: '删除收藏夹', color: AppTheme.DANGER },
        ],
      }).then((result) => {
        if (result.index === 0) {
          this.openFolderDialog(true, folder);
        } else if (result.index === 1) {
          this.confirmDeleteFolder(folder);
        }
      });
    } catch (e) {
      // 弹窗失败不阻塞页面
    }
  }

  private openFolderDialog(isEdit: boolean, folder?: FavoriteFolderItem): void {
    this.folderDialogIsEdit = isEdit;
    if (isEdit && folder !== undefined) {
      this.dialogFolder = folder;
      this.folderDialogInput = folder.title;
    } else {
      this.dialogFolder = new FavoriteFolderItem();
      this.folderDialogInput = '';
    }
    this.folderDialogVisible = true;
  }

  private async submitFolderDialog(): Promise<void> {
    const title: string = this.folderDialogInput.trim();
    if (title.length === 0) {
      this.toast('收藏夹名称不能为空');
      return;
    }
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = this.folderDialogIsEdit ?
        await FavoriteApi.editFavoriteFolder(this.dialogFolder.id, title, this.dialogFolder.isPublic, this.dialogFolder.intro) :
        await FavoriteApi.addFavoriteFolder(title);
      this.toast(result.ok ? (this.folderDialogIsEdit ? '已重命名' : '已创建') : result.message);
      if (result.ok) {
        this.folderDialogVisible = false;
        this.loadFolders(true).catch(() => {
        });
      }
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  private confirmDeleteFolder(folder: FavoriteFolderItem): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除收藏夹「' + folder.title + '」',
        message: '夹内视频不会被删除，但收藏夹本身不可恢复。确定删除吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '删除', color: AppTheme.DANGER },
        ],
      }).then((dialogResult) => {
        if (dialogResult.index === 1) {
          this.deleteFolder(folder).catch(() => {
          });
        }
      });
    } catch (e) {
      // 弹窗失败不阻塞页面
    }
  }

  private async deleteFolder(folder: FavoriteFolderItem): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await FavoriteApi.delFavoriteFolder([folder.id]);
      this.toast(result.ok ? '已删除' : result.message);
      if (result.ok) {
        this.loadFolders(true).catch(() => {
        });
      }
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  // ===== 夹内视频编辑模式：多选删除 / 批量移动 / 排序 =====
  private toggleEdit(): void {
    if (this.editing && this.orderDirty) {
      // 退出编辑时提交排序（本地顺序已改，服务端同步）。
      this.saveVideoOrder().catch(() => {
      });
    }
    this.editing = !this.editing;
    this.checkedAids = [];
    this.orderDirty = false;
  }

  /** 编辑模式下上下调整视频顺序（只移动位置，不落库；退出时统一提交）。 */
  private moveVideo(index: number, delta: number): void {
    const all: Array<VideoItem> = this.videosSource.getAll();
    const target: number = index + delta;
    if (target < 0 || target >= all.length) return;
    const next: Array<VideoItem> = all.slice();
    const item: VideoItem = next.splice(index, 1)[0];
    next.splice(target, 0, item);
    this.videosSource.reset(next);
    this.orderDirty = true;
    this.drawVideos();
  }

  private drawVideos(): void {
    // reset 已广播变更：无需显式重绘；保留为空方法避免退化路径误用。
  }

  /** 提交收藏夹内视频排序：按当前列表顺序传 aid。 */
  private async saveVideoOrder(): Promise<void> {
    if (this.selected.id <= 0) return;
    const aids: Array<number> = this.videosSource.getAll().map((v: VideoItem) => v.aid);
    if (aids.length < 2) {
      this.orderDirty = false;
      return;
    }
    const result: ActionResult = await FavoriteApi.sortFavoriteVideos(this.selected.id, aids);
    if (result.ok) {
      this.toast('视频排序已保存');
    } else {
      this.toast(result.message);
    }
  }

  private isChecked(aid: number): boolean {
    return this.checkedAids.indexOf(aid) >= 0;
  }

  private toggleChecked(aid: number, index: number): void {
    if (this.isChecked(aid)) {
      this.checkedAids = this.checkedAids.filter((id: number) => id !== aid);
    } else {
      this.checkedAids = this.checkedAids.concat([aid]);
    }
    // @State 数组重赋值驱动底部操作条刷新；行本身通过 notifyItemChanged 重绑。
    this.videosSource.notifyItemChanged(index);
  }

  private confirmDeleteChecked(): void {
    if (this.checkedAids.length === 0) {
      this.toast('请先选择视频');
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '移除收藏',
        message: '将 ' + String(this.checkedAids.length) + ' 个视频从本收藏夹移除（不会取消其他收藏夹的收藏）。',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '移除', color: AppTheme.DANGER },
        ],
      }).then((dialogResult) => {
        if (dialogResult.index === 1) {
          this.deleteChecked().catch(() => {
          });
        }
      });
    } catch (e) {
      // 弹窗失败不阻塞页面
    }
  }

  private async deleteChecked(): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await FavoriteApi.delFavoriteResources(this.selected.id, this.checkedAids);
      this.toast(result.ok ? '已移除' : result.message);
      if (result.ok) this.removeCheckedLocally();
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  private async openMoveSheet(): Promise<void> {
    if (this.checkedAids.length === 0) {
      this.toast('请先选择视频');
      return;
    }
    const user = UserStore.current;
    if (user === null) return;
    try {
      const all: Array<FavoriteFolderItem> = await FavoriteApi.getAllFavoriteFolders(user.mid);
      this.moveTargets = all.filter((f: FavoriteFolderItem) => f.id !== this.selected.id);
      if (this.moveTargets.length === 0) {
        this.toast('没有其他收藏夹可移动');
        return;
      }
      this.moveSheetVisible = true;
    } catch (e) {
      this.toast('收藏夹列表加载失败，请稍后重试');
    }
  }

  private async moveCheckedTo(target: FavoriteFolderItem): Promise<void> {
    this.moveSheetVisible = false;
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await FavoriteApi.moveFavoriteResources(this.selected.id, target.id, this.checkedAids);
      this.toast(result.ok ? '已移动到「' + target.title + '」' : result.message);
      if (result.ok) {
        this.removeCheckedLocally();
        this.editing = false;
      }
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  /** 删除/移动成功后本地移除勾选项，避免整页重拉闪烁。 */
  private removeCheckedLocally(): void {
    this.videosSource.reset(this.videosSource.getAll().filter((v: VideoItem) => this.checkedAids.indexOf(v.aid) < 0));
    this.checkedAids = [];
  }

  /** 当前列表的分页加载入口（footer 点击与触底共用） */
  private loadMore(): void {
    if (this.selected.id > 0) {
      this.loadVideos(false).catch(() => {
      });
    } else if (this.category === 1) {
      this.loadCollections(false).catch(() => {
      });
    } else {
      this.loadFolders(false).catch(() => {
      });
    }
  }

  /** 收藏集 Tab 有自己的加载/到底状态，footer 需要按当前列表切换。 */
  private footerLoading(): boolean {
    if (this.selected.id > 0) return this.videoLoading;
    return this.category === 1 ? this.collectionLoading : this.loading;
  }

  private footerHasMore(): boolean {
    return this.selected.id === 0 && this.category === 1 ? this.collectionHasMore : this.hasMore;
  }

  @Builder
  FolderRow(item: FavoriteFolderItem) {
    Row({ space: 12 }) {
      Image(item.cover)
        .width(104)
        .height(68)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
      Column({ space: 7 }) {
        Row({ space: 6 }) {
          Text(item.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.type === 21) {
            Text('合集').fontSize(9).fontColor('#FFFFFF').backgroundColor(this.accent)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(4)
          }
        }
        Text(item.type === 21 ?
          ('创建者：' + item.upperName + ' · ' + formatCount(item.count) + ' 个视频 · ' + formatCount(item.viewCount) + ' 播放') :
          (formatCount(item.count) + ' 个内容' + (item.isPublic ? ' · 公开' : ' · 私密')))
          .fontSize(11)
          .fontColor('#9499A0')
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 自建收藏夹（收藏夹 Tab）提供管理入口；收藏集不管理
      if (this.category === 0 && this.selected.id === 0) {
        Image($r('app.media.ic_more'))
          .width(20)
          .height(20)
          .fillColor('#B4B6BA')
          .padding(6)
          .onClick(() => this.showFolderActions(item))
      } else {
        Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#B4B6BA')
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => this.openFolder(item))
  }

  @Builder
  FavHeaderActions() {
    // 收藏夹根列表提供「排序」入口；进入夹内则提供编辑
    if (this.selected.id === 0 && this.category === 0 && this.foldersSource.totalCount() > 1) {
      Text('排序')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => this.openFolderSort())
    } else if (this.selected.id > 0 && this.selected.type !== 21) {
      Text(this.editing ? '完成' : '编辑')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => this.toggleEdit())
    }
  }

  /** 打开收藏夹排序页（仅传自建收藏夹，默认收藏夹固定首位不参与）。 */
  private openFolderSort(): void {
    const sortable: Array<FavoriteFolderItem> =
      this.foldersSource.getAll().filter((f: FavoriteFolderItem) => f.type !== 0);
    if (sortable.length < 2) {
      this.toast('至少两个自建收藏夹才能排序');
      return;
    }
    const param: FavSortParam = { folders: sortable };
    AppNavStack.pushPathByName(NAV_FAV_SORT, param);
  }

  @Builder
  CheckCircle(checked: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(18)
        .height(18)
        .fill(checked ? this.accent : '#00000000')
        .border({ width: 1.5, color: checked ? this.accent : '#B4B6BA' })
      if (checked) {
        Text('✓')
          .fontSize(11)
          .fontColor('#FFFFFF')
      }
    }
    .width(26)
    .height(26)
  }

  /** 新建/重命名收藏夹弹窗（居中卡片 + 遮罩，点遮罩关闭）。 */
  @Builder
  FolderDialogOverlay() {
    Column() {
      Column({ space: 16 }) {
        Text(this.folderDialogIsEdit ? '重命名收藏夹' : '新建收藏夹')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        TextInput({ placeholder: '收藏夹名称', text: this.folderDialogInput })
          .fontSize(14)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .placeholderColor('#9499A0')
          .backgroundColor(this.isDark ? '#3A3D44' : '#F0F1F3')
          .maxLength(20)
          .onChange((value: string) => {
            this.folderDialogInput = value;
          })
        Row({ space: 12 }) {
          Text('取消')
            .layoutWeight(1)
            .height(40)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor('#9499A0')
            .backgroundColor(this.isDark ? '#3A3D44' : '#F0F1F3')
            .borderRadius(20)
            .onClick(() => {
              this.folderDialogVisible = false;
            })
          Text('确定')
            .layoutWeight(1)
            .height(40)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accent)
            .borderRadius(20)
            .onClick(() => {
              this.submitFolderDialog().catch(() => {
              });
            })
        }
        .width('100%')
      }
      .width('78%')
      .padding(18)
      .borderRadius(14)
      .backgroundColor(this.isDark ? '#2A2C31' : '#FFFFFF')
      .onClick(() => {
        // 吞掉卡片区域点击，避免触发遮罩关闭
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
    .onClick(() => {
      this.folderDialogVisible = false;
    })
  }

  /** 移动到目标收藏夹的底部选择弹层。 */
  @Builder
  MoveSheetOverlay() {
    Column() {
      Blank()
        .layoutWeight(1)
        .width('100%')
        .onClick(() => {
          this.moveSheetVisible = false;
        })
      Column() {
        Text('移动到…')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .padding({ top: 14, bottom: 8 })
        List() {
          ForEach(this.moveTargets, (folder: FavoriteFolderItem) => {
            ListItem() {
              Row() {
                Text(folder.title)
                  .fontSize(14)
                  .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(formatCount(folder.count) + ' 个内容')
                  .fontSize(12)
                  .fontColor('#9499A0')
              }
              .width('100%')
              .height(46)
              .padding({ left: 18, right: 18 })
              .onClick(() => {
                this.moveCheckedTo(folder).catch(() => {
                });
              })
            }
          }, (folder: FavoriteFolderItem) => String(folder.id))
        }
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ bottom: Immersive.bottomInset() + 8 })
      .backgroundColor(this.isDark ? '#2A2C31' : '#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: this.selected.id > 0 ? this.selected.title : '我的收藏',
          onBack: () => this.goBack(),
          trailing: (): void => {
            this.FavHeaderActions()
          },
        })
        if (this.selected.id === 0) {
          Row() {
            Text('收藏夹')
              .layoutWeight(1).height(42).textAlign(TextAlign.Center).fontSize(14)
              .fontWeight(this.category === 0 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.category === 0 ? this.accent : '#9499A0')
              .onClick(() => this.category = 0)
            Text('收藏集')
              .layoutWeight(1).height(42).textAlign(TextAlign.Center).fontSize(14)
              .fontWeight(this.category === 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.category === 1 ? this.accent : '#9499A0')
              .onClick(() => this.category = 1)
            // 收藏夹 Tab 顶部提供新建入口
            if (this.category === 0) {
              Text('＋新建')
                .fontSize(13)
                .fontColor(this.accent)
                .padding({ left: 10, right: 14, top: 6, bottom: 6 })
                .onClick(() => this.openFolderDialog(false))
            }
          }
          .width('100%')
          .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
        }
        if ((this.selected.id > 0 ? this.videoLoading : this.loading) &&
          this.foldersSource.isEmpty() && this.videosSource.isEmpty()) {
          LoadingView({ loading: true })
        } else {
          List() {
            if (this.selected.id === 0) {
              if (this.category === 0) {
                LazyForEach(this.foldersSource, (item: FavoriteFolderItem) => {
                  ListItem() { this.FolderRow(item) }
                }, (item: FavoriteFolderItem) => String(item.id))
              } else {
                LazyForEach(this.collectionsSource, (item: FavoriteFolderItem) => {
                  ListItem() { this.FolderRow(item) }
                }, (item: FavoriteFolderItem) => 'collection-' + String(item.id))
              }
            } else {
              LazyForEach(this.videosSource, (item: VideoItem, index: number) => {
                ListItem() {
                  Row({ space: 4 }) {
                    if (this.editing) {
                      this.CheckCircle(this.isChecked(item.aid))
                    }
                    VideoRowCard({
                      cover: item.cover,
                      title: item.title,
                      upName: item.upName,
                      extraText: formatCount(item.play) + ' 播放',
                      contentSpace: 7,
                      titleDarkColor: '#FFFFFF',
                      onTap: () => {
                        if (this.editing) {
                          this.toggleChecked(item.aid, index);
                          return;
                        }
                        const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
                        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                      },
                    })
                      .layoutWeight(1)
                    if (this.editing) {
                      Column({ space: 2 }) {
                        Text('↑')
                          .fontSize(14).fontColor(index === 0 ? '#B4B6BA' : this.accent)
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .onClick(() => this.moveVideo(index, -1))
                        Text('↓')
                          .fontSize(14).fontColor(index === this.videosSource.totalCount() - 1 ? '#B4B6BA' : this.accent)
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .onClick(() => this.moveVideo(index, 1))
                      }
                      .width(34)
                      .alignItems(HorizontalAlign.Center)
                    }
                  }
                  .width('100%')
                }
              }, (item: VideoItem) => item.bvid + String(item.aid))
            }
            ListItem() {
              LoadMoreFooter({
                loading: this.footerLoading(),
                hasMore: this.footerHasMore(),
                moreText: '继续加载',
                endText: this.selected.id === 0 && this.category === 1 ? '—— 收藏集到底啦 ——' : '—— 到底啦 ——',
                loadingText: '加载中…',
                accentLoadingText: true,
                padTop: 18,
                padBottom: 18,
                onLoadMore: () => this.loadMore(),
              })
            }
          }
          .layoutWeight(1)
          .padding({ left: 12, right: 12 })
          .cachedCount(5)
          .scrollBar(BarState.Off)
          .onReachEnd(() => this.loadMore())
        }
        // 编辑模式底部操作条：多选删除/移动 + 排序提示
        if (this.editing && this.selected.id > 0) {
          Row({ space: 12 }) {
            Text(this.checkedAids.length > 0 ? '已选 ' + String(this.checkedAids.length) + ' 项' : '↑↓ 调整顺序')
              .fontSize(13)
              .fontColor('#9499A0')
              .layoutWeight(1)
            Text('移动到…')
              .fontSize(14)
              .fontColor(this.checkedAids.length > 0 ? this.accent : '#B4B6BA')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick(() => {
                this.openMoveSheet().catch(() => {
                });
              })
            Text('删除')
              .fontSize(14)
              .fontColor(this.checkedAids.length > 0 ? AppTheme.DANGER : '#B4B6BA')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick(() => this.confirmDeleteChecked())
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: Immersive.bottomInset() })
          .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: Immersive.statusBarHeight() })

      if (this.folderDialogVisible) {
        this.FolderDialogOverlay()
      }
      if (this.moveSheetVisible) {
        this.MoveSheetOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
