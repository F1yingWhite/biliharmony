/**
 * 网络与隐私设置：
 * - 代理：持久化 HTTP(S) 代理地址，下次冷启动生效（EntryAbility 启动时读取）；
 * - 隐私与数据：本地「不想看」黑名单管理、Cookie 罐导入导出入口说明。
 * 依赖方向：仅依赖 HttpClient / LocalVideoFilter / Preferences，不触碰 api 层。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { LocalVideoFilter } from '../common/LocalVideoFilter';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { AppTheme } from '../common/AppTheme';

export class NetworkSettingsStore {
  private static readonly PREFS_NAME: string = 'network_settings';
  private static readonly KEY_PROXY: string = 'proxyUrl';
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;

  static ensure(context: common.UIAbilityContext): Promise<void> {
    if (NetworkSettingsStore.ready !== null) return NetworkSettingsStore.ready;
    NetworkSettingsStore.ready = preferences.getPreferences(context, { name: NetworkSettingsStore.PREFS_NAME })
      .then((store: preferences.Preferences) => {
        NetworkSettingsStore.store = store;
      }).catch(() => {
      });
    return NetworkSettingsStore.ready;
  }

  /** 读取已保存的代理地址（空串 = 直连）；EntryAbility 冷启动时调用。 */
  static async loadProxy(context: common.UIAbilityContext): Promise<string> {
    await NetworkSettingsStore.ensure(context);
    return NetworkSettingsStore.store === null ? '' :
      NetworkSettingsStore.store.getSync(NetworkSettingsStore.KEY_PROXY, '') as string;
  }

  static async saveProxy(context: common.UIAbilityContext, value: string): Promise<void> {
    await NetworkSettingsStore.ensure(context);
    if (NetworkSettingsStore.store === null) return;
    NetworkSettingsStore.store.putSync(NetworkSettingsStore.KEY_PROXY, value);
    await NetworkSettingsStore.store.flush();
  }
}

@Component
export struct NetworkPrivacyPage {
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State proxyEnabled: boolean = false;
  @State proxyUrl: string = '';
  @State hiddenCount: number = 0;
  @State loaded: boolean = false;

  aboutToAppear(): void {
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return;
    NetworkSettingsStore.loadProxy(context).then(async (saved: string) => {
      this.proxyUrl = saved;
      this.proxyEnabled = saved.length > 0;
      await LocalVideoFilter.get().ensureLoaded();
      this.hiddenCount = LocalVideoFilter.count();
      this.loaded = true;
    }).catch(() => {
      this.loaded = true;
    });
  }

  private saveProxy(): void {
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return;
    const value: string = this.proxyEnabled ? this.proxyUrl.trim() : '';
    if (this.proxyEnabled && value.length === 0) return;
    NetworkSettingsStore.saveProxy(context, value).then(() => {
      this.toast(value.length > 0 ? '代理已保存，重启应用后生效' : '已恢复直连，重启应用后生效');
    }).catch(() => {
      this.toast('保存失败，请重试');
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // toast 失败忽略。
    }
  }

  private confirmClearHidden(): void {
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '清空本地「不想看」记录？清空后这些视频会重新出现。',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '清空', color: AppTheme.DANGER },
        ],
      }).then((result) => {
        if (Number(result.index) !== 1) return;
        LocalVideoFilter.clearAll().then(() => {
          this.hiddenCount = 0;
          this.toast('已清空');
        }).catch(() => this.toast('清空失败'));
      });
    } catch (e) {
      // 弹窗失败忽略。
    }
  }

  private surface(): string {
    return this.isDark ? '#26272B' : '#FFFFFF';
  }

  private titleColor(): string {
    return this.isDark ? '#F1F2F4' : '#18191C';
  }

  private subColor(): string {
    return this.isDark ? '#8A8F99' : '#9499A0';
  }

  build() {
    Column() {
      PageHeader({ title: '网络与隐私', showDivider: false })
      Scroll() {
        Column({ space: 12 }) {
          Column() {
            Row() {
              Column({ space: 3 }) {
                Text('HTTP 代理').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.titleColor())
                Text('仅代理 B 站 API 请求；更改在重启应用后生效')
                  .fontSize(11).fontColor(this.subColor())
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.proxyEnabled })
                .selectedColor(this.accent)
                .onChange((on: boolean) => {
                  this.proxyEnabled = on;
                  if (!on) {
                    this.saveProxy();
                  }
                })
            }
            .width('100%')
            if (this.proxyEnabled) {
              TextInput({ placeholder: 'http://127.0.0.1:7890', text: this.proxyUrl })
                .fontSize(13)
                .height(38)
                .width('100%')
                .margin({ top: 10 })
                .onChange((value: string) => this.proxyUrl = value)
              Button('保存')
                .fontSize(13)
                .backgroundColor(this.accent)
                .height(34)
                .width('100%')
                .margin({ top: 10 })
                .onClick(() => this.saveProxy())
            }
          }
          .padding(16)
          .width('100%')
          .borderRadius(18)
          .backgroundColor(this.surface())

          Column() {
            Row() {
              Column({ space: 3 }) {
                Text('本地「不想看」记录').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.titleColor())
                Text(this.hiddenCount > 0 ? '已隐藏 ' + String(this.hiddenCount) + ' 个视频（本地生效）' : '暂无隐藏记录')
                  .fontSize(11).fontColor(this.subColor())
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('清空')
                .fontSize(13)
                .fontColor(this.hiddenCount > 0 ? AppTheme.DANGER : this.subColor())
                .opacity(this.hiddenCount > 0 ? 1 : 0.5)
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .onClick(() => {
                  if (this.hiddenCount > 0) this.confirmClearHidden();
                })
            }
            .width('100%')
          }
          .padding(16)
          .width('100%')
          .borderRadius(18)
          .backgroundColor(this.surface())

          Text('隐私说明：SponsorBlock 查询仅上传视频哈希（SHA-256），不上传你的账号或完整视频 ID；日志不记录 Cookie 与请求地址。')
            .fontSize(11)
            .fontColor(this.subColor())
            .lineHeight(17)
            .padding({ left: 6, right: 6 })
            .width('100%')
        }
        .width('100%')
        .constraintSize({ maxWidth: 640 })
        .padding({ left: 18, right: 18, top: 12, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191F' : '#F3F4F8')
  }
}
