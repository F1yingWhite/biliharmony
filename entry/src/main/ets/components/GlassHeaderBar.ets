/**
 * 玻璃头栏：左侧长搜索胶囊，右侧消息与头像圆形入口。
 * 随列表上滑逐渐淡出，消失进状态栏；仅本组件订阅滚动淡出值，避免列表重渲染。
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_LOGIN, NAV_MESSAGES, NAV_SEARCH } from '../common/AppRouter';
import { UserStore } from '../services/auth/UserStore';
import { AppTheme } from '../common/AppTheme';
import { HotSearchStore } from '../common/HotSearchStore';
import { Haptic } from '../common/Haptic';
import { MsgUnreadStore } from '../services/message/MsgUnreadStore';
import { DecoratedAvatar } from './UserDecorations';
import { GlassCapsuleSurface, ImmersiveEdgeMask } from './ImmersiveSurfaces';

/** 遮罩放在频道导航下方，让背景化开，文字与按钮保持清晰。 */
@Component
export struct HeaderBackdrop {
  @StorageProp('windowStatusBarHeight') statusBarInset: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;

  @StorageProp('headerFade') fade: number = 0;
  @Prop withChannels: boolean = true;

  build() {
    ImmersiveEdgeMask({
      maskHeight: this.statusBarInset + (this.withChannels ? 114 : 70) -
        (this.withChannels ? 54 : 26) * Math.min(1, Math.max(0, this.fade)),
      topEdge: true,
    })
  }
}

@Component
export struct GlassHeaderBar {
  @Prop backdropInContent: boolean = false;
  @StorageProp('windowStatusBarHeight') statusBarInset: number = 0;
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
  private destroyed: boolean = false;
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
    this.destroyed = false;
    HotSearchStore.load().then(() => {
      if (!this.destroyed) HotSearchStore.publish(0);
    }).catch(() => {
      // 热搜只是头栏占位文案，网络失败不应形成未处理的 Promise rejection。
    });
    // 未登录时 MsgUnreadStore 内部直接清零返回，不会发起请求。
    MsgUnreadStore.refresh().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private headerContentOpacity(): number {
    return 1 - Math.min(1, Math.max(0, this.fade / 0.65));
  }

  private openSearch(): void {
    Haptic.light();
    AppStorage.setOrCreate<string>('searchSuggestedKeyword', this.hotSearch);
    AppNavStack.pushPathByName(NAV_SEARCH, null);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.backdropInContent) {
        HeaderBackdrop({ withChannels: false })
      }
      Row({ space: 5 }) {
        Stack() {
          GlassCapsuleSurface({ surfaceHeight: 35 })
          Row({ space: 7 }) {
            Image($r('app.media.ic_search'))
              .width(18).height(18).renderMode(ImageRenderMode.Template)
              .fillColor(this.isDark ? '#C3C5CD' : '#777D82')
            Text(this.hotSearch.length > 0 ? this.hotSearch : '搜索')
              .fontSize(14).fontWeight(FontWeight.Normal)
              .fontColor(this.isDark ? '#C3C5CD' : '#777D82')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%').height('100%').padding({ left: 13, right: 13 })
          .hitTestBehavior(HitTestMode.None)
        }
        .height(35).layoutWeight(1).margin({ right: 5 })
        .opacity(this.headerContentOpacity())
        .translate({ y: -54 * this.fade })
        .hitTestBehavior(this.fade >= 0.65 ? HitTestMode.None : HitTestMode.Default)
        .accessibilityText('搜索：' + (this.hotSearch || '搜索'))
        .id('home-search-entry')
        .onClick(() => this.openSearch())

        Stack() {
          Image($r('app.media.ic_message'))
            .width(22).height(22).renderMode(ImageRenderMode.Template)
            .fillColor(this.accent)
          if (this.msgUnread > 0) {
            Text(this.msgUnread > 99 ? '99+' : String(this.msgUnread))
              .fontSize(9).fontColor('#FFFFFF').backgroundColor(AppTheme.DANGER)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 }).borderRadius(8)
              .position({ right: -2, top: -2 })
          }
        }
        .width(32).height(32).borderRadius(16)
        .backgroundColor(this.isDark ? '#34363C' : '#FFFFFF')
        .opacity(this.headerContentOpacity())
        .translate({ y: -54 * this.fade })
        .hitTestBehavior(this.fade >= 0.65 ? HitTestMode.None : HitTestMode.Default)
        .id('home-message-entry').accessibilityText('消息')
        .onClick(() => {
          Haptic.light();
          if (UserStore.isLogin) {
            AppNavStack.pushPathByName(NAV_MESSAGES, null);
          } else {
            this.getUIContext().getPromptAction().showToast({ message: '请先登录后查看私信' });
            AppNavStack.pushPathByName(NAV_LOGIN, null);
          }
        })

        // 与消息共用中线；收起后留在频道行右侧，继续提供个人页入口。
        Stack() {
          DecoratedAvatar({ face: this.userAvatar, pendant: this.userPendant,
            avatarSize: 26, containerSize: 32, pendantScale: 1.22 })
        }
        .width(32).height(32).borderRadius(16)
        .backgroundColor(this.isDark ? '#34363C' : '#FFFFFF')
        .translate({ y: -9 * this.fade })
        .accessibilityText('个人中心').id('home-avatar-entry')
        .onClick(() => { Haptic.light(); this.onAvatarTap(); })
      }
      .width('100%').height(35)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 20, right: 20 })
      .margin({ top: this.statusBarInset + 10 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%').height(this.statusBarInset + 46)
    .clip(false)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
