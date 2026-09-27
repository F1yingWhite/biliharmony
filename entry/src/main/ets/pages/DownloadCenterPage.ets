/** 下载中心：持久化媒体下载队列的管理页。 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RequestEpoch } from '../common/RequestEpoch';
import { AppTheme } from '../common/AppTheme';
import { PageHeader } from '../components/PageHeader';
import { LoadingView } from '../components/LoadingView';
import { DownloadCenter, DownloadTaskItem, DOWNLOAD_STATUS_DONE, DOWNLOAD_STATUS_FAILED,
  DOWNLOAD_STATUS_INTERRUPTED, DOWNLOAD_STATUS_QUEUED, DOWNLOAD_STATUS_RUNNING } from '../services/media/DownloadCenter';

@Component
export struct DownloadCenterPage {
  @State preparing: boolean = true;
  @State visibleTasks: Array<DownloadTaskItem> = [];
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private prepareEpoch: RequestEpoch = new RequestEpoch();
  private destroyed: boolean = false;
  private refreshTimer: number = -1;
  private lastTaskSnapshot: string = '';

  aboutToAppear(): void {
    this.destroyed = false;
    this.prepare();
    this.refreshTasks();
    this.refreshTimer = setInterval(() => {
      const snapshot: string = this.taskSnapshot();
      if (snapshot === this.lastTaskSnapshot) return;
      this.refreshTasks();
    }, 1000);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.prepareEpoch.invalidate();
    if (this.refreshTimer >= 0) clearInterval(this.refreshTimer);
    this.refreshTimer = -1;
  }

  private taskSnapshot(): string {
    return DownloadCenter.list().map((task: DownloadTaskItem): string =>
      task.id + ':' + String(task.status) + ':' + String(task.progress)).join('|');
  }

  private refreshTasks(): void {
    this.lastTaskSnapshot = this.taskSnapshot();
    this.visibleTasks = DownloadCenter.list().slice();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // toast 失败不影响业务流程
    }
  }

  private prepare(): void {
    const epoch: number = this.prepareEpoch.next();
    this.preparing = true;
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.preparing = false;
      return;
    }
    DownloadCenter.init(context).then(() => {
      if (this.destroyed || !this.prepareEpoch.isCurrent(epoch)) return;
      this.preparing = false;
      this.refreshTasks();
    }).catch(() => {
      if (!this.destroyed) this.preparing = false;
    });
  }

  private bg(): string {
    return this.isDark ? '#18191C' : '#F5F6F7';
  }

  private cardBg(): string {
    return this.isDark ? '#26272B' : '#FFFFFF';
  }

  private titleColor(): string {
    return this.isDark ? '#F1F2F4' : '#18191C';
  }

  private subColor(): string {
    return this.isDark ? '#8A8F99' : '#9499A0';
  }

  private statusColor(item: DownloadTaskItem): string {
    if (item.status === DOWNLOAD_STATUS_DONE) return '#2FB96A';
    if (item.status === DOWNLOAD_STATUS_FAILED || item.status === DOWNLOAD_STATUS_INTERRUPTED) {
      return AppTheme.DANGER;
    }
    return this.accent;
  }

  private tasks(): Array<DownloadTaskItem> {
    return this.visibleTasks;
  }

  private confirm(title: string, action: () => void): void {
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: title,
        buttons: [
          { text: '取消', color: this.isDark ? '#E6E6E6' : '#18191C' },
          { text: '确定', color: AppTheme.DANGER },
        ],
      }).then((result) => {
        if (Number(result.index) === 1) action();
      });
    } catch (e) {
      action();
    }
  }

  private exportItem(item: DownloadTaskItem): void {
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined || item.filePath.length === 0) return;
    const picker2 = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [item.title + item.extension()];
    options.fileSuffixChoices = [item.kind === 1 ? '音频文件|.m4a' : '视频文件|.mp4'];
    picker2.save(options).then((targets: Array<string>) => {
      if (targets.length === 0 || this.destroyed) return;
      try {
        const target: fs.File = fs.openSync(targets[0],
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        const source: fs.File = fs.openSync(item.filePath, fs.OpenMode.READ_ONLY);
        try {
          fs.copyFileSync(source.fd, target.fd);
        } finally {
          fs.closeSync(target);
          fs.closeSync(source);
        }
        this.toast('已导出到所选位置');
      } catch (e) {
        this.toast('导出失败，请重试');
      }
    }).catch(() => {
      // 用户取消选择。
    });
  }

  private jumpItem(item: DownloadTaskItem): void {
    if (item.status !== DOWNLOAD_STATUS_DONE) return;
    this.exportItem(item);
  }

  @Builder
  TaskRow(item: DownloadTaskItem) {
    Row({ space: 12 }) {
      Stack() {
        Image(item.kind === 1 ? $r('app.media.ic_headphone') : $r('app.media.ic_play'))
          .width(18).height(18)
          .renderMode(ImageRenderMode.Template)
          .fillColor(this.accent)
      }
      .width(40).height(40)
      .alignContent(Alignment.Center)
      .borderRadius(10)
      .backgroundColor(this.isDark ? '#2C2D33' : '#F3F4F6')

      Column({ space: 4 }) {
        Text(item.title)
          .fontSize(14)
          .fontColor(this.titleColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          Text(item.qualityLabel.length > 0 ? item.qualityLabel : (item.kind === 1 ? '音频' : '视频'))
            .fontSize(11)
            .fontColor(this.subColor())
          Text(item.statusLabel())
            .fontSize(11)
            .fontColor(this.statusColor(item))
        }
        if (item.status === DOWNLOAD_STATUS_RUNNING && item.progress >= 0) {
          Progress({ value: item.progress, total: 100, type: ProgressType.Linear })
            .color(this.accent)
            .width('100%')
        }
        if (item.message.length > 0) {
          Text(item.message)
            .fontSize(11)
            .fontColor(this.subColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 6 }) {
        if (item.status === DOWNLOAD_STATUS_DONE) {
          this.ActionChip('导出', (): void => this.exportItem(item))
        }
        if (item.status === DOWNLOAD_STATUS_FAILED || item.status === DOWNLOAD_STATUS_INTERRUPTED) {
          this.ActionChip('重试', (): void => {
            DownloadCenter.retry(item.id).then(() => this.refreshTasks()).catch(() => this.toast('重试失败'));
          })
        }
        this.ActionChip('删除', (): void => {
          this.confirm('删除该下载任务？', (): void => {
            DownloadCenter.remove(item.id).then(() => this.refreshTasks()).catch(() => this.toast('删除失败'));
          });
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .borderRadius(14)
    .backgroundColor(this.cardBg())
  }

  @Builder
  ActionChip(label: string, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(label === '删除' ? AppTheme.DANGER : this.accent)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(12)
      .border({ width: 0.8, color: label === '删除' ? AppTheme.DANGER : this.accent })
      .onClick(() => onTap())
  }

  build() {
    Column() {
      PageHeader({ title: '下载中心' })

      if (this.preparing) {
        Column() {
          LoadingView()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Row() {
            Text(String(this.tasks().length) + ' 个任务')
              .fontSize(12)
              .fontColor(this.subColor())
            Blank()
            Text('清理已完成')
              .fontSize(12)
              .fontColor(AppTheme.DANGER)
              .onClick(() => {
                this.confirm('清理已完成/失败的任务记录？', (): void => {
                  DownloadCenter.clearFinished().then(() => this.refreshTasks())
                    .catch(() => this.toast('清理失败'));
                });
              })
          }
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 8 })

          List({ space: 10 }) {
            ForEach(this.tasks(), (item: DownloadTaskItem) => {
              ListItem() {
                this.TaskRow(item)
              }
            }, (item: DownloadTaskItem) => item.id + '_' + String(item.status) + '_' + String(item.progress))
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)

          if (this.tasks().length === 0) {
            Column({ space: 10 }) {
              Text('暂无下载任务')
                .fontSize(14)
                .fontColor(this.subColor())
              Text('在播放器「更多 → 下载」中选择「缓存到下载中心」即可离线保存')
                .fontSize(12)
                .fontColor(this.subColor())
                .opacity(0.8)
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bg())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
