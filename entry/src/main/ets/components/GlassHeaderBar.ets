/**
 * 玻璃拟态头栏（头像 + 搜索胶囊 + 消息入口），布局对齐 B 站官方首页
 * 随列表上滑逐渐淡出，消失进状态栏；仅本组件订阅滚动淡出值，避免列表重渲染。
 */
import { promptAction } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_LOGIN, NAV_MESSAGES, NAV_SEARCH } from '../common/AppRouter';
import { UserStore } from '../common/UserStore';
import { AppTheme } from '../common/AppTheme';
import { colorWithAlpha } from '../common/Utils';
import { HotSearchStore } from '../common/HotSearchStore';
import { DecoratedAvatar } from './UserDecorations';

@Component
export struct GlassHeaderBar {
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') @Watch('onThemeChanged') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('glassLevel') glassLevel: number = 1;
  // 头像单独放入 AppStorage，登录成功后可直接触发头栏刷新。
  @StorageProp('userAvatar') userAvatar: string = '';
  @StorageProp('userPendant') userPendant: string = '';
  // headerFade 每帧变化，只驱动 build 中的透明度；系统栏图标改由主题变化时设置（onThemeChanged）。
  @StorageProp('headerFade') fade: number = 0;
  @StorageProp('homeHotSearch') hotSearch: string = '';
  private hotTimer: number = -1;
  private hotIndex: number = 0;
  onAvatarTap: () => void = () => {
  };

  onThemeChanged(): void {
    // 状态栏图标深浅始终跟随主题（浅色模式→深色图标，深色模式→浅色图标），
    // 保证浮在玻璃光效上始终可读；仅明暗切换时设置，滚动不再逐帧触发。
    Immersive.setBarIcons(this.isDark, this.isDark);
  }

  aboutToAppear(): void {
    HotSearchStore.load().then(() => {
      HotSearchStore.publish(0);
    }).catch(() => {
      // 热搜只是头栏占位文案，网络失败不应形成未处理的 Promise rejection。
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

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部短模糊向搜索栏下方继续衰减；不再叠加一块等高的矩形材质，
      // 避免材质在搜索栏底边突然截止，看起来像一条分割线。
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
        // 展开和折叠状态都保持顶部浓、底部透明的纵向衰减。
        .opacity(1)
        .hitTestBehavior(HitTestMode.None)

      // L1 主题色低透明光晕，让浅色空白背景下也能看出光感层次。
      Column()
        .width('100%')
        .height(Immersive.statusBarHeight() + 68)
        .radialGradient({
          center: ['16%', '0%'],
          radius: '100%',
          colors: [[colorWithAlpha(this.accent, '38'), 0.0], ['#00000000', 1.0]],
        })
        .opacity(0.75 - 0.5 * this.fade)
        .hitTestBehavior(HitTestMode.None)

      // 可折叠的搜索/消息头栏。左侧留出头像位，头像本身由下方独立渲染。
      Row({ space: 12 }) {
        Row()
          .width(32)
          .height(32)

        Row({ space: 6 }) {
          Image($r('app.media.ic_search'))
            .width(16)
            .height(16)
            .fillColor(this.accent)
          Text(this.hotSearch.length > 0 ? this.hotSearch : '搜索你感兴趣的内容')
            .fontSize(13)
            .fontColor(this.isDark ? '#C8C8CC' : '#8A8A8E')
        }
        .height(32)
        .layoutWeight(1)
        .borderRadius(16)
        .backgroundColor(this.glassOn ? '#00000000' : (this.isDark ? '#3DFFFFFF' : '#66FFFFFF'))
        .systemMaterial(AppTheme.floatMaterial(this.glassOn, this.glassLevel))
        .border({ width: 0.5, color: this.isDark ? '#2EFFFFFF' : '#33FFFFFF' })
        .justifyContent(FlexAlign.Center)
        // Block 在当前系统版本会截断子 Text/Image 到父 Row 的点击冒泡。
        .hitTestBehavior(HitTestMode.Default)
        .onClick(() => {
          AppStorage.setOrCreate<string>('searchSuggestedKeyword', this.hotSearch);
          AppNavStack.pushPathByName(NAV_SEARCH, null);
        })

        Stack() {
          Image($r('app.media.ic_message'))
            .width(22)
            .height(22)
            .fillColor(this.isDark ? '#E6E6E6' : '#333333')
        }
        // 图形保持 22vp，实际触发区扩大为 40vp，避免只能点到图标笔画才生效。
        .width(40)
        .height(40)
        .onClick(() => {
          if (UserStore.isLogin) {
            AppNavStack.pushPathByName(NAV_MESSAGES, null);
          } else {
            promptAction.showToast({ message: '请先登录后查看私信' });
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
      .opacity(1 - this.fade)
      .hitTestBehavior(this.fade > 0.9 ? HitTestMode.None : HitTestMode.Default)

      // 头像不跟随头栏淡出：列表下滑到顶部后仍然可见、可点击。
      DecoratedAvatar({
        face: this.userAvatar,
        pendant: this.userPendant,
        avatarSize: 32,
        containerSize: 42,
        pendantScale: 1.38,
        avatarBorderWidth: 1,
        avatarBorderColor: this.isDark ? '#3DFFFFFF' : '#66FFFFFF',
      })
        .shadow({ radius: 6, color: this.isDark ? '#59000000' : '#1A000000', offsetX: 0, offsetY: 2 })
        .margin({ left: 7, top: Immersive.statusBarHeight() - 1 })
        .onClick(() => {
          this.onAvatarTap();
        })
    }
    .width('100%')
    .height(Immersive.statusBarHeight() + 44)
    .clip(false)
  }
}
