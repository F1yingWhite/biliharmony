import { FavoriteFolderItem } from '../../model/library/LibraryModels';
import { Immersive } from '../../common/Immersive';
import { formatCount } from '../../common/Utils';

@Component
export struct FavoriteMoveSheet {
  @Prop targets: Array<FavoriteFolderItem> = [];
  @StorageProp('isDarkMode') isDark: boolean = false;
  onSelect: (folder: FavoriteFolderItem) => void = (): void => {};
  onClose: () => void = (): void => {};

  build() {
    Column() {
      Blank()
        .layoutWeight(1)
        .width('100%')
        .onClick(() => {
          this.onClose();
        })
      Column() {
        Text('移动到…')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .padding({ top: 14, bottom: 8 })
        List() {
          ForEach(this.targets, (folder: FavoriteFolderItem) => {
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
                this.onSelect(folder);
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

}
