import { DynDraftImage } from '../../common/DynImagePreparer';
import { DynamicComposerController, DynamicComposerState, DYNAMIC_MAX_IMAGES } from './DynamicComposerController';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { PhotoPickerHandoff } from '../../common/PhotoPickerHandoff';

/** 发布面板只处理控件与系统相册入口，草稿和事务由页面持有的控制器管理。 */
@Component
export struct DynamicComposer {
  controller: DynamicComposerController = new DynamicComposerController(() => {}, () => {});
  onClose: () => void = () => {};
  @State draft: DynamicComposerState = new DynamicComposerState();
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';

  aboutToAppear(): void {
    this.controller.attach((state: DynamicComposerState) => { this.draft = state; });
  }

  aboutToDisappear(): void { this.controller.detach(); }

  private pickImages(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) return;
    this.controller.pick(context, async (remaining: number): Promise<Array<string>> => {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: remaining,
      });
      return PhotoPickerHandoff.defer(result.photoUris);
    });
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('发布动态').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
        Text('取消').fontSize(13).fontColor('#9499A0')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .stateStyles({
            pressed: { opacity: 0.6 },
            normal: { opacity: 1 },
          })
          .onClick(() => this.onClose())
      }
      .width('100%')
      TextArea({ placeholder: '分享新鲜事…', text: this.draft.text })
        .width('100%')
        .height(150)
        .fontSize(15)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .placeholderColor('#9499A0')
        .backgroundColor(this.isDark ? '#26272B' : '#F3F4F6')
        .borderRadius(10)
        .enabled(!this.draft.busy)
        .onChange((value: string) => this.controller.setText(value))
      if (this.draft.images.length > 0 || !this.draft.busy) {
        // 图片九宫格：已选缩略图 + 末尾的添加块（满 9 张时隐藏）。
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.draft.images, (img: DynDraftImage) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              Image('file://' + img.cachePath)
                .width(72)
                .height(72)
                .borderRadius(8)
                .objectFit(ImageFit.Cover)
                .alt($r('app.media.placeholder_cover'))
              Text('×')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .textAlign(TextAlign.Center)
                .width(20)
                .height(20)
                .borderRadius(10)
                .backgroundColor('#99000000')
                .margin(3)
                .onClick(() => this.controller.removeImage(img.key))
            }
            .margin({ right: 8, bottom: 8 })
          }, (img: DynDraftImage) => img.key)
          if (this.draft.images.length < DYNAMIC_MAX_IMAGES && !this.draft.busy) {
            Column() {
              Text('+').fontSize(26).fontColor('#9499A0')
              Text(String(this.draft.images.length) + '/' + String(DYNAMIC_MAX_IMAGES))
                .fontSize(9)
                .fontColor('#B0B3B8')
                .margin({ top: 1 })
            }
            .width(72)
            .height(72)
            .borderRadius(8)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.isDark ? '#26272B' : '#F3F4F6')
            .margin({ right: 8, bottom: 8 })
            .stateStyles({
              pressed: { opacity: 0.6 },
              normal: { opacity: 1 },
            })
            .onClick(() => this.pickImages())
          }
        }
        .width('100%')
      }
      Text(this.draft.text.length + ' / 2000')
        .width('100%').fontSize(11).fontColor('#B0B3B8').textAlign(TextAlign.End)
      Button(this.draft.busy ? (this.draft.stage.length > 0 ? this.draft.stage : '发布中…') : '发布')
        .width('100%').height(42).borderRadius(21)
        .fontSize(15).fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .enabled(!this.draft.busy && (this.draft.text.trim().length > 0 || this.draft.images.length > 0))
        .onClick(() => this.controller.submit())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
  }

}
