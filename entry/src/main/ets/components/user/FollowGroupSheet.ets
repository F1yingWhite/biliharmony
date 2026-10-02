import { Immersive } from '../../common/Immersive';
import { FollowTagItem } from '../../model/user/UserModels';
import { FollowGroupState } from './FollowGroupController';

/** 关注分组表单；选择、草稿与提交归 FollowGroupController。 */
@Component
export struct FollowGroupSheet {
  @Prop state: FollowGroupState = new FollowGroupState();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  onRenameDraft: (value: string) => void = () => {};
  onNewName: (value: string) => void = () => {};
  onRename: () => void = () => {};
  onCancelRename: () => void = () => {};
  onToggle: (tagId: number) => void = () => {};
  onTagActions: (tag: FollowTagItem) => void = () => {};
  onCreate: () => void = () => {};
  onClose: () => void = () => {};
  onSave: () => void = () => {};
  onRetryLoad: () => void = () => {};

  build() {
    Column() {
      Blank()
      Column({ space: 10 }) {
        Text('关注分组')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('勾选分组（取消全部 = 默认分组）。')
          .fontSize(11).fontColor('#9499A0')
        if (this.state.loading) {
          Text('加载中…').fontSize(13).fontColor('#9499A0').padding(14)
        } else if (this.state.error.length > 0) {
          Text(this.state.error).fontSize(13).fontColor('#9499A0').padding(14)
          Text('重新加载').fontSize(13).fontColor(this.accent)
            .padding(10).onClick(() => this.onRetryLoad())
        } else {
          if (this.state.renameId > 0) {
            Row({ space: 8 }) {
              TextInput({ placeholder: '新的分组名称', text: this.state.renameDraft })
                .fontSize(13)
                .layoutWeight(1)
                .height(34)
                .enabled(!this.state.busy)
                .onChange((value: string) => this.onRenameDraft(value))
              Text(this.state.busy ? '处理中…' : '保存')
                .fontSize(13).fontColor(this.accent)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .enabled(!this.state.busy)
                .onClick(() => this.onRename())
              Text('取消')
                .fontSize(13).fontColor('#9499A0')
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .enabled(!this.state.busy)
                .onClick(() => this.onCancelRename())
            }
            .width('100%')
          }
          List() {
            ForEach(this.state.tags, (tag: FollowTagItem) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text(tag.name).fontSize(14)
                    .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
                    .layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(String(tag.count)).fontSize(11).fontColor('#9499A0')
                  Stack({ alignContent: Alignment.Center }) {
                    Circle()
                      .width(18).height(18)
                      .fill(this.state.checked.indexOf(tag.tagid) >= 0 ? this.accent : '#00000000')
                      .border({ width: 1.5, color: this.state.checked.indexOf(tag.tagid) >= 0 ? this.accent : '#B4B6BA' })
                    if (this.state.checked.indexOf(tag.tagid) >= 0) {
                      Text('✓').fontSize(11).fontColor('#FFFFFF')
                    }
                  }
                  .width(24).height(24)
                }
                .width('100%').padding({ top: 8, bottom: 8 })
                .enabled(!this.state.busy)
                .onClick(() => this.onToggle(tag.tagid))
                .gesture(LongPressGesture({ repeat: false })
                  .onAction(() => this.onTagActions(tag)))
              }
            }, (item: FollowTagItem) => String(item.tagid) + ':' + item.name + ':' + String(item.count))
          }
          .width('100%')
          .constraintSize({ maxHeight: 300 })
          .scrollBar(BarState.Off)
        }
        Row({ space: 8 }) {
          TextInput({ placeholder: '新建分组名称', text: this.state.newName })
            .fontSize(13)
            .layoutWeight(1)
            .height(34)
            .enabled(!this.state.loading && !this.state.busy && this.state.error.length === 0)
            .onChange((value: string) => this.onNewName(value))
          Text('新建')
            .fontSize(13).fontColor(this.accent)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .enabled(!this.state.loading && !this.state.busy && this.state.error.length === 0)
            .onClick(() => this.onCreate())
        }
        .width('100%')
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(14).fontColor('#9499A0')
            .layoutWeight(1).height(38).textAlign(TextAlign.Center)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F5F7F9').borderRadius(19)
            .onClick(() => this.onClose())
          Text(this.state.busy ? '处理中…' : '保存')
            .fontSize(14).fontColor('#FFFFFF').backgroundColor(this.accent)
            .layoutWeight(1).height(38).textAlign(TextAlign.Center)
            .borderRadius(19)
            .enabled(!this.state.loading && !this.state.busy && this.state.error.length === 0)
            .opacity(this.state.loading || this.state.busy || this.state.error.length > 0 ? 0.5 : 1)
            .onClick(() => this.onSave())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: Immersive.bottomInset() + 14 })
      .backgroundColor(this.isDark ? '#1E2024' : '#FFFFFF')
      .borderRadius({ topLeft: 14, topRight: 14 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }

}
