/**
 * 玻璃拟态头栏（头像 + 搜索胶囊 + 消息入口），布局对齐 B 站官方首页
 * 随列表上滑逐渐淡出，消失进状态栏；仅本组件订阅滚动淡出值，避免列表重渲染。
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_LOGIN, NAV_MESSAGES, NAV_SEARCH } from '../common/AppRouter';
import { UserStore } from '../common/UserStore';
import { AppTheme } from '../common/AppTheme';
import { HotSearchStore } from '../common/HotSearchStore';
import { Haptic } from '../common/Haptic';
import { MsgUnreadStore } from '../common/MsgUnreadStore';
import { DecoratedAvatar } from './UserDecorations';

@Component
export struct GlassHeaderBar {
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') @Watch('onThemeChanged') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  // 头像单独放入 AppStorage，登录成功后可直接触发头栏刷新。
  @StorageProp('userAvatar') userAvatar: string = '';
  @StorageProp('userPendant') userPendant: string = '';
  // headerFade 每帧变化，只驱动 build 中的透明度；系统栏图标改由主题变化时设置（onThemeChanged）。
  @StorageProp('headerFade') fade: number = 0;
  @StorageProp('homeHotSearch') hotSearch: string = '';
  // 消息中心未读总数（回复/@/赞/系统），>0 时在消息入口右上角显示红色角标。
  @StorageProp('msgUnreadTotal') msgUnread: number = 0;
  private hotTimer: number = -1;
  private hotIndex: number = 0;
  onAvatarTap: () => void = () => {
  };

  onThemeChanged(): void {
    // 状态栏图标深浅始终跟随主题（浅色模式→深色图标，深色模式→浅色图标），
    // 保证浮在玻璃光效上始终可读；仅明暗切换时设置，滚动不再逐帧触发。
    // 头栏只在导航栈根页可见：栈顶有二级页（如黑底播放器）时跳过，避免把图标刷成深色。
    if (AppNavStack.getAllPathName().length > 0) {
      return;
    }
    Immersive.setBarIcons(this.isDark, this.isDark);
  }

  aboutToAppear(): void {
    HotSearchStore.load().then(() => {
      HotSearchStore.publish(0);
    }).catch(() => {
      // 热搜只是头栏占位文案，网络失败不应形成未处理的 Promise rejection。
    });
    // 未登录时 MsgUnreadStore 内部直接清零返回，不会发起请求。
    MsgUnreadStore.refresh().catch(() => {
    });
    this.hotTimer = setInterval(() => {
      this.hotIndex++;
      HotSearchStore.publish(this.hotIndex);
    }, 6500);
  }

  aboutToDisappear(): void {
    if (this.hotTimer >= 0) clearInterval(this.hotTimer);
    this.hotTimer = -1;
  }

  /** 头像图源：已登录用响应式缓存的 face，未登录用默认 noface。 */
  private avatarSource(): string | Resource {
    if (this.userAvatar.length > 0) {
      return this.userAvatar;
    }
    return $r('app.media.placeholder_avatar_noface');
  }

  private headerContentOpacity(): number {
    return Math.min(1, Math.max(0, (1 - this.fade) * 5));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部沉浸光感：状态栏处最强，向内容区连续衰减。只保留这一层纵向光感，
      // 不叠加主题色光晕、搜索栏边框或额外阴影。
      Column()
        .width('100%')
        .height(Immersive.statusBarHeight() + 68)
        .linearGradient({
          angle: 180,
          colors: this.isDark ?
            [['#B8141418', 0.0], ['#66141418', 0.5], ['#00141418', 1.0]] :
            [['#B8FFFFFF', 0.0], ['#66FFFFFF', 0.5], ['#00FFFFFF', 1.0]],
        })
        .linearGradientBlur(28, {
          fractionStops: [[1.0, 0.0], [0.5, 0.5], [0.0, 1.0]],
          direction: GradientDirection.Bottom,
        })
        .hitTestBehavior(HitTestMode.None)

      // 可折叠的搜索/消息头栏。左侧留出头像位，头像本身由下方独立渲染。
      Row({ space: 12 }) {
        Row()
          .width(32)
          .height(32)

        Search({
          value: '',
          placeholder: this.hotSearch.length > 0 ? this.hotSearch : '搜索你感兴趣的内容',
        })
        .height(32)
        .layoutWeight(1)
        .borderRadius(16)
        .searchIcon({ size: 16, color: this.accent, src: $r('app.media.ic_search') })
        .cancelButton({ style: CancelButtonStyle.INVISIBLE })
        .placeholderColor(this.isDark ? '#D6D6DA' : '#62666D')
        .textFont({ size: 13 })
        .textAlign(TextAlign.Center)
        .enableKeyboardOnFocus(false)
        .focusable(false)
        .focusOnTouch(false)
        // 使用原生 Search 进入系统搜索控件的材质路径；不叠背景、边框、阴影或模糊。
        .systemMaterial(this.fade < 0.98 ? AppTheme.floatMaterial(this.glassOn) : undefined)
        .opacity(this.headerContentOpacity())
        .hitTestBehavior(HitTestMode.Default)
        .onClick(() => {
          Haptic.light();
          AppStorage.setOrCreate<string>('searchSuggestedKeyword', this.hotSearch);
          AppNavStack.pushPathByName(NAV_SEARCH, null);
        })

        Stack({ alignContent: Alignment.TopEnd }) {
          Image($r('app.media.ic_message'))
            .width(22)
            .height(22)
            .fillColor(this.isDark ? '#E6E6E6' : '#333333')
            .margin({ top: 9 })
          if (this.msgUnread > 0) {
            Text(this.msgUnread > 99 ? '99+' : String(this.msgUnread))
              .fontSize(9).fontColor('#FFFFFF').backgroundColor(AppTheme.DANGER)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 }).borderRadius(8)
              .translate({ x: 10, y: 2 })
          }
        }
        // 图形保持 22vp，实际触发区扩大为 40vp，避免只能点到图标笔画才生效。
        .width(40)
        .height(40)
        .opacity(this.headerContentOpacity())
        .onClick(() => {
          Haptic.light();
          if (UserStore.isLogin) {
            AppNavStack.pushPathByName(NAV_MESSAGES, null);
          } else {
            this.getUIContext().getPromptAction().showToast({ message: '请先登录后查看私信' });
            AppNavStack.pushPathByName(NAV_LOGIN, null);
          }
        })
      }
      .width('100%')
      .padding({
        left: 12,
        right: 12,
        top: Immersive.statusBarHeight() + 4,
        bottom: 8,
      })
      .hitTestBehavior(this.fade > 0.98 ? HitTestMode.None : HitTestMode.Default)

      // 头像不跟随头栏淡出：列表下滑到顶部后仍然可见、可点击。
      DecoratedAvatar({
        face: this.userAvatar,
        pendant: this.userPendant,
        avatarSize: 32,
        containerSize: 42,
        pendantScale: 1.38,
      })
        .margin({ left: 7, top: Immersive.statusBarHeight() - 1 })
        .onClick(() => {
          Haptic.light();
          this.onAvatarTap();
        })
    }
    .width('100%')
    .height(Immersive.statusBarHeight() + 44)
    .clip(false)
  }
}
