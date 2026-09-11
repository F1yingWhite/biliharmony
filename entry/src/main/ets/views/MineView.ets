/**
 * 我的视图：B 站风格布局——顶部用户区（头像/昵称/Lv/签名 + 关注/粉丝/获赞）
 * + 圆角分组功能列表；功能逻辑（深色模式/沉浸光感/主题色/退出登录/关于）不变
 */
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common, bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { AppNavStack, NAV_FAVORITES, NAV_HISTORY, NAV_LOGIN, NAV_RELATION_LIST, NAV_USER_SPACE, NAV_WATCH_LATER,
  NAV_BANGUMI_LIST, NAV_BANGUMI_INDEX, NAV_BLACK_LIST,
  RelationListParam, UserSpaceParam } from '../common/AppRouter';
import { UserInfo, UserStat } from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { UserStore } from '../services/auth/UserStore';
import { AppTheme } from '../common/AppTheme';
import { Haptic } from '../common/Haptic';
import { LoadingView } from '../components/LoadingView';
import { formatCount } from '../common/Utils';
import { Immersive } from '../common/Immersive';
import { DecoratedAvatar } from '../components/UserDecorations';
import { UserApi } from '../api/UserApi';

/** NavRow 的按引用传参包裹类型：@Builder 按值参数不随状态刷新，必须传对象引用。 */
interface NavRowValue {
  value: string;
}

@Component
export struct MineView {
  @State loading: boolean = true;
  @State user: UserInfo = new UserInfo();
  @State stat: UserStat = new UserStat();
  @State autoDark: boolean = false;
  @State appVersion: string = '';
  /** 定时深色：每分钟应用一次，跨时刻后自动切换明暗（无需重启）。 */
  private autoTimer: number = -1;
  /** 定时深色时段编辑（TimePicker 抽屉）状态；以小时/分钟数字存储，跨组件直接赋值驱动刷新。 */
  @State showTimeEditor: boolean = false;
  @State startHour: number = 19;
  @State startMinute: number = 0;
  @State endHour: number = 7;
  @State endMinute: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('themeMode') themeMode: string = AppTheme.MODE_SYSTEM;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVer: number = 0;
  @StorageProp('userPendant') userPendant: string = '';

  aboutToDisappear(): void {
    if (this.autoTimer >= 0) {
      clearInterval(this.autoTimer);
      this.autoTimer = -1;
    }
  }

  onLoginChanged(): void {
    // 登录/登出广播：刷新用户信息（Tabs 保活，aboutToAppear 不会再触发）
    this.init().catch(() => {
    });
  }

  aboutToAppear(): void {
    this.loadAppVersion();
    this.autoDark = AppTheme.isAutoDarkEnabled();
    this.init().catch(() => {
    });
    if (this.autoTimer < 0) {
      this.autoTimer = setInterval(() => {
        AppTheme.applyAutoDark();
        this.syncAutoDark();
      }, 60 * 1000);
    }
  }

  private syncAutoDark(): void {
    this.autoDark = AppTheme.isAutoDarkEnabled();
  }

  private autoDarkLabel(): string {
    return AppTheme.getAutoDarkStart() + ' - ' + AppTheme.getAutoDarkEnd() + ' 自动深色';
  }

  private toggleTimeEditor(): void {
    this.showTimeEditor = !this.showTimeEditor;
    if (this.showTimeEditor) {
      this.parseHHMM(AppTheme.getAutoDarkStart(), true);
      this.parseHHMM(AppTheme.getAutoDarkEnd(), false);
    }
  }

  private parseHHMM(hhmm: string, isStart: boolean): void {
    const parts: Array<string> = hhmm.split(':');
    const h: number = parts.length > 0 ? Number(parts[0]) : (isStart ? 19 : 7);
    const m: number = parts.length > 1 ? Number(parts[1]) : 0;
    if (isStart) {
      this.startHour = Number.isNaN(h) ? 19 : h;
      this.startMinute = Number.isNaN(m) ? 0 : m;
    } else {
      this.endHour = Number.isNaN(h) ? 7 : h;
      this.endMinute = Number.isNaN(m) ? 0 : m;
    }
  }

