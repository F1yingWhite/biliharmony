/**
 * 我的视图：B 站风格布局——顶部用户区（头像/昵称/Lv/签名 + 关注/粉丝/获赞）
 * + 圆角分组功能列表；功能逻辑（深色模式/沉浸光感/强度/主题色/退出登录/关于）不变
 */
import { promptAction } from '@kit.ArkUI';
import { AppNavStack, NAV_FAVORITES, NAV_HISTORY, NAV_LOGIN, NAV_USER_SPACE, UserSpaceParam } from '../common/AppRouter';
import { UserInfo, UserStat } from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';
import { AppTheme } from '../common/AppTheme';
import { LoadingView } from '../components/LoadingView';
import { formatCount } from '../common/Utils';
import { Immersive } from '../common/Immersive';
import { DecoratedAvatar } from '../components/UserDecorations';

@Component
export struct MineView {
  @State loading: boolean = true;
  @State user: UserInfo = new UserInfo();
  @State stat: UserStat = new UserStat();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('themeMode') themeMode: string = AppTheme.MODE_SYSTEM;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('glassLevel') glassLevel: number = 1;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVer: number = 0;
  @StorageProp('userPendant') userPendant: string = '';

  onLoginChanged(): void {
    // 登录/登出广播：刷新用户信息（Tabs 保活，aboutToAppear 不会再触发）
    this.init().catch(() => {
    });
  }

  aboutToAppear(): void {
    this.init().catch(() => {
    });
  }

  async init(): Promise<void> {
    this.loading = true;
    try {
      const u: UserInfo = await UserStore.refresh();
      this.user = u;
      if (u.isLogin) {
        this.stat = await BiliApi.getUserStat(u.mid);
      } else {
        this.stat = new UserStat();
      }
    } finally {
      this.loading = false;
    }
  }

  /** 分组容器底色（浅色白底 / 深色 #2A2C31） */
  private groupBg(): string {
    return this.isDark ? '#2A2C31' : '#FFFFFF';
  }

  /** 行内主文字色 */
  private itemColor(): string {
    return this.isDark ? '#E6E6E6' : '#18191C';
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
  StatBlock(num: string, label: string) {
    Column({ space: 3 }) {
      Text(num)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Text(label)
        .fontSize(12)
        .fontColor('#9499A0')
    }
    .layoutWeight(1)
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
      onTap();
    })
  }

  /** 菜单行：文案 + 右侧值 + 箭头（关于） */
  @Builder
  NavRow(label: string, value: string, onTap: () => void) {
    Row({ space: 14 }) {
      Text(label)
        .fontSize(15)
        .fontColor(this.itemColor())
      Blank()
      Text(value)
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
          this.StatBlock(formatCount(this.stat.following), '关注')
          this.StatBlock(formatCount(this.stat.follower), '粉丝')
          this.StatBlock(formatCount(this.stat.likeNum), '获赞')
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

        this.MenuRow($r('app.media.ic_favorite'), '我的收藏', () => {
          if (UserStore.isLogin) AppNavStack.pushPathByName(NAV_FAVORITES, null);
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
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(14)
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

        // 材质强度三档（沉浸光感关闭时置灰）
        Row({ space: 14 }) {
          Text('材质强度')
            .fontSize(15)
            .fontColor(this.itemColor())
          Blank()
          Row({ space: 8 }) {
            ForEach(['弱', '标准', '强'], (label: string, index: number) => {
              Text(label)
                .fontSize(13)
                .fontColor(this.glassLevel === index ? '#FFFFFF' : (this.isDark ? '#C8C8CC' : '#5A5F66'))
                .backgroundColor(this.glassLevel === index ? this.accent : (this.isDark ? '#3A3D44' : '#F0F1F3'))
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(14)
                .onClick(() => {
                  if (this.glassOn) {
                    AppTheme.setGlassLevel(index);
                  }
                })
            }, (label: string) => label)
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)
        .opacity(this.glassOn ? 1 : 0.4)

        this.GroupDivider()

        // 主题色（用户自选，色板右对齐紧凑排列）
        Row({ space: 14 }) {
          Text('主题色')
            .fontSize(15)
            .fontColor(this.itemColor())
          Blank()
          Row({ space: 10 }) {
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
                    .border({ width: 2, color: c })
                }
              }
              .width(26)
              .height(26)
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

      // ===== 组3：关于 / 退出登录 =====
      Column() {
        this.NavRow('关于', 'v1.0.0', () => {
          promptAction.showDialog({
            title: 'BiliHaromny',
            message: '基于开源项目 PiliPlus 移植的鸿蒙原生哔哩哔哩第三方客户端（API 26）。\n支持沉浸式全屏、封面取色动态主题、环境光自适应。\n仅供学习交流使用。',
            buttons: [{ text: '知道了', color: this.accent }],
          });
        })

        if (this.user.isLogin) {
          this.GroupDivider()

          Row() {
            Text('退出登录')
              .fontSize(15)
              .fontColor('#FB4A4A')
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
              promptAction.showToast({ message: '已退出登录' });
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

  build() {
    Column() {
      if (this.loading) {
        LoadingView({ loading: true })
          .margin({ top: 80 })
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
        .contentEndOffset(Immersive.bottomInset() + 56)
        .padding({ left: 10, right: 10 })
        .scrollBar(BarState.Off)
        .onScroll((offset: number) => {
          AppTheme.updateHeaderFade(offset);
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
