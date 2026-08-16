/**
 * 用户空间页（P3）：banner 氛围头部 + 资料卡 + 投稿 Tab（排序 chips + 双列流分页）
 * 入口：搜索用户卡片 / 视频详情 UP 主条
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, ImageViewerParam, LiveRoomParam, NAV_IMAGE_VIEWER, NAV_LIVE_ROOM, NAV_LOGIN,
  NAV_RELATION_LIST, NAV_SEARCH, RelationListParam, UserSpaceParam } from '../common/AppRouter';
import { VideoItem, UserSpaceHeaderItem, UserSpaceInfo, UserStat, SpaceArcData, FollowTagItem } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { VideoCard } from '../components/VideoCard';
import { LoadingView } from '../components/LoadingView';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { FilterChip } from '../components/FilterChip';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { colorWithAlpha, formatCount } from '../common/Utils';
import { UserStore } from '../common/UserStore';
import { BasicDataSource } from '../common/BasicDataSource';
import { DecoratedAvatar } from '../components/UserDecorations';
import { DynamicView } from '../views/DynamicView';
import { LayoutTokens } from '../common/LayoutTokens';

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
  @State arcTotal: number = 0;
  @State arcPage: number = 1;
  @State arcOrder: string = 'pubdate';
  @State arcLoading: boolean = true;
  @State loadingMore: boolean = false;
  @State following: boolean = false;
  @State followLoading: boolean = false;
  @State groupSheetOpen: boolean = false;
  @State groupList: Array<FollowTagItem> = [];
  @State groupLoading: boolean = false;
  @State groupNewName: string = '';
  /** 当前 UP 勾选中的分组 id 数组（空 = 默认分组）；保存时用。 */
  @State groupChecked: Array<number> = [];
  @State spaceTab: number = 0;
  @State visualSpaceTab: number = 0;
  @State headerIndex: number = 0;
  @State headerVideoReadyIndex: number = -1;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 780;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  private tabsController: TabsController = new TabsController();
  private videosSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private arcFetching: boolean = false;
  private destroyed: boolean = false;
  private lifecycleGeneration: number = 0;
  private headerVideoGeneration: number = 0;
  private headerVideoRevealPendingIndex: number = -1;

  aboutToAppear(): void {
    this.destroyed = false;
    this.lifecycleGeneration++;
    this.followLoading = false;
    this.arcFetching = false;
    this.loadingMore = false;
    this.init().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.lifecycleGeneration++;
    this.headerVideoGeneration++;
    this.headerVideoRevealPendingIndex = -1;
  }

  private headerTransitionId(index: number): string {
    return 'image-viewer-space-' + String(this.param.mid) + '-' + String(index);
  }

  async init(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    this.loading = true;
    this.errorText = '';
    try {
      const info: UserSpaceInfo | null = await BiliApi.getUserSpaceInfo(this.param.mid);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      if (info === null) {
        this.errorText = '用户信息加载失败，请检查网络后重试';
        return;
      }
      this.info = info;
      BiliApi.getUserStat(this.param.mid).then((stat: UserStat) => {
        if (!this.destroyed && generation === this.lifecycleGeneration) this.stat = stat;
      }).catch(() => {
      });
      if (UserStore.isLogin) this.loadFollowState().catch(() => {
      });
      this.loadArcs(true).catch(() => {
      });
    } catch (e) {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        this.errorText = '用户信息加载失败，请检查网络后重试';
      }
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) this.loading = false;
    }
  }

  async loadFollowState(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    this.followLoading = true;
    try {
      const attribute: number | null = await BiliApi.getUserRelation(this.param.mid);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      if (attribute !== null) this.following = attribute === 2 || attribute === 6;
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) this.followLoading = false;
    }
  }

  private toast(message: string): void {
    try {
      this.toast(message);
    } catch (e) {
      // 页面销毁或窗口异常时忽略提示。
    }
  }

  async toggleFollow(): Promise<void> {
    if (!UserStore.isLogin) {
      this.toast('请先登录后再关注');
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return;
    }
    if (UserStore.current !== null && UserStore.current.mid === this.param.mid) {
      this.toast('不能关注自己');
      return;
    }
    if (this.followLoading) return;
    const previous: boolean = this.following;
    this.following = !previous;
    this.followLoading = true;
    const generation: number = this.lifecycleGeneration;
    try {
      const result: ActionResult = await BiliApi.modifyUserRelation(this.param.mid, this.following);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      if (!result.ok) {
        this.following = previous;
        this.toast(result.message);
      }
    } catch (e) {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        this.following = previous;
        this.toast('关注操作失败，请检查网络');
      }
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) this.followLoading = false;
    }
  }

  async loadArcs(reset: boolean): Promise<void> {
    if (this.arcFetching) {
      return;
    }
    this.arcFetching = true;
    const generation: number = this.lifecycleGeneration;
    try {
      if (reset) {
        this.arcPage = 1;
        this.arcLoading = true;
      }
      const pn: number = this.arcPage;
      const data: SpaceArcData = await BiliApi.getUserSpaceArcs(this.param.mid, pn, this.arcOrder);
      if (this.destroyed || generation !== this.lifecycleGeneration) {
        return;
      }
      if (reset) {
        this.videosSource.reset(data.videos);
      } else {
        this.videosSource.append(data.videos);
      }
      this.arcTotal = data.total;
      this.arcPage = pn + 1;
    } catch (e) {
      // 保留已加载投稿，排序或重试时可再次请求。
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        this.arcLoading = false;
        this.arcFetching = false;
      }
    }
  }

  hasMoreArcs(): boolean {
    return this.videosSource.totalCount() > 0 && this.videosSource.totalCount() < this.arcTotal;
  }

  onReachEnd(): void {
    if (this.loadingMore || this.arcLoading || !this.hasMoreArcs()) {
      return;
    }
    this.loadingMore = true;
    this.loadArcs(false)
      .catch(() => {
      })
      .finally(() => {
        this.loadingMore = false;
      });
  }

  private openLiveRoom(): void {
    if (this.info.liveStatus !== 1 || this.info.liveRoomId <= 0) return;
    const param: LiveRoomParam = {
      roomId: this.info.liveRoomId,
      uid: this.info.mid,
      title: this.info.liveTitle,
      uname: this.info.name,
      face: this.info.face,
      cover: this.info.liveCover,
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  private openHeaderImage(): void {
    const images: Array<string> = [];
    for (let i: number = 0; i < this.info.collectionHeaders.length; i++) {
      const item: UserSpaceHeaderItem = this.info.collectionHeaders[i];
      const url: string = item.fullCover.length > 0 ? item.fullCover : item.preview;
      if (url.length > 0) images.push(url);
    }
    if (images.length === 0 && this.info.topPhoto.length > 0) images.push(this.info.topPhoto);
    if (images.length === 0) return;
    const initialIndex: number = Math.min(this.headerIndex, images.length - 1);
    const param: ImageViewerParam = {
      images: images,
      initialIndex: initialIndex,
      transitionId: this.headerTransitionId(initialIndex),
    };
    // 一镜到底：关默认转场 + animateTo，geometryTransition 接管
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, param, false);
    });
  }

  @Builder
  HeaderImage(url: string) {
    Image(url)
      .width('100%')
      .height('100%')
      .objectFit(ImageFit.Cover)
      .draggable(false)
      .geometryTransition(this.headerTransitionId(this.headerIndex))
      .onClick(() => this.openHeaderImage())
  }

  private headerPageNear(index: number): boolean {
    return Math.abs(index - this.headerIndex) <= 1;
  }

  /** 同一组典藏保持稳定的响应式展示比例，切页时资料区不会上下跳。 */
  private adaptiveHeaderHeight(): number {
    const statusHeight: number = Immersive.statusBarHeight();
    const width: number = Math.max(1, this.viewportWidth);
    const minHeight: number = statusHeight + 160;
    const maxHeight: number = Math.max(minHeight, Math.min(360, this.viewportHeight * 0.42));
    return Math.max(minHeight, Math.min(width / 1.55, maxHeight));
  }

  private headerMediaWidth(item: UserSpaceHeaderItem): number {
    if (item.sourceWidth <= 0 || item.sourceHeight <= 0) return this.viewportWidth;
    const scale: number = Math.max(this.viewportWidth / item.sourceWidth,
      this.adaptiveHeaderHeight() / item.sourceHeight);
    return item.sourceWidth * scale;
  }

  private headerMediaHeight(item: UserSpaceHeaderItem): number {
    if (item.sourceWidth <= 0 || item.sourceHeight <= 0) return this.adaptiveHeaderHeight();
    const scale: number = Math.max(this.viewportWidth / item.sourceWidth,
      this.adaptiveHeaderHeight() / item.sourceHeight);
    return item.sourceHeight * scale;
  }

  private headerMediaOffsetX(item: UserSpaceHeaderItem): number {
    const mediaWidth: number = this.headerMediaWidth(item);
    const desired: number = this.viewportWidth / 2 - item.focusX * mediaWidth;
    return Math.max(this.viewportWidth - mediaWidth, Math.min(0, desired));
  }

  private headerMediaOffsetY(item: UserSpaceHeaderItem): number {
    const mediaHeight: number = this.headerMediaHeight(item);
    const headerHeight: number = this.adaptiveHeaderHeight();
    const desired: number = headerHeight / 2 - item.focusY * mediaHeight;
    return Math.max(headerHeight - mediaHeight, Math.min(0, desired));
  }

  /** 第一帧真正提交到 Video Surface 后再移走封面，避免 prepared/start 与画面提交之间露出黑帧。 */
  private revealHeaderVideoAfterFirstFrame(index: number): void {
    if (index !== this.headerIndex || this.headerVideoReadyIndex === index ||
      this.headerVideoRevealPendingIndex === index) return;
    const generation: number = this.headerVideoGeneration;
    this.headerVideoRevealPendingIndex = index;
    setTimeout(() => {
      if (generation !== this.headerVideoGeneration) return;
      this.headerVideoRevealPendingIndex = -1;
      if (!this.destroyed && index === this.headerIndex) this.headerVideoReadyIndex = index;
    }, 80);
  }

  @Builder
  CollectionHeaderPage(item: UserSpaceHeaderItem, index: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (index === this.headerIndex && item.animationUrl.length > 0) {
        Video({
          src: item.animationUrl,
          previewUri: item.preview.length > 0 ? item.preview : item.fullCover,
          posterOptions: {
            showFirstFrame: false,
            contentTransitionEffect: ContentTransitionEffect.OPACITY,
          },
        })
          .width(this.headerMediaWidth(item))
          .height(this.headerMediaHeight(item))
          // 元数据与实际素材尺寸可能不一致：Cover 在尺寸吻合时与 Fill 等价，不吻合时裁剪而不是拉伸。
          .objectFit(ImageFit.Cover)
          .position({ x: this.headerMediaOffsetX(item), y: this.headerMediaOffsetY(item) })
          .zIndex(0)
          .muted(true)
          .controls(false)
          .autoPlay(true)
          .loop(true)
          .onUpdate((info: PlaybackInfo) => {
            if (info.time > 0) this.revealHeaderVideoAfterFirstFrame(index);
          })
      }
      if (this.headerPageNear(index)) {
        // Image 始终压在活动 Video 上方；只有收到首个有效播放进度并再等待一次合成提交后才淡出。
        Image(item.preview.length > 0 ? item.preview : item.fullCover)
          .width(this.headerMediaWidth(item))
          .height(this.headerMediaHeight(item))
          .objectFit(ImageFit.Cover)
          .position({ x: this.headerMediaOffsetX(item), y: this.headerMediaOffsetY(item) })
          .draggable(false)
          .zIndex(1)
          .opacity(index === this.headerIndex && item.animationUrl.length > 0 &&
            this.headerVideoReadyIndex === index ? 0 : 1)
          .animation({ duration: 160, curve: Curve.EaseOut })
      } else if (index !== this.headerIndex) {
        // 远离当前页时不创建 Image/Video，避免十几张典藏头图一次性下载和解码。
        Blank().width('100%').height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .id('uspace-header-media')
    .geometryTransition(this.headerTransitionId(index))
    .onClick(() => this.openHeaderImage())
  }

  // ===== 空间头图：典藏卡多图用 Swiper；普通空间装扮用日/夜头图 =====
  @Builder
  Header() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.info.collectionHeaders.length > 1) {
        Swiper() {
          ForEach(this.info.collectionHeaders, (item: UserSpaceHeaderItem, index: number) => {
            this.CollectionHeaderPage(item, index)
          }, (item: UserSpaceHeaderItem, index: number) => item.fullCover + String(index))
        }
        .width('100%')
        .height('100%')
        .indicator(new DotIndicator().itemWidth(5).itemHeight(5).selectedItemWidth(13)
          .selectedItemHeight(5).color('#66FFFFFF').selectedColor('#FFFFFF'))
        .loop(false)
        .autoPlay(false)
        .duration(450)
        .onChange((index: number) => {
          this.headerVideoGeneration++;
          this.headerVideoRevealPendingIndex = -1;
          this.headerVideoReadyIndex = -1;
          this.headerIndex = index;
        })
      } else if (this.info.collectionHeaders.length === 1) {
        this.CollectionHeaderPage(this.info.collectionHeaders[0], 0)
      } else if (this.info.topPhoto.length > 0) {
        this.HeaderImage(this.isDark && this.info.topPhotoDark.length > 0 ? this.info.topPhotoDark : this.info.topPhoto)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [[this.accent, 0.0], [colorWithAlpha(this.accent, '66'), 1.0]],
          })
      }
      // 上下两端轻微压暗，保证系统栏与悬浮按钮可读。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#59000000', 0.0], ['#00000000', 0.38], ['#33000000', 1.0]],
        })
        .hitTestBehavior(HitTestMode.None)
      Row() {
        BackButton({ variant: BackButtonVariant.GLASS })
        Blank()
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_search')).width(20).height(20).fillColor('#FFFFFF')
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(this.glassOn ? '#66000000' : '#B3000000')
        .backdropBlur(this.glassOn ? 10 : 0)
        .onClick(() => AppNavStack.pushPathByName(NAV_SEARCH, null))
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_more')).width(20).height(20).fillColor('#FFFFFF')
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(this.glassOn ? '#66000000' : '#B3000000')
        .backdropBlur(this.glassOn ? 10 : 0)
        .onClick(() => this.openHeaderImage())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: Immersive.statusBarHeight() + 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(this.adaptiveHeaderHeight())
  }

  @Builder
  StatCell(value: number, label: string, mode: string) {
    Column({ space: 2 }) {
      Text(formatCount(value))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#F2F2F4' : '#18191C')
      Text(label).fontSize(11).fontColor('#9499A0')
    }
    .width(this.viewportWidth < 360 ? 60 : 70)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      if (mode.length === 0) return;
      const param: RelationListParam = { mid: this.param.mid, mode: mode };
      AppNavStack.pushPathByName(NAV_RELATION_LIST, param);
    })
  }

  // ===== 头像压住头图下缘；统计、资料和关注操作放在纯色内容区 =====
  @Builder
  ProfileSummary() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.Bottom }) {
        DecoratedAvatar({
          face: this.info.face,
          pendant: this.info.pendant,
          avatarSize: 78,
          containerSize: 108,
          pendantScale: 1.38,
          avatarBorderWidth: this.info.pendant.length > 0 ? 0 : 3,
          avatarBorderColor: this.isDark ? '#18191C' : '#FFFFFF',
        })
        if (this.info.liveStatus === 1 && this.info.liveRoomId > 0) {
          Text('直播中')
            .width(52).height(20).textAlign(TextAlign.Center)
            .fontSize(10).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
            .backgroundColor(this.accent).borderRadius(10)
        }
      }
      .width(108).height(108)
      .position({ x: 14, y: -48 })
      .onClick(() => this.openLiveRoom())
      Row() {
        this.StatCell(this.stat.follower, '粉丝', 'follower')
        this.StatCell(this.stat.following, '关注', 'following')
        this.StatCell(this.stat.likeNum, '获赞', '')
      }
      .position({ x: this.viewportWidth < 360 ? 120 : 132, y: 12 })
      Column({ space: 8 }) {
        Row({ space: 7 }) {
          Text(this.info.name)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.info.officialType >= 0 ? this.accent : (this.isDark ? '#F2F2F4' : '#18191C'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.info.level > 0) {
            Text('LV' + this.info.level)
              .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .backgroundColor(this.accent).borderRadius(3)
          }
        }
        if (this.info.officialDesc.length > 0) {
          Text(this.info.officialDesc).fontSize(11).fontColor('#F0C541').maxLines(1)
        }
        Text(this.info.sign.length > 0 ? this.info.sign : '这个人很神秘，什么都没有写')
          .fontSize(13)
          .fontColor(this.isDark ? '#B8B8BE' : '#61666D')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('UID ' + String(this.info.mid))
          .fontSize(10).fontColor('#9499A0')
        if (this.info.liveStatus === 1 && this.info.liveRoomId > 0) {
          Row({ space: 8 }) {
            Image($r('app.media.ic_live')).width(16).height(16).fillColor('#FFFFFF')
            Text(this.info.liveTitle.length > 0 ? this.info.liveTitle : '正在直播')
              .fontSize(12).fontColor('#FFFFFF').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text('进入直播间 ›').fontSize(11).fontColor('#FFFFFF')
          }
          .width('100%').height(36).padding({ left: 10, right: 10 })
          .backgroundColor(this.accent).borderRadius(8)
          .onClick(() => this.openLiveRoom())
        }
        if (UserStore.current === null || UserStore.current.mid !== this.param.mid) {
          Text(this.followLoading ? '处理中…' : (this.following ? '已关注' : '+ 关注'))
            .width('100%').height(36).textAlign(TextAlign.Center)
            .fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(this.following ? '#9499A0' : this.accent)
            .border({ width: 1, color: this.following ? '#55565B' : this.accent, radius: 5 })
            .onClick(() => this.toggleFollow())
          Row({ space: 0 }) {
            Text('举报')
              .fontSize(11).fontColor('#B0B3B8')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick(() => this.reportBlockMenu())
            Text('·').fontSize(11).fontColor('#55565B')
            Text('分组')
              .fontSize(11).fontColor('#B0B3B8')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .priorityGesture(TapGesture().onAction(() => this.openFollowGroups()))
            Text('·').fontSize(11).fontColor('#55565B')
            Text('拉黑')
              .fontSize(11).fontColor('#B0B3B8')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick(() => this.blockUser())
          }
          .width('100%').justifyContent(FlexAlign.Center).margin({ top: 6 })
        } else {
          Text('这是你的空间')
            .width('100%').height(36).textAlign(TextAlign.Center)
            .fontSize(13).fontColor('#9499A0')
            .border({ width: 1, color: '#55565B', radius: 5 })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 72, bottom: 14 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 190 })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  /** 举报用户入口：选择原因 → 提交；同时提供快捷拉黑。 */
  private reportBlockMenu(): void {
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再操作');
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '操作',
        message: '对 ' + this.info.name + ' 进行什么操作？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '拉黑', color: '#FB4A4A' },
          { text: '举报', color: this.accent },
        ],
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        if (pick === 1) {
          this.blockUser();
        } else if (pick === 2) {
          this.reportUser();
        }
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  private blockUser(): void {
    BiliApi.blockUser(this.param.mid, true).then((r: ActionResult) => {
      this.toast(r.ok ? '已加入黑名单' : r.message);
    }).catch(() => {
      this.toast('操作失败，请稍后重试');
    });
  }

  // ===== 关注分组 =====
  private openFollowGroups(): void {
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再使用分组功能');
      return;
    }
    this.groupSheetOpen = true;
    this.groupChecked = [];
    this.groupLoading = true;
    BiliApi.getFollowTags().then((tags: Array<FollowTagItem>) => {
      this.groupList = tags;
      this.groupLoading = false;
    }).catch(() => {
      this.groupList = [];
      this.groupLoading = false;
    });
  }

  private async createGroup(): Promise<void> {
    const name: string = this.groupNewName.trim();
    if (name.length === 0) {
      this.toast('请输入分组名称');
      return;
    }
    if (name.length > 15) {
      this.toast('分组名称最多 15 个字');
      return;
    }
    const tagid: number = await BiliApi.createFollowTag(name);
    if (tagid <= 0) {
      this.toast('创建分组失败，请检查登录状态后重试');
      return;
    }
    this.groupList = this.groupList.concat([{ tagid: tagid, name: name, count: 0 }]);
    this.groupChecked = this.groupChecked.concat([tagid]);
    this.groupNewName = '';
  }

  private async saveGroupChecked(): Promise<void> {
    await BiliApi.addUserToTags(this.param.mid, this.groupChecked);
    this.groupSheetOpen = false;
    this.toast('分组已保存');
  }

  private reportUser(): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报用户',
        message: '选择举报原因',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '违法违规', color: '#18191C' },
          { text: '垃圾广告', color: '#18191C' },
          { text: '人身攻击', color: '#18191C' },
        ],
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        const reasons: Array<string> = ['', '1', '3', '4'];
        if (pick <= 0 || pick >= reasons.length) return;
        BiliApi.reportMember(this.param.mid, reasons[pick]).then((r: ActionResult) => {
          this.toast(r.ok ? '已提交举报，感谢反馈' : r.message);
        }).catch(() => {
          this.toast('举报失败，请稍后重试');
        });
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  // ===== 投稿 Tab：排序 chips + 双列视频流 =====
  @Builder
  ArcTab(showFilters: boolean) {
    Column() {
      if (showFilters) {
        Row() {
          ForEach(ARC_ORDERS, (opt: Record<string, string>) => {
            FilterChip({
              label: opt['label'],
              selected: this.arcOrder === opt['value'],
              onTap: () => {
                if (this.arcOrder !== opt['value']) {
                  this.arcOrder = opt['value'];
                  this.loadArcs(true).catch(() => {
                  });
                }
              },
            })
          }, (opt: Record<string, string>) => opt['value'])
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 2 })
      } else {
        Row({ space: 7 }) {
          Text('视频').fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#F2F2F4' : '#18191C')
          Text(formatCount(this.arcTotal)).fontSize(12).fontColor('#9499A0')
          Blank()
          Text('更多  ›').fontSize(12).fontColor('#9499A0')
        }
        .width('100%').height(44).padding({ left: 14, right: 14 })
        .onClick(() => {
          this.visualSpaceTab = 2;
          this.tabsController.changeIndex(2);
        })
      }

      if (this.arcLoading && this.videosSource.isEmpty()) {
        LoadingView({ loading: true })
      } else if (this.videosSource.isEmpty()) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: '暂无投稿视频',
          onRetry: () => {
            this.loadArcs(true).catch(() => {
            });
          },
        })
      } else {
        List({ space: 10 }) {
          LazyForEach(this.videosSource, (item: VideoItem) => {
            ListItem() {
              VideoCard({ video: item, compact: true })
            }
          }, (item: VideoItem) => item.bvid.length > 0 ? item.bvid : String(item.aid))
          ListItem() {
            LoadMoreFooter({
              loading: this.loadingMore,
              hasMore: this.hasMoreArcs(),
              moreText: '加载更多',
              endText: '—— 到底啦 ——',
              padTop: 8,
              padBottom: 16,
              onLoadMore: () => {
                this.onReachEnd();
              },
            })
          }
        }
        .width('100%')
        .height('100%')
        .lanes(LayoutTokens.feedColumns(this.viewportWidth), 10)
        .cachedCount(3)
        .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
          right: LayoutTokens.horizontalPadding(this.viewportWidth), top: 6 })
        .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
        .alignSelf(ItemAlign.Center)
        .scrollBar(BarState.Off)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST,
        })
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
        if ((index === 0 || index === 2) && this.arcTotal > 0) {
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
              this.init().catch(() => {
              });
            },
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      } else {
        List() {
          ListItem() {
            this.Header()
          }
          ListItem() {
            this.ProfileSummary()
          }
          ListItem() {
            Column() {
              // 外层 List 吸顶到沉浸区域时，为标签栏保留系统栏高度；负 margin 抵消普通位置的额外占位。
              Row().width('100%').height(Immersive.statusBarHeight())
              Tabs({ barPosition: BarPosition.Start, index: this.spaceTab, controller: this.tabsController }) {
                TabContent() {
                  this.ArcTab(false)
                }
                .tabBar(this.SpaceTabBar('主页', 0))
                TabContent() {
                  DynamicView({ hostMid: this.param.mid, embedded: true })
                }
                .tabBar(this.SpaceTabBar('动态', 1))
                TabContent() {
                  this.ArcTab(true)
                }
                .tabBar(this.SpaceTabBar('投稿', 2))
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
              .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
            }
            .width('100%')
            .height('100%')
            .margin({ top: -Immersive.statusBarHeight() })
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      }

      if (this.groupSheetOpen) {
        this.GroupSheetOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      const height: number = Number(newValue.height);
      if (!Number.isNaN(width) && width > 0) this.viewportWidth = width;
      if (!Number.isNaN(height) && height > 0) this.viewportHeight = height;
    })
  }

  /** 关注分组底部面板：勾选分组（空=默认分组）+ 新建分组输入。 */
  @Builder
  GroupSheetOverlay() {
    Column() {
      Blank()
      Column({ space: 10 }) {
        Text('关注分组')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('勾选分组（取消全部 = 默认分组）。')
          .fontSize(11).fontColor('#9499A0')
        if (this.groupLoading) {
          Text('加载中…').fontSize(13).fontColor('#9499A0').padding(14)
        } else {
          List() {
            ForEach(this.groupList, (tag: FollowTagItem) => {
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
                      .fill(this.groupChecked.indexOf(tag.tagid) >= 0 ? this.accent : '#00000000')
                      .border({ width: 1.5, color: this.groupChecked.indexOf(tag.tagid) >= 0 ? this.accent : '#B4B6BA' })
                    if (this.groupChecked.indexOf(tag.tagid) >= 0) {
                      Text('✓').fontSize(11).fontColor('#FFFFFF')
                    }
                  }
                  .width(24).height(24)
                }
                .width('100%').padding({ top: 8, bottom: 8 })
                .onClick(() => this.toggleGroupChecked(tag.tagid))
              }
            }, (item: FollowTagItem) => String(item.tagid))
          }
          .width('100%')
          .constraintSize({ maxHeight: 300 })
          .scrollBar(BarState.Off)
        }
        Row({ space: 8 }) {
          TextInput({ placeholder: '新建分组名称', text: this.groupNewName })
            .fontSize(13)
            .layoutWeight(1)
            .height(34)
            .onChange((value: string) => this.groupNewName = value)
          Text('新建')
            .fontSize(13).fontColor(this.accent)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.createGroup().catch(() => {
              });
            })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(14).fontColor('#9499A0')
            .layoutWeight(1).height(38).textAlign(TextAlign.Center)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F5F7F9').borderRadius(19)
            .onClick(() => this.groupSheetOpen = false)
          Text('保存')
            .fontSize(14).fontColor('#FFFFFF').backgroundColor(this.accent)
            .layoutWeight(1).height(38).textAlign(TextAlign.Center)
            .borderRadius(19)
            .onClick(() => {
              this.saveGroupChecked().catch(() => {
              });
            })
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

  private toggleGroupChecked(tagid: number): void {
    this.groupChecked = this.groupChecked.indexOf(tagid) >= 0 ?
      this.groupChecked.filter((id: number) => id !== tagid) : this.groupChecked.concat([tagid]);
  }
}
