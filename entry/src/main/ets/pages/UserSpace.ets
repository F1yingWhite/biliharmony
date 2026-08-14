/**
 * 用户空间页（P3）：banner 氛围头部 + 资料卡 + 投稿 Tab（排序 chips + 双列流分页）
 * 入口：搜索用户卡片 / 视频详情 UP 主条
 */
import { promptAction } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_LOGIN, UserSpaceParam } from '../common/AppRouter';
import { VideoItem, UserSpaceInfo, UserStat, SpaceArcData } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { VideoCard } from '../components/VideoCard';
import { LoadingView } from '../components/LoadingView';
import { colorWithAlpha, formatCount } from '../common/Utils';
import { UserStore } from '../common/UserStore';
import { DecoratedAvatar } from '../components/UserDecorations';
import { DynamicView } from '../views/DynamicView';

// 投稿排序（order 参数）
const ARC_ORDERS: Array<Record<string, string>> = [
  { 'label': '最新发布', 'value': 'pubdate' },
  { 'label': '最多播放', 'value': 'click' },
  { 'label': '最多收藏', 'value': 'stow' },
];

@Component
export struct UserSpacePage {
  param: UserSpaceParam = { mid: 0 };
  @State info: UserSpaceInfo = new UserSpaceInfo();
  @State stat: UserStat = new UserStat();
  @State loading: boolean = true;
  @State errorText: string = '';
  // ===== 投稿 Tab =====
  @State videos: Array<VideoItem> = [];
  @State arcTotal: number = 0;
  @State arcPage: number = 1;
  @State arcOrder: string = 'pubdate';
  @State arcLoading: boolean = true;
  @State loadingMore: boolean = false;
  @State following: boolean = false;
  @State followLoading: boolean = false;
  @State spaceTab: number = 0;
  @State visualSpaceTab: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  private tabsController: TabsController = new TabsController();

  aboutToAppear(): void {
    this.init();
  }

  async init(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    const info: UserSpaceInfo | null = await BiliApi.getUserSpaceInfo(this.param.mid);
    if (info === null) {
      this.loading = false;
      this.errorText = '用户信息加载失败，请检查网络后重试';
      return;
    }
    this.info = info;
    this.loading = false;
    BiliApi.getUserStat(this.param.mid).then((stat: UserStat) => {
      this.stat = stat;
    });
    if (UserStore.isLogin) this.loadFollowState();
    this.loadArcs(true);
  }

  async loadFollowState(): Promise<void> {
    this.followLoading = true;
    const attribute: number | null = await BiliApi.getUserRelation(this.param.mid);
    if (attribute !== null) this.following = attribute === 2 || attribute === 6;
    this.followLoading = false;
  }

  async toggleFollow(): Promise<void> {
    if (!UserStore.isLogin) {
      promptAction.showToast({ message: '请先登录后再关注' });
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return;
    }
    if (UserStore.current !== null && UserStore.current.mid === this.param.mid) {
      promptAction.showToast({ message: '不能关注自己' });
      return;
    }
    if (this.followLoading) return;
    const previous: boolean = this.following;
    this.following = !previous;
    this.followLoading = true;
    const result: ActionResult = await BiliApi.modifyUserRelation(this.param.mid, this.following);
    this.followLoading = false;
    if (!result.ok) {
      this.following = previous;
      promptAction.showToast({ message: result.message });
    }
  }

  async loadArcs(reset: boolean): Promise<void> {
    if (reset) {
      this.arcPage = 1;
      this.arcLoading = true;
    }
    const pn: number = this.arcPage;
    const data: SpaceArcData = await BiliApi.getUserSpaceArcs(this.param.mid, pn, this.arcOrder);
    this.videos = reset ? data.videos : this.videos.concat(data.videos);
    this.arcTotal = data.total;
    this.arcPage = pn + 1;
    this.arcLoading = false;
  }

  hasMoreArcs(): boolean {
    return this.videos.length > 0 && this.videos.length < this.arcTotal;
  }

  onReachEnd(): void {
    if (this.loadingMore || this.arcLoading || !this.hasMoreArcs()) {
      return;
    }
    this.loadingMore = true;
    this.loadArcs(false).finally(() => {
      this.loadingMore = false;
    });
  }

