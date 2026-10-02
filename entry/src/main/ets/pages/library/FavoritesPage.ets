/** 收藏库页面只组合列表、导航与系统确认框；请求/编辑事务由收藏领域控制器持有。 */
import { AppTheme } from '../../common/AppTheme';
import { Immersive } from '../../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, NAV_FAV_SORT, FavSortParam, VideoDetailParam } from '../../common/AppRouter';
import { FavoriteFolderItem } from '../../model/library/LibraryModels';
import { VideoItem } from '../../model/video/VideoModels';
import { formatCount } from '../../common/Utils';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { LoadingView } from '../../components/LoadingView';
import { LoadMoreFooter } from '../../components/LoadMoreFooter';
import { PageHeader } from '../../components/PageHeader';
import { VideoRowCard } from '../../components/video/VideoRowCard';
import { FavoriteLibraryController } from '../../components/favorites/FavoriteLibraryController';
import { FavoriteLibraryView, copyFavoriteFolder } from '../../components/favorites/FavoriteLibraryState';
import { FavoriteSessionToken } from '../../components/favorites/FavoriteLibrarySession';
import { FavoriteSelection } from '../../components/favorites/FavoriteVideoEditor';
import { FavoriteFolderDialog } from '../../components/favorites/FavoriteFolderDialog';
import { FavoriteMoveSheet } from '../../components/favorites/FavoriteMoveSheet';

@Component
export struct FavoritesPage {
  @State state: FavoriteLibraryView = new FavoriteLibraryView();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVersion: number = 0;
  private library: FavoriteLibraryController = new FavoriteLibraryController();

  aboutToAppear(): void {
    this.library.onChange = (view: FavoriteLibraryView): void => { this.state = view; };
    this.library.onToast = (message: string): void => this.toast(message);
    this.initFavorites().catch(() => {});
  }

  aboutToDisappear(): void { this.library.dispose(); }

  private onLoginChanged(): void { this.library.accountChanged().catch(() => {}); }

  async initFavorites(): Promise<void> { await this.library.activate(); }
  async loadFolders(reset: boolean): Promise<void> { await this.library.folders.load(reset); }
  async loadCollections(reset: boolean): Promise<void> { await this.library.collections.load(reset); }
  async loadVideos(reset: boolean): Promise<void> { await this.library.videos.load(reset); }
  async openFolder(folder: FavoriteFolderItem): Promise<void> { await this.library.openFolder(folder); }

  goBack(): void { if (!this.library.back()) AppNavStack.pop(); }