  private static pad2(v: number): string {
    return v < 10 ? '0' + String(v) : String(v);
  }

  private formatHM(hour: number, minute: number): string {
    return MineView.pad2(hour) + ':' + MineView.pad2(minute);
  }

  private commitTimeEditor(): void {
    const s: string = this.formatHM(this.startHour, this.startMinute);
    const e: string = this.formatHM(this.endHour, this.endMinute);
    if (s === e) {
      this.getUIContext().getPromptAction().showToast({ message: '开始与结束时间不能相同' });
      return;
    }
    AppTheme.setAutoDarkWindow(s, e);
    AppTheme.applyAutoDark();
    this.showTimeEditor = false;
  }

  private async loadAppVersion(): Promise<void> {
    if (this.appVersion.length > 0) return;
    try {
      const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(0);
      this.appVersion = 'v' + info.versionName;
    } catch (e) {
      // 读取失败时省略版本，不能显示过期的硬编码版本号。
    }
  }

  async init(): Promise<void> {
    this.loading = true;
    try {
      const u: UserInfo = await UserStore.refresh();
      this.user = u;
      if (u.isLogin) {
        this.stat = await UserApi.getUserStat(u.mid);
      } else {
        this.stat = new UserStat();
      }
    } finally {
      this.loading = false;
    }
  }

  /** 分组容器底色：中性灰底（深色 #26272B / 浅色白），不跟随主题色派生——
   *  粉色种子派生的表面色在大面积分组上观感偏脏，与首页卡片中性底对齐。 */
  private groupBg(): string {
    return this.isDark ? '#26272B' : '#FFFFFF';
  }

  /** 行内主文字色：统一走 AppTheme 语义色，避免散落硬编码。 */
  private itemColor(): string {
    return AppTheme.onSurface();
  }

  private themeModeAt(index: number): string {
    if (index === 1) return AppTheme.MODE_LIGHT;
    if (index === 2) return AppTheme.MODE_DARK;
    return AppTheme.MODE_SYSTEM;
  }

  @Builder
  GroupDivider() {
    Divider()
      .strokeWidth(0.5)
      .color(this.isDark ? '#1FFFFFFF' : '#0F000000')
      .margin({ left: 48, right: 14 })
  }

  @Builder
  StatBlock(num: string, label: string, onTap: () => void) {
    Column({ space: 3 }) {
      Text(num)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Text(label)
        .fontSize(12)
        .fontColor('#9499A0')
    }
    .width('33.33%')
    .padding({ top: 4, bottom: 4 })
    .onClick(() => onTap())
  }

