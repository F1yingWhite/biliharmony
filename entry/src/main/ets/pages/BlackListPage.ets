import { RequestEpoch } from '../common/RequestEpoch';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { LoadingView } from '../components/LoadingView';
/**
 * 黑名单管理页：展示已拉黑的用户列表，支持一键解除拉黑。
 */
import { AppNavStack, NAV_USER_SPACE, UserSpaceParam } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { ActionResult } from '../api/BiliApi';
import { RelationUserItem, RelationUserPageData } from '../model/Models';
import { UserApi } from '../api/UserApi';
import { PageHeader } from '../components/PageHeader';
import { DecoratedAvatar } from '../components/UserDecorations';
import { formatCount } from '../common/Utils';
import { BasicDataSource } from '../common/BasicDataSource';

/**
 * 黑名单列表行。@Reusable：配合 LazyForEach 在长列表滚动时复用行实例；
 * @Prop 数据复用时自动重绑，回调引用在 aboutToReuse 承接。
 */
@Reusable
@Component
struct BlacklistUserRow {
  @Prop face: string = '';
  @Prop uname: string = '';
  @Prop sign: string = '';
  /** 页面正在提交解除拉黑请求时禁用行内按钮。 */
  @Prop busy: boolean = false;
  onOpen: () => void = () => {
  };
  onUnblock: () => void = () => {
  };
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';

  aboutToReuse(params: Record<string, Object>): void {
    // @Prop 自动跟随，这里承接回调引用等非常量绑定（对齐 VideoRowCard 模式）。
    const open: Object | undefined = params['onOpen'];
    if (typeof open === 'function') {
      this.onOpen = open as () => void;
    }
    const unblock: Object | undefined = params['onUnblock'];
    if (typeof unblock === 'function') {
      this.onUnblock = unblock as () => void;
    }
  }

  build() {
    Row({ space: 12 }) {
      DecoratedAvatar({ face: this.face, avatarSize: 48, containerSize: 54 })
      Column({ space: 5 }) {
        Text(this.uname).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#F2F2F4' : '#18191C')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.sign.length > 0 ? this.sign : '这个人很神秘，什么都没有写')
          .fontSize(11).fontColor('#9499A0').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('解除')
        .fontSize(12)
        .fontColor(this.accent)
        .height(36).padding({ left: 12, right: 12 })
        .enabled(!this.busy)
        .accessibilityText('解除对' + this.uname + '的拉黑')
        .border({ width: 0.5, color: this.accent, radius: 12 })
        .onClick(() => this.onUnblock())
        .stateStyles({
          pressed: { opacity: 0.9 },
          normal: { opacity: 1 },
        })
    }
    .width('100%').height(70).padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#303136' : '#ECEEF0' })
    .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
    .onClick(() => this.onOpen())
  }
}

@Component
export struct BlackListPage {
  private usersSource: BasicDataSource<RelationUserItem> = new BasicDataSource<RelationUserItem>();
  /** 列表行数镜像：BasicDataSource 不触发非 LazyForEach 区域刷新，空态/列表分支由它切换。 */
  @State userCount: number = 0;
  @State total: number = 0;
  @State loading: boolean = false;
  @State failed: boolean = false;
  @State page: number = 1;
  @State actionBusy: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  private destroyed: boolean = false;
  @State hasMore: boolean = true;
  private requestEpoch: RequestEpoch = new RequestEpoch();

  aboutToAppear(): void {
    this.destroyed = false;
    this.loading = false;
    this.load(true).catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.requestEpoch.invalidate();
  }

  private async load(reset: boolean): Promise<void> {
    if (this.destroyed || this.loading || (!reset && !this.hasMore)) return;
    const epoch: number = this.requestEpoch.next();
    const pn: number = reset ? 1 : this.page;
    this.loading = true;
    this.failed = false;
    try {
      const data: RelationUserPageData = await UserApi.getBlackList(pn);
      if (this.destroyed || !this.requestEpoch.isCurrent(epoch)) return;
      if (reset) this.usersSource.reset(data.users);
      else this.usersSource.append(data.users);
      this.userCount = this.usersSource.totalCount();
      this.total = data.total;
      this.hasMore = data.users.length > 0 && this.userCount < data.total;
      this.page = pn + 1;
    } catch (e) {
      if (!this.destroyed && this.requestEpoch.isCurrent(epoch)) this.failed = true;
    } finally {
      if (!this.destroyed && this.requestEpoch.isCurrent(epoch)) this.loading = false;
    }
  }

  private openUser(item: RelationUserItem): void {
    const param: UserSpaceParam = { mid: item.mid };
    AppNavStack.pushPathByName(NAV_USER_SPACE, param);
  }

  /** 解除拉黑：成功后从数据源移除该行。 */
  private async unblock(item: RelationUserItem): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await UserApi.setBlocked(item.mid, false);
      if (this.destroyed) return;
      if (result.ok) {
        this.usersSource.reset(this.usersSource.getAll().filter(
          (x: RelationUserItem) => x.mid !== item.mid));
        this.userCount = this.usersSource.totalCount();
        this.total = Math.max(0, this.total - 1);
        this.getUIContext().getPromptAction().showToast({ message: '已解除拉黑' });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
      }
    } catch (e) {
      if (!this.destroyed) this.getUIContext().getPromptAction().showToast({ message: '操作失败，请稍后重试' });
    } finally {
      this.actionBusy = false;
    }
  }

  build() {
    Column() {
      PageHeader({ title: '黑名单' + (this.total > 0 ? ' ' + formatCount(this.total) : '') })
      if (this.userCount === 0) {
        LoadingView({ loading: this.loading, skeleton: 'sessions', empty: !this.loading && !this.failed,
          emptyText: '黑名单为空', errorText: this.failed ? '列表加载失败，请重试' : '',
          onRetry: () => this.load(true).catch(() => {}) })
      } else {
        List() {
          LazyForEach(this.usersSource, (item: RelationUserItem) => {
            ListItem() {
              BlacklistUserRow({
                face: item.face,
                uname: item.uname,
                sign: item.sign,
                busy: this.actionBusy,
                onOpen: () => this.openUser(item),
                onUnblock: () => this.unblock(item).catch(() => {
                }),
              })
            }
          }, (item: RelationUserItem) => String(item.mid))
          ListItem() {
            LoadMoreFooter({ loading: this.loading, hasMore: this.hasMore,
              moreText: this.failed ? '加载失败 · 点击重试' : '加载更多',
              loadingText: '加载中…', fixedHeight: 48,
              onLoadMore: () => this.load(false) })
          }
        }
        .width('100%').layoutWeight(1).cachedCount(4).scrollBar(BarState.Off)
        .onReachEnd(() => { if (!this.failed) this.load(false); })
      }
    }
    .width('100%').height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
