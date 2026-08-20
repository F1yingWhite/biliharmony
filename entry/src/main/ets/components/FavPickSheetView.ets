/**
 * 收藏夹多选底部抽屉（视频详情页，长按收藏触发）：夹列表勾选 + 取消/保存。
 * 纯展示组件：夹数据、勾选集与保存逻辑（saveFavPick）都在详情页。
 */
import { FavoriteFolderItem } from '../model/Models';
import { Immersive } from '../common/Immersive';

@Component
export struct FavPickSheetView {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @Prop loading: boolean = false;
  @Prop folders: Array<FavoriteFolderItem> = [];
  @Prop checked: Array<number> = [];
  onToggle: (id: number) => void = () => {};
  onConfirm: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Column() {
      Blank()
      Column({ space: 10 }) {
        Text('选择收藏夹')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        if (this.loading) {
          Text('加载中…').fontSize(13).fontColor('#9499A0').padding(14)
        } else if (this.folders.length === 0) {
          Text('还没有收藏夹').fontSize(12).fontColor('#9499A0').padding(14)
        } else {
          List() {
            ForEach(this.folders, (f: FavoriteFolderItem) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text(f.title).fontSize(14)
                    .fontColor(this.isDark ? '#FFFFFF' : '#18191C').layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Stack({ alignContent: Alignment.Center }) {
                    Circle().width(18).height(18)
                      .fill(this.checked.indexOf(f.id) >= 0 ? this.accent : '#00000000')
                      .border({ width: 1.5, color: this.checked.indexOf(f.id) >= 0 ? this.accent : '#B4B6BA' })
                    if (this.checked.indexOf(f.id) >= 0) {
                      Text('✓').fontSize(11).fontColor('#FFFFFF')
                    }
                  }
                  .width(24).height(24)
                }
                .width('100%').padding({ top: 8, bottom: 8 })
                .onClick(() => this.onToggle(f.id))
              }
            }, (f: FavoriteFolderItem) => String(f.id))
          }
          .width('100%')
          .constraintSize({ maxHeight: 300 })
          .scrollBar(BarState.Off)
        }
        Row({ space: 10 }) {
          Text('取消').fontSize(14).fontColor('#9499A0')
            .layoutWeight(1).height(38).textAlign(TextAlign.Center)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F5F7F9').borderRadius(19)
            .onClick(() => this.onClose())
          Text('保存').fontSize(14).fontColor('#FFFFFF').backgroundColor(this.accent)
            .layoutWeight(1).height(38).textAlign(TextAlign.Center).borderRadius(19)
            .onClick(() => {
              this.onConfirm();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: Immersive.bottomInset() + 14 })
      .backgroundColor(this.isDark ? '#1E2024' : '#FFFFFF')
      .borderRadius({ topLeft: 14, topRight: 14 })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }
}