  /** 菜单行：图标 + 文案 + 右侧箭头（历史记录 / 我的收藏） */
  @Builder
  MenuRow(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 14 }) {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(this.isDark ? '#C6C7CB' : '#61666D')
      Text(label)
        .fontSize(15)
        .fontColor(this.itemColor())
      Blank()
      Image($r('app.media.ic_arrow_right'))
        .width(18)
        .height(18)
        .fillColor('#C1C2C5')
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      Haptic.light();
      onTap();
    })
  }

  /** 菜单行：文案 + 右侧值 + 箭头（关于） */
  @Builder
  NavRow(label: string, $$: NavRowValue, onTap: () => void) {
    Row({ space: 14 }) {
      Text(label)
        .fontSize(15)
        .fontColor(this.itemColor())
      Blank()
      Text($$.value)
        .fontSize(13)
        .fontColor('#9499A0')
      Image($r('app.media.ic_arrow_right'))
        .width(18)
        .height(18)
        .fillColor('#C1C2C5')
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      Haptic.light();
      onTap();
    })
  }

  /** 顶部用户区（无重渐变卡片，直接铺在页面氛围背景上） */
  @Builder
  UserHeader() {
    Column() {
      if (this.user.isLogin) {
        Row({ space: 14 }) {
          DecoratedAvatar({
            face: this.user.face,
            pendant: this.userPendant,
            avatarSize: 64,
            containerSize: 84,
            pendantScale: 1.38,
          })
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              Text(this.user.uname)
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
              Text('Lv' + this.user.level)
                .fontSize(10)
                .fontColor('#FFFFFF')
                .backgroundColor(this.accent)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(8)
            }
            Text(this.user.sign.length > 0 ? this.user.sign : '这个人很懒，什么都没有写')
              .fontSize(12)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Image($r('app.media.ic_arrow_right'))
            .width(20)
            .height(20)
            .fillColor('#C1C2C5')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          // 进入自己的用户空间页
          AppNavStack.pushPathByName(NAV_USER_SPACE, { mid: this.user.mid } as UserSpaceParam);
        })

        Row() {
          this.StatBlock(formatCount(this.stat.following), '关注', () => {
            const param: RelationListParam = { mid: this.user.mid, mode: 'following' };
            AppNavStack.pushPathByName(NAV_RELATION_LIST, param);
          })
          this.StatBlock(formatCount(this.stat.follower), '粉丝', () => {
            const param: RelationListParam = { mid: this.user.mid, mode: 'follower' };
            AppNavStack.pushPathByName(NAV_RELATION_LIST, param);
          })
          this.StatBlock(formatCount(this.stat.likeNum), '获赞', () => {
          })
        }
        .width('100%')
        .margin({ top: 18 })
      } else {
        Row({ space: 14 }) {
          Image($r('app.media.placeholder_avatar_noface'))
            .width(64)
            .height(64)
            .borderRadius(32)
            .objectFit(ImageFit.Cover)
            .clip(true)
          Column({ space: 6 }) {
            Text('点击登录')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            Text('登录后享受评论、收藏、动态等完整功能')
              .fontSize(12)
              .fontColor('#9499A0')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Image($r('app.media.ic_arrow_right'))
            .width(20)
            .height(20)
            .fillColor('#C1C2C5')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          AppNavStack.pushPathByName(NAV_LOGIN, null);
        })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
  }

  @Builder
  MenuList() {
    Column({ space: 12 }) {
      // ===== 组1：内容入口 =====
      Column() {
        this.MenuRow($r('app.media.ic_history'), '历史记录', () => {
          if (UserStore.isLogin) AppNavStack.pushPathByName(NAV_HISTORY, null);
          else AppNavStack.pushPathByName(NAV_LOGIN, null);
        })

        this.GroupDivider()

        this.MenuRow($r('app.media.ic_watch_later'), '稍后再看', () => {
          if (UserStore.isLogin) AppNavStack.pushPathByName(NAV_WATCH_LATER, null);
          else AppNavStack.pushPathByName(NAV_LOGIN, null);
        })

        this.GroupDivider()

        this.MenuRow($r('app.media.ic_favorite'), '我的收藏', () => {
          if (UserStore.isLogin) AppNavStack.pushPathByName(NAV_FAVORITES, null);
          else AppNavStack.pushPathByName(NAV_LOGIN, null);
        })

        this.GroupDivider()

        // 追番/追剧列表（需登录）
        this.MenuRow($r('app.media.bilix_logo_tv'), '我的追番', () => {
          if (UserStore.isLogin) AppNavStack.pushPathByName(NAV_BANGUMI_LIST, null);
          else AppNavStack.pushPathByName(NAV_LOGIN, null);
        })

        this.GroupDivider()

        // 番剧索引（无需登录的浏览聚合）
        this.MenuRow($r('app.media.ic_favorite'), '番剧索引', () => {
          AppNavStack.pushPathByName(NAV_BANGUMI_INDEX, null);
        })

        this.GroupDivider()

        // 黑名单（需登录）
        this.MenuRow($r('app.media.ic_dislike'), '黑名单', () => {
          if (UserStore.isLogin) AppNavStack.pushPathByName(NAV_BLACK_LIST, null);
          else AppNavStack.pushPathByName(NAV_LOGIN, null);
        })
      }
      .width('100%')
      .borderRadius(12)
      .backgroundColor(this.groupBg())
      .clip(true)

      // ===== 组2：外观 =====
      Column() {
        // 跟随系统 / 强制浅色 / 强制深色
        Row({ space: 14 }) {
          Text('显示模式')
            .fontSize(15)
            .fontColor(this.itemColor())
          Blank()
          Row({ space: 6 }) {
            ForEach(['跟随系统', '浅色', '深色'], (label: string, index: number) => {
              Text(label)
                .fontSize(12)
                .fontColor(this.themeMode === this.themeModeAt(index) ? '#FFFFFF' :
                  (this.isDark ? '#C8C8CC' : '#5A5F66'))
                .backgroundColor(this.themeMode === this.themeModeAt(index) ? this.accent :
                  (this.isDark ? '#3A3D44' : '#F0F1F3'))
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .borderRadius(16)
                .stateStyles({ pressed: { opacity: 0.9 } })
                .onClick(() => {
                  AppTheme.setMode(this.themeModeAt(index));
                })
            }, (label: string) => label)
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)

        this.GroupDivider()

        // 定时深色：跟随系统模式下按时间段自动切换明暗（跨午夜支持）。
        Row({ space: 14 }) {
          Column({ space: 2 }) {
            Text('定时深色')
              .fontSize(15)
              .fontColor(this.itemColor())
            Text(this.autoDarkLabel())
              .fontSize(10)
              .fontColor('#9499A0')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .onClick(() => {
            if (this.autoDark) this.toggleTimeEditor();
          })
          Toggle({ type: ToggleType.Switch, isOn: this.autoDark })
            .selectedColor(this.accent)
            .onChange((on: boolean) => {
              AppTheme.setAutoDarkEnabled(on);
              this.syncAutoDark();
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)

        this.GroupDivider()

        // 沉浸光感（设计规范 §3.2：性能可降级）
        Row({ space: 14 }) {
          Text('沉浸光感')
            .fontSize(15)
            .fontColor(this.itemColor())
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.glassOn })
            .selectedColor(this.accent)
            .onChange((on: boolean) => {
              AppTheme.setGlassEnabled(on);
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)

        this.GroupDivider()

        // 主题色（用户自选，色板右对齐紧凑排列）
        Row({ space: 14 }) {
          Text('主题色')
            .fontSize(15)
            .fontColor(this.itemColor())
          Blank()
          Row({ space: 4 }) {
            ForEach(AppTheme.PRESET_COLORS, (c: string) => {
              Stack({ alignContent: Alignment.Center }) {
                Circle()
                  .width(20)
                  .height(20)
                  .fill(c)
                if (c === this.accent) {
                  Circle()
                    .width(26)
                    .height(26)
                    .fill('#00000000')
                    .border({ width: 2, color: c, radius: 13 })
                }
              }
              .width(32)
              .height(36)
              .accessibilityText('主题色 ' + c + (c === this.accent ? '，已选中' : ''))
              .onClick(() => {
                AppTheme.setAccent(c);
              })
            }, (c: string) => c)
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .borderRadius(12)
      .backgroundColor(this.groupBg())
      .clip(true)

      // ===== 组3：关于 / 清空缓存 / 退出登录 =====
      Column() {
        this.NavRow('关于', { value: this.appVersion }, () => {
          this.getUIContext().getPromptAction().showDialog({
            title: 'BiliHaromny',
            message: '基于开源项目 PiliPlus 移植的鸿蒙原生哔哩哔哩第三方客户端（API 26）。\n支持沉浸式全屏、封面取色动态主题、环境光自适应。\n仅供学习交流使用。',
            buttons: [{ text: '知道了', color: this.accent }],
          });
        })

        this.GroupDivider()

        this.NavRow('清空缓存', { value: '点击查看' }, () => {
          this.confirmClearCache();
        })

        if (this.user.isLogin) {
          this.GroupDivider()

          Row() {
            Text('退出登录')
              .fontSize(15)
              .fontColor(AppTheme.DANGER)
          }
          .width('100%')
          .height(48)
          .padding({ left: 14, right: 14 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            UserStore.logout().catch(() => {
            }).finally(() => {
              this.user = new UserInfo();
              this.stat = new UserStat();
              this.getUIContext().getPromptAction().showToast({ message: '已退出登录' });
            });
          })
        }
      }
      .width('100%')
      .borderRadius(12)
      .backgroundColor(this.groupBg())
      .clip(true)
    }
    .width('100%')
  }

  /** 递归累加目录下所有文件的字节数（statSync 目录只给目录项大小，不等于内容总大小）。 */
  private dirSize(path: string): number {
    let total: number = 0;
    let entries: Array<string> = [];
    try {
      entries = fs.listFileSync(path);
    } catch (e) {
      return 0;
    }
    for (let i: number = 0; i < entries.length; i++) {
      const p: string = path + '/' + entries[i];
      try {
        const st: fs.Stat | null = fs.statSync(p);
        if (st === null) continue;
        total += st.isDirectory() ? this.dirSize(p) : st.size;
      } catch (e) {
        // 单个条目失败不影响整体统计
      }
    }
    return total;
  }

  /** 递归删除目录内容（文件 unlink，子目录递归后 rmdir），返回释放的字节数。 */
  private clearDir(path: string): number {
    let freed: number = 0;
    let entries: Array<string> = [];
    try {
      entries = fs.listFileSync(path);
    } catch (e) {
      return 0;
    }
    for (let i: number = 0; i < entries.length; i++) {
      const p: string = path + '/' + entries[i];
      try {
        const st: fs.Stat | null = fs.statSync(p);
        if (st === null) continue;
        if (st.isDirectory()) {
          freed += this.clearDir(p);
          fs.rmdirSync(p);
        } else {
          freed += st.size;
          fs.unlinkSync(p);
        }
      } catch (e) {
        // 单个条目删除失败不影响其余清理
      }
    }
    return freed;
  }

  private cacheDirPath(): string {
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return '';
    return context.cacheDir;
  }

  /** 用户点击缓存入口后才统计大小并展示确认弹窗。 */
  private confirmClearCache(): void {
    const dir: string = this.cacheDirPath();
    if (dir.length === 0) {
      this.toast('无法访问缓存目录');
      return;
    }
    const size: number = this.dirSize(dir);
    if (DEBUG) hilog.info(0x0000, 'BiliCache', 'cache size on demand: %{public}d bytes', size);
    this.getUIContext().getPromptAction().showDialog({
      title: '清空缓存',
      message: `将删除 ${this.formatBytes(size)} 的图片/弹幕等临时文件，不影响登录态。`,
      buttons: [
        { text: '取消', color: '#9499A0' },
        { text: '清空', color: this.accent },
      ],
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) this.clearCache();
    }).catch(() => {
      // 用户侧滑关闭弹窗，无需处理。
    });
  }

  /** 清空应用缓存目录（图片/弹幕等临时文件，含子目录），保留登录态。 */
  private clearCache(): void {
    const dir: string = this.cacheDirPath();
    if (dir.length === 0) {
      this.toast('无法访问缓存目录');
      return;
    }
    try {
      const freed: number = this.clearDir(dir);
      if (DEBUG) {
        hilog.info(0x0000, 'BiliCache', 'clearCache done: freed=%{public}d bytes from %{public}s', freed, dir);
      }
      this.toast(freed > 0 ? `已清空 ${this.formatBytes(freed)}` : '缓存已是空的');
    } catch (e) {
      // 目录清空失败忽略
    }
  }

  private formatBytes(v: number): string {
    if (v >= 1024 * 1024) return (v / (1024 * 1024)).toFixed(1) + 'MB';
    if (v >= 1024) return (v / 1024).toFixed(0) + 'KB';
    return String(v) + 'B';
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 窗口异常时忽略
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.loading) {
          LoadingView({ skeleton: 'settings', loading: true })
            .padding({ top: Immersive.statusBarHeight() + 56 })
        } else {
          List({ space: 12 }) {
            ListItem() {
              Column({ space: 12 }) {
                this.UserHeader()
                this.MenuList()
              }
              .width('100%')
            }
          }
          .width('100%')
          .height('100%')
          .contentStartOffset(Immersive.statusBarHeight() + 56)
          // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
          .contentEndOffset(Immersive.bottomInset() + 76)
          .padding({ left: 10, right: 10 })
          .scrollBar(BarState.Off)
          .onDidScroll((offset: number) => {
            AppTheme.updateHeaderFade(offset);
          })
        }
      }
      .width('100%')
      .height('100%')

      // 定时深色时段编辑抽屉：两个 TimePicker + 确认，半透明遮罩点击关闭。
      if (this.showTimeEditor) {
        Column() {
          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Text('开始时间').fontSize(14).fontColor(this.itemColor())
              TimePicker({ selected: this.makeStartDate() })
                .width('100%').height(160).useMilitaryTime(true)
                .selectedTextStyle({ color: this.accent, font: { size: 20 } })
                .backgroundColor(Color.Transparent)
                .onChange((value: TimePickerResult) => {
                  this.startHour = value.hour;
                  this.startMinute = value.minute;
                })
            }.layoutWeight(1)
            Column({ space: 6 }) {
              Text('结束时间').fontSize(14).fontColor(this.itemColor())
              TimePicker({ selected: this.makeEndDate() })
                .width('100%').height(160).useMilitaryTime(true)
                .selectedTextStyle({ color: this.accent, font: { size: 20 } })
                .backgroundColor(Color.Transparent)
                .onChange((value: TimePickerResult) => {
                  this.endHour = value.hour;
                  this.endMinute = value.minute;
                })
            }.layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 20 })
          Text('此时段内自动切换为深色（支持跨午夜）')
            .fontSize(11)
            .fontColor('#9499A0')
            .margin({ top: 4 })
          Row({ space: 12 }) {
            Text('取消')
              .fontSize(15)
              .fontColor('#9499A0')
              .padding({ left: 28, right: 28, top: 10, bottom: 10 })
              .borderRadius(18)
              .backgroundColor(this.isDark ? '#3A3D44' : '#F0F1F3')
              .onClick(() => {
                this.showTimeEditor = false;
              })
            Text('确定')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .padding({ left: 28, right: 28, top: 10, bottom: 10 })
              .borderRadius(18)
              .backgroundColor(this.accent)
              .onClick(() => {
                this.commitTimeEditor();
              })
          }
          .margin({ top: 12 })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
        // 底部 Dock（Tabs）高约 56vp：抽屉按钮必须整体抬到 Dock 之上，防被遮挡。
        .padding({ bottom: Immersive.bottomInset() + 74 })
        .backgroundColor(this.isDark ? '#26272B' : '#FFFFFF')
        .borderRadius({ topLeft: 16, topRight: 16 })
        .shadow({ radius: 24, color: '#33000000', offsetY: -4 })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.translate({ y: 120 }).animation({ duration: 180, curve: Curve.EaseOut }),
          TransitionEffect.translate({ y: 120 }).animation({ duration: 160, curve: Curve.EaseIn })))
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 构建 TimePicker 初始 Date（避开 @State Date 可变性，仅作组件初始值）。 */
  private makeStartDate(): Date {
    const d: Date = new Date();
    d.setHours(this.startHour, this.startMinute, 0, 0);
    return d;
  }

  private makeEndDate(): Date {
    const d: Date = new Date();
    d.setHours(this.endHour, this.endMinute, 0, 0);
    return d;
  }
}
