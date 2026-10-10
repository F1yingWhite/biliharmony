/** 下载中心：持久化媒体下载队列的管理页。 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RequestEpoch } from '../common/RequestEpoch';
import { AppTheme } from '../common/AppTheme';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { LoadingView } from '../components/LoadingView';
import { DownloadCenter, DownloadTaskItem, DOWNLOAD_STATUS_DONE, DOWNLOAD_STATUS_FAILED,
  DOWNLOAD_STATUS_INTERRUPTED, DOWNLOAD_STATUS_QUEUED, DOWNLOAD_STATUS_RUNNING } from '../services/media/DownloadCenter';
import { DOWNLOAD_STATUS_PAUSED, DOWNLOAD_STATUS_WAITING } from '../services/media/DownloadCenter';

@Component
export struct DownloadCenterPage {
  @State preparing: boolean = true;
  @State prepareError: string = '';
  @State visibleTasks: Array<DownloadTaskItem> = [];
  @State exportTaskId: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private prepareEpoch: RequestEpoch = new RequestEpoch();
  private destroyed: boolean = false;
  private refreshTimer: number = -1;
  private lastTaskSnapshot: string = '';
  private exportBusy: boolean = false;
  private exportGeneration: number = 0;

  aboutToAppear(): void {
    this.destroyed = false;
    this.exportGeneration++;
    if (!this.exportBusy) this.exportTaskId = '';
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
    this.exportGeneration++;
    this.prepareEpoch.invalidate();
    if (this.refreshTimer >= 0) clearInterval(this.refreshTimer);
    this.refreshTimer = -1;
  }

  private taskSnapshot(): string {
    return DownloadCenter.list().map((task: DownloadTaskItem): string =>
      task.id + ':' + String(task.status) + ':' + String(task.progress) + ':' +
      String(task.receivedBytes) + ':' + task.message).join('|');
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
    this.prepareError = '';
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.preparing = false;
      this.prepareError = '下载记录加载失败，请返回后重试';
      return;
    }
    DownloadCenter.onForeground(context).then(() => {
      if (this.destroyed || !this.prepareEpoch.isCurrent(epoch)) return;
      this.preparing = false;
      this.refreshTasks();
    }).catch(() => {
      if (this.destroyed || !this.prepareEpoch.isCurrent(epoch)) return;
      this.preparing = false;
      this.prepareError = '下载记录加载失败，请重试';
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
    if (this.exportBusy) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '确认删除',
        message: title,
        buttons: [
          { text: '取消', color: this.isDark ? '#E6E6E6' : '#18191C' },
          { text: '确定', color: AppTheme.DANGER },
        ],
      }).then((result) => {
        if (!this.destroyed && !this.exportBusy && Number(result.index) === 1) action();
      }).catch(() => {
        // 用户取消或确认窗口不可用时，不执行删除。
      });
    } catch (e) {
      if (!this.destroyed) this.toast('无法打开确认，请重试');
    }
  }

  private async exportItem(item: DownloadTaskItem): Promise<void> {
    if (this.destroyed || this.exportBusy || item.status !== DOWNLOAD_STATUS_DONE) return;
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined || item.filePath.length === 0) return;
    this.exportBusy = true;
    this.exportTaskId = item.id;
    const generation: number = this.exportGeneration;
    let copying: boolean = false;
    try {
      const picker2 = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [item.title + item.extension()];
      options.fileSuffixChoices = [item.kind === 1 ? '音频文件|.m4a' : '视频文件|.mp4'];
      const targets: Array<string> = await picker2.save(options);
      if (targets.length === 0 || this.destroyed || generation !== this.exportGeneration) return;
      copying = true;
      const source: fs.File = await fs.open(item.filePath, fs.OpenMode.READ_ONLY);
      try {
        const target: fs.File = await fs.open(targets[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          await fs.copyFile(source.fd, target.fd);
        } finally {
          await fs.close(target);
        }
      } finally {
        await fs.close(source);
      }
      if (!this.destroyed && generation === this.exportGeneration) this.toast('已导出到所选位置');
    } catch (e) {
      if (copying && !this.destroyed && generation === this.exportGeneration) this.toast('导出失败，请重试');
    } finally {
      this.exportBusy = false;
      if (!this.destroyed) this.exportTaskId = '';
    }
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
          this.ActionChip(this.exportTaskId === item.id ? '导出中…' : '导出', (): void => { void this.exportItem(item); })
        }
        if (item.status === DOWNLOAD_STATUS_PAUSED) {
          this.ActionChip('继续', (): void => {
            DownloadCenter.resume(item.id).then(() => this.refreshTasks()).catch(() => this.toast('恢复失败，可重试'));
          })
        }
        if (item.status === DOWNLOAD_STATUS_FAILED || item.status === DOWNLOAD_STATUS_INTERRUPTED ||
          item.status === DOWNLOAD_STATUS_PAUSED || item.status === DOWNLOAD_STATUS_WAITING) {
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
      .enabled(this.exportTaskId.length === 0)
      .opacity(this.exportTaskId.length > 0 ? 0.6 : 1)
      .onClick(() => { if (!this.exportBusy) onTap(); })
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
      } else if (this.prepareError.length > 0) {
        Column() {
          LoadingView({ loading: false, errorText: this.prepareError, onRetry: (): void => this.prepare() })
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
              .enabled(this.exportTaskId.length === 0)
              .onClick(() => {
                this.confirm('删除已完成、失败或中断的任务及本地下载文件？未导出的文件也会删除，已导出的副本不受影响。', (): void => {
                  DownloadCenter.clearFinished().then(() => this.refreshTasks())
                    .catch(() => this.toast('清理失败'));
                });
              })
          }
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 8 })

          if (this.tasks().length > 0) {
            List({ space: 10 }) {
              ForEach(this.tasks(), (item: DownloadTaskItem) => {
                ListItem() {
                  this.TaskRow(item)
                }
              }, (item: DownloadTaskItem) => item.id + '_' + String(item.status) + '_' +
                String(item.progress) + '_' + item.message)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          } else {
            Column({ space: 10 }) {
              Text('暂无下载任务')
                .fontSize(14)
                .fontColor(this.subColor())
              Text('在播放器「更多 → 下载」中选择「缓存到下载中心」即可离线保存')
                .fontSize(12)
                .fontColor(this.subColor())
                .opacity(0.8)
                .width('100%')
                .constraintSize({ maxWidth: 320 })
                .lineHeight(18)
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 24, right: 24 })
            .alignItems(HorizontalAlign.Center)
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
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.bg())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
