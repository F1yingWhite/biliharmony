/**
 * 收藏夹排序页：拖拽排序自建收藏夹（长按拖动或按钮上移/下移），保存后服务端生效。
 * 对齐 PiliPlus FavFolderSortPage；排序接口 /x/v3/fav/folder/sort 需登录 + appSign。
 */
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { BiliApi } from '../api/BiliApi';
import { ActionResult } from '../api/BiliApi';
import { FavoriteFolderItem } from '../model/Models';
import { formatCount } from '../common/Utils';
import { FavSortParam } from '../common/AppRouter';

@Component
export struct FavoriteFolderSortPage {
  /** LibraryPages 传入的自建文件夹列表（已去除默认收藏夹）。 */
  param: FavSortParam = { folders: [] };
  @State sort: Array<FavoriteFolderItem> = [];
  @State saving: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToAppear(): void {
    this.sort = this.param.folders.slice();
  }

  private move(index: number, delta: number): void {
    const target: number = index + delta;
    if (target < 0 || target >= this.sort.length) return;
    const next: Array<FavoriteFolderItem> = this.sort.slice();
    const item: FavoriteFolderItem = next.splice(index, 1)[0];
    next.splice(target, 0, item);
    this.sort = next;
  }

  private async save(): Promise<void> {
    if (this.saving) return;
    this.saving = true;
    try {
      const ids: Array<number> = this.sort.map((item: FavoriteFolderItem) => item.id);
      const result: ActionResult = await BiliApi.sortFavoriteFolders(ids);
      if (result.ok) {
        this.getUIContext().getPromptAction().showToast({ message: '排序已保存' });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
      }
    } finally {
      this.saving = false;
    }
  }

  @Builder
  Row2(item: FavoriteFolderItem, index: number) {
    Row({ space: 12 }) {
      Image(item.cover)
        .width(104)
        .height(68)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
      Column({ space: 6 }) {
        Text(item.title).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatCount(item.count) + ' 个内容' + (item.isPublic ? ' · 公开' : ' · 私密'))
          .fontSize(11).fontColor('#9499A0')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          // 上移（第一个禁用）
          Text('↑').fontSize(14).fontColor(index === 0 ? '#B4B6BA' : this.accent)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .onClick(() => this.move(index, -1))
          Text('↓').fontSize(14).fontColor(index === this.sort.length - 1 ? '#B4B6BA' : this.accent)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .onClick(() => this.move(index, 1))
        }
        Text(String(index + 1)).fontSize(10).fontColor('#B0B3B8')
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#303136' : '#ECEEF0' })
  }

  build() {
    Column() {
      PageHeader({ title: '收藏夹排序' })
      Text('点击 ↑↓ 调整显示顺序，保存后同步到账号')
        .fontSize(11).fontColor('#9499A0')
        .width('100%').padding({ left: 14, top: 8, bottom: 4 })
      List() {
        ForEach(this.sort, (item: FavoriteFolderItem, index: number) => {
          ListItem() { this.Row2(item, index) }
        }, (item: FavoriteFolderItem) => String(item.id))
      }
      .layoutWeight(1)
      .width('100%')
      .cachedCount(4)
      .scrollBar(BarState.Off)
      .onReachEnd(() => {
      })

      Button(this.saving ? '保存中…' : '保存排序')
        .width('86%').height(44).borderRadius(22)
        .fontSize(15).fontColor('#FFFFFF').backgroundColor(this.accent)
        .margin({ bottom: Immersive.bottomInset() + 16 })
        .onClick(() => this.save().catch(() => {
        }))
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}