  @Builder
  BackButton() {
    Row() {
      Image($r('app.media.ic_back'))
        .width(18)
        .height(18)
        .fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .borderRadius(17)
    .backgroundColor(this.glassOn ? '#66000000' : '#B3000000')
    .backdropBlur(this.glassOn ? 10 : 0)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      AppNavStack.pop();
    })
  }

  // ===== 头部氛围层：top_photo banner（无则主题色渐变）+ 头像/昵称/等级/认证/签名 =====
  @Builder
  Header() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // banner 背景
      if (this.info.topPhoto.length > 0) {
        Image(this.isDark && this.info.topPhotoDark.length > 0 ? this.info.topPhotoDark : this.info.topPhoto)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [[this.accent, 0.0], [colorWithAlpha(this.accent, '66'), 1.0]],
          })
      }
      // 底部压暗渐变，保证白字可读
      Column()
        .width('100%')
        .height('60%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#73000000', 1.0]],
        })

      // 资料行
      Row({ space: 12 }) {
        DecoratedAvatar({
          face: this.info.face,
          pendant: this.info.pendant,
          avatarSize: 64,
          containerSize: 86,
          pendantScale: 1.38,
          avatarBorderWidth: this.info.pendant.length > 0 ? 0 : 2,
          avatarBorderColor: '#CCFFFFFF',
        })
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(this.info.name)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 170 })
              .shadow({ radius: 3, color: '#59000000', offsetX: 0, offsetY: 1 })
            Text('Lv' + this.info.level)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor('#59FFFFFF')
              .borderRadius(3)
            if (this.info.sex === '男' || this.info.sex === '女') {
              Text(this.info.sex === '男' ? '♂' : '♀')
                .fontSize(12)
                .fontColor(this.info.sex === '男' ? '#7EC3F0' : '#FF9CC0')
            }
          }
          if (this.info.officialDesc.length > 0) {
            Text((this.info.officialType === 1 ? '机构认证：' : '个人认证：') + this.info.officialDesc)
              .fontSize(10)
              .fontColor('#F0C541')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.info.sign.length > 0 ? this.info.sign : '这个人很神秘，什么都没有写')
            .fontSize(11)
            .fontColor('#D9FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, bottom: 12 })
    }
    .width('100%')
    .height(Immersive.statusBarHeight() + 150)
  }

  // ===== 数据行：关注 | 粉丝 + 关注按钮（v1 展示态） =====
  @Builder
  StatRow() {
    Row({ space: 16 }) {
      Row({ space: 4 }) {
        Text(formatCount(this.stat.following))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('关注')
          .fontSize(12)
          .fontColor('#9499A0')
      }
      Row({ space: 4 }) {
        Text(formatCount(this.stat.follower))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('粉丝')
          .fontSize(12)
          .fontColor('#9499A0')
      }
      Blank()
      Text(this.followLoading ? '处理中…' : (this.following ? '已关注' : '+ 关注'))
        .fontSize(13)
        .fontColor(this.following ? (this.isDark ? '#D0D0D4' : '#61666D') : '#FFFFFF')
        .backgroundColor(this.following ? (this.isDark ? '#333438' : '#EEF0F2') : this.accent)
        .padding({ left: 18, right: 18, top: 6, bottom: 6 })
        .borderRadius(15)
        .onClick(() => {
          this.toggleFollow();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 投稿 Tab：排序 chips + 双列视频流 =====
  @Builder
  Chip(label: string, value: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.arcOrder === value ? '#FFFFFF' : (this.isDark ? '#C6C7CB' : '#61666D'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.arcOrder === value ? this.accent : (this.isDark ? '#2E3136' : '#ECEEF0'))
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(() => {
        if (this.arcOrder !== value) {
          this.arcOrder = value;
          this.loadArcs(true);
        }
      })
  }

  @Builder
  ArcTab() {
    Column() {
      // 排序 chips
      Row() {
        ForEach(ARC_ORDERS, (opt: Record<string, string>) => {
          this.Chip(opt['label'], opt['value'])
        }, (opt: Record<string, string>) => opt['value'])
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 2 })

      if (this.arcLoading && this.videos.length === 0) {
        LoadingView({ loading: true })
      } else if (this.videos.length === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: '暂无投稿视频',
          onRetry: () => {
            this.loadArcs(true);
          },
        })
      } else {
        List({ space: 10 }) {
          ForEach(this.videos, (item: VideoItem) => {
            ListItem() {
              VideoCard({ video: item })
            }
          }, (item: VideoItem) => item.bvid.length > 0 ? item.bvid : String(item.aid))
          ListItem() {
            Row() {
              if (this.loadingMore) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(this.accent)
              } else {
                Text(this.hasMoreArcs() ? '加载更多' : '—— 到底啦 ——')
                  .fontSize(12)
                  .fontColor(this.hasMoreArcs() ? this.accent : '#999999')
                  .onClick(() => {
                    this.onReachEnd();
                  })
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 8, bottom: 16 })
          }
        }
        .width('100%')
        .height('100%')
        .lanes(2, 10)
        .padding({ left: 10, right: 10, top: 6 })
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.onReachEnd();
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SpaceTabBar(label: string, index: number) {
    Column({ space: 3 }) {
      Row({ space: 6 }) {
        Text(label)
          .fontSize(15)
          .fontWeight(this.visualSpaceTab === index ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.visualSpaceTab === index ? this.accent : '#9499A0')
        if (index === 0 && this.arcTotal > 0) {
          Text(formatCount(this.arcTotal))
            .fontSize(11)
            .fontColor('#9499A0')
        }
      }
      Row()
        .width(20)
        .height(2.5)
        .borderRadius(1.5)
        .backgroundColor(this.visualSpaceTab === index ? this.accent : '#00000000')
    }
    .width('100%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.visualSpaceTab = index;
      this.tabsController.changeIndex(index);
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading) {
        Column() {
          LoadingView({ loading: true })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      } else if (this.errorText.length > 0) {
        Column() {
          LoadingView({
            loading: false,
            empty: false,
            errorText: this.errorText,
            onRetry: () => {
              this.init();
            },
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      } else {
        Column() {
          this.Header()
          this.StatRow()
          Tabs({ barPosition: BarPosition.Start, index: this.spaceTab, controller: this.tabsController }) {
            TabContent() {
              this.ArcTab()
            }
            .tabBar(this.SpaceTabBar('投稿', 0))
            TabContent() {
              DynamicView({ hostMid: this.param.mid, embedded: true })
            }
            .tabBar(this.SpaceTabBar('动态', 1))
          }
          .barHeight(40)
          .divider(null)
          .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
          .animationMode(AnimationMode.CONTENT_FIRST)
          .animationDuration(300)
          .animationCurve(Curve.EaseInOut)
          .onAnimationStart((index: number, targetIndex: number, extraInfo: TabsAnimationEvent) => {
            this.visualSpaceTab = targetIndex;
          })
          .onChange((index: number) => {
            this.spaceTab = index;
            this.visualSpaceTab = index;
          })
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      }

      // 悬浮返回键（banner 之上，浅色图标）
      Column() {
        this.BackButton()
      }
      .margin({ top: Immersive.statusBarHeight() + 8, left: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
