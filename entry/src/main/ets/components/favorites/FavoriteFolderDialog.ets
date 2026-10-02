import { FavoriteFolderDialogState } from './FavoriteLibraryState';

@Component
export struct FavoriteFolderDialog {
  @Prop view: FavoriteFolderDialogState = new FavoriteFolderDialogState();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  onInput: (value: string) => void = (): void => {};
  onSubmit: () => void = (): void => {};
  onClose: () => void = (): void => {};

  build() {
    Column() {
      Column({ space: 16 }) {
        Text(this.view.isEdit ? '重命名收藏夹' : '新建收藏夹')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        TextInput({ placeholder: '收藏夹名称', text: this.view.input })
          .fontSize(14)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .placeholderColor('#9499A0')
          .backgroundColor(this.isDark ? '#3A3D44' : '#F0F1F3')
          .maxLength(20)
          .enabled(!this.view.busy)
          .onChange((value: string) => {
            this.onInput(value);
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
              if (!this.view.busy) this.onClose();
            })
          Text(this.view.busy ? '提交中…' : '确定')
            .layoutWeight(1)
            .height(40)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accent)
            .borderRadius(20)
            .onClick(() => {
              this.onSubmit();
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
      if (!this.view.busy) this.onClose();
    })
  }

}