  private toast(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message }); } catch (error) {}
  }

  private showFolderActions(folder: FavoriteFolderItem): void {
    const session: FavoriteSessionToken | null = this.library.session.capture();
    if (session === null) return;
    const target: FavoriteFolderItem = copyFavoriteFolder(folder);
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: target.title,
        buttons: [
          { text: '重命名', color: this.isDark ? '#E6E6E6' : '#18191C' },
          { text: '删除收藏夹', color: AppTheme.DANGER },
        ],
      }).then((result) => {
        if (!this.library.session.current(session)) return;
        if (result.index === 0) this.library.folderEditor.open(true, target);
        else if (result.index === 1) this.confirmDeleteFolder(target);
      }).catch(() => {});
    } catch (error) {}
  }

  private confirmDeleteFolder(folder: FavoriteFolderItem): void {
    const session: FavoriteSessionToken | null = this.library.session.capture();
    if (session === null) return;
    const target: FavoriteFolderItem = copyFavoriteFolder(folder);
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除收藏夹「' + target.title + '」',
        message: '夹内视频不会被删除，但收藏夹本身不可恢复。确定删除吗？',
        buttons: [{ text: '取消', color: '#9499A0' }, { text: '删除', color: AppTheme.DANGER }],
      }).then((result) => {
        if (result.index === 1 && this.library.session.current(session)) this.library.folderEditor.delete(target).catch(() => {});
      }).catch(() => {});
    } catch (error) {}
  }

  private confirmDeleteChecked(): void {
    const selection: FavoriteSelection | null = this.library.editor.selection();
    if (selection === null || selection.aids.length === 0) { this.toast('请先选择视频'); return; }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '移除收藏',
        message: '将 ' + selection.aids.length + ' 个视频从本收藏夹移除（不会取消其他收藏夹的收藏）。',
        buttons: [{ text: '取消', color: '#9499A0' }, { text: '移除', color: AppTheme.DANGER }],
      }).then((result) => {
        if (result.index === 1 && this.library.editor.isCurrent(selection)) this.library.editor.deleteChecked(selection).catch(() => {});
      }).catch(() => {});
    } catch (error) {}
  }

  @Builder
  FolderRow(item: FavoriteFolderItem) {
    Row({ space: 12 }) {
      Image(biliImageThumbnail(item.cover, 320))
        .width(104)
        .height(68)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .alt($r('app.media.placeholder_cover'))
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
      if (this.state.category === 0 && this.state.selected.id === 0) {
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
    if (this.state.selected.id === 0 && this.state.category === 0 && this.library.folders.source.totalCount() > 1) {
      Text('排序')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => this.openFolderSort())
    } else if (this.state.selected.id > 0 && this.state.selected.type !== 21) {
      Text(this.state.edit.editing ? '完成' : '编辑')
        .fontSize(14)
        .fontColor(this.accent)
        .padding({ left: 12, right: 2, top: 6, bottom: 6 })
        .onClick(() => this.library.editor.toggleEdit())
    }
  }

  /** 打开收藏夹排序页（仅传自建收藏夹，默认收藏夹固定首位不参与）。 */
  private openFolderSort(): void {
    const sortable: Array<FavoriteFolderItem> =
      this.library.folders.source.getAll().filter((f: FavoriteFolderItem) => f.type !== 0);
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

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: this.state.selected.id > 0 ? this.state.selected.title : '我的收藏',
          onBack: () => this.goBack(),
          trailing: (): void => {
            this.FavHeaderActions()
          },
        })
        if (this.state.selected.id === 0) {
          Row() {
            Text('收藏夹')
              .layoutWeight(1).height(42).textAlign(TextAlign.Center).fontSize(14)
              .fontWeight(this.state.category === 0 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.state.category === 0 ? this.accent : '#9499A0')
              .onClick(() => this.library.setCategory(0))
            Text('收藏集')
              .layoutWeight(1).height(42).textAlign(TextAlign.Center).fontSize(14)
              .fontWeight(this.state.category === 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.state.category === 1 ? this.accent : '#9499A0')
              .onClick(() => this.library.setCategory(1))
            // 收藏夹 Tab 顶部提供新建入口
            if (this.state.category === 0) {
              Text('＋新建')
                .fontSize(13)
                .fontColor(this.accent)
                .padding({ left: 10, right: 14, top: 6, bottom: 6 })
                .onClick(() => this.library.folderEditor.open(false))
            }
          }
          .width('100%')
          .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
        }
        if (this.state.current.count === 0) {
          LoadingView({ skeleton: 'list', loading: this.state.current.loading,
            empty: !this.state.current.loading && this.state.current.error.length === 0,
            emptyText: this.state.selected.id > 0 ? '收藏夹里还没有视频' : (this.state.category === 1 ? '暂无收藏集' : '暂无收藏夹'),
            errorText: this.state.current.error, onRetry: () => this.library.retry() })
        } else {
          List() {
            if (this.state.selected.id === 0) {
              if (this.state.category === 0) {
                LazyForEach(this.library.folders.source, (item: FavoriteFolderItem) => {
                  ListItem() { this.FolderRow(item) }
                }, (item: FavoriteFolderItem) => String(item.id))
              } else {
                LazyForEach(this.library.collections.source, (item: FavoriteFolderItem) => {
                  ListItem() { this.FolderRow(item) }
                }, (item: FavoriteFolderItem) => 'collection-' + String(item.id))
              }
            } else {
              LazyForEach(this.library.videos.source, (item: VideoItem, index: number) => {
                ListItem() {
                  Row({ space: 4 }) {
                    if (this.state.edit.editing) {
                      this.CheckCircle(this.library.editor.isChecked(item.aid))
                    }
                    VideoRowCard({
                      cover: item.cover,
                      title: item.title,
                      upName: item.upName,
                      extraText: formatCount(item.play) + ' 播放',
                      contentSpace: 7,
                      titleDarkColor: '#FFFFFF',
                      onTap: () => {
                        if (this.state.edit.editing) {
                          this.library.editor.toggleChecked(item.aid, index);
                          return;
                        }
                        const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
                        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
                      },
                    })
                      .layoutWeight(1)
                    if (this.state.edit.editing) {
                      Column({ space: 2 }) {
                        Text('↑')
                          .fontSize(14).fontColor(index === 0 ? '#B4B6BA' : this.accent)
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .onClick(() => this.library.editor.moveVideo(index, -1))
                        Text('↓')
                          .fontSize(14).fontColor(index === this.library.videos.source.totalCount() - 1 ? '#B4B6BA' : this.accent)
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .onClick(() => this.library.editor.moveVideo(index, 1))
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
                loading: this.state.current.loading,
                hasMore: this.state.current.error.length > 0 || this.state.current.hasMore,
                moreText: this.state.current.error.length > 0 ? '加载失败 · 点击重试' : '继续加载',
                endText: this.state.selected.id === 0 && this.state.category === 1 ? '—— 收藏集到底啦 ——' : '—— 到底啦 ——',
                loadingText: '加载中…',
                accentLoadingText: true,
                padTop: 18,
                padBottom: 18,
                onLoadMore: () => this.state.current.error.length > 0 ? this.library.retry() : this.library.loadMore(),
              })
            }
          }
          .layoutWeight(1)
          .padding({ left: 12, right: 12 })
          .cachedCount(5)
          .scrollBar(BarState.Off)
          .onReachEnd(() => { if (this.state.current.error.length === 0) this.library.loadMore(); })
        }
        // 编辑模式底部操作条：多选删除/移动 + 排序提示
        if (this.state.edit.editing && this.state.selected.id > 0) {
          Row({ space: 12 }) {
            Text(this.state.edit.checkedAids.length > 0 ? '已选 ' + String(this.state.edit.checkedAids.length) + ' 项' : '↑↓ 调整顺序')
              .fontSize(13)
              .fontColor('#9499A0')
              .layoutWeight(1)
            Text('移动到…')
              .fontSize(14)
              .fontColor(this.state.edit.checkedAids.length > 0 ? this.accent : '#B4B6BA')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick(() => {
                this.library.editor.openMoveSheet().catch(() => {
                });
              })
            Text('删除')
              .fontSize(14)
              .fontColor(this.state.edit.checkedAids.length > 0 ? AppTheme.DANGER : '#B4B6BA')
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

      if (this.state.dialog.visible) {
        FavoriteFolderDialog({
          view: this.state.dialog,
          onInput: (value: string): void => this.library.folderEditor.setInput(value),
          onSubmit: (): void => { this.library.folderEditor.submit().catch(() => {}); },
          onClose: (): void => this.library.folderEditor.close(),
        })
      }
      if (this.state.edit.moveVisible) {
        FavoriteMoveSheet({
          targets: this.state.edit.moveTargets,
          onSelect: (folder: FavoriteFolderItem): void => { this.library.editor.moveCheckedTo(folder).catch(() => {}); },
          onClose: (): void => this.library.editor.closeMoveSheet(),
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
