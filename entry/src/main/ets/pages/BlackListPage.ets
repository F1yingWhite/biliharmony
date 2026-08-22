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

@Component
export struct BlackListPage {
  @State users: Array<RelationUserItem> = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State failed: boolean = false;
  @State page: number = 1;
  @State actionBusy: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  private destroyed: boolean = false;
  private hasMore: boolean = true;

  aboutToAppear(): void {
    this.destroyed = false;
    this.load(true).catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private async load(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    this.loading = true;
    if (reset) {
      this.failed = false;
      this.page = 1;
    }
    try {
      const data: RelationUserPageData = await UserApi.getBlackList(this.page);
      if (this.destroyed) return;
      this.users = reset ? data.users : this.users.concat(data.users);
      this.total = data.total;
      this.hasMore = data.users.length > 0 && this.users.length < data.total;
      this.page++;
    } catch (e) {
      if (!this.destroyed && this.users.length === 0) this.failed = true;
    } finally {
      if (!this.destroyed) this.loading = false;
    }
  }

  private openUser(item: RelationUserItem): void {
    const param: UserSpaceParam = { mid: item.mid };
    AppNavStack.pushPathByName(NAV_USER_SPACE, param);
  }

  /** 解除拉黑：成功后本地移除该行。 */
  private async unblock(item: RelationUserItem, index: number): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await UserApi.setBlocked(item.mid, false);
      if (this.destroyed) return;
      if (result.ok) {
        const next: Array<RelationUserItem> = this.users.slice();
        next.splice(index, 1);
        this.users = next;
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

  @Builder
  BlackRow(item: RelationUserItem, index: number) {
    Row({ space: 12 }) {
      DecoratedAvatar({ face: item.face, avatarSize: 48, containerSize: 54 })
      Column({ space: 5 }) {
        Text(item.uname).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#F2F2F4' : '#18191C')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.sign.length > 0 ? item.sign : '这个人很神秘，什么都没有写')
          .fontSize(11).fontColor('#9499A0').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('解除')
        .fontSize(12)
        .fontColor(this.accent)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .border({ width: 0.5, color: this.accent, radius: 12 })
        .onClick(() => this.unblock(item, index).catch(() => {
        }))
        .stateStyles({
          pressed: { opacity: 0.6 },
          normal: { opacity: 1 },
        })
    }
    .width('100%').height(70).padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#303136' : '#ECEEF0' })
    .onClick(() => this.openUser(item))
  }

  build() {
    Column() {
      PageHeader({ title: '黑名单' + (this.total > 0 ? ' ' + formatCount(this.total) : '') })
      if (this.loading && this.users.length === 0) {
        LoadingProgress().width(28).height(28).color(this.accent).margin({ top: 60 })
      } else if (this.failed) {
        Text('列表加载失败，点击重试').fontSize(13).fontColor('#9499A0').margin({ top: 60 })
          .onClick(() => this.load(true).catch(() => {
          }))
      } else if (this.users.length === 0) {
        Text('黑名单为空').fontSize(13).fontColor('#9499A0').margin({ top: 60 })
      } else {
        List() {
          ForEach(this.users, (item: RelationUserItem, index: number) => {
            ListItem() {
              this.BlackRow(item, index)
            }
          }, (item: RelationUserItem) => String(item.mid))
          if (this.hasMore || this.loading) {
            ListItem() {
              Text(this.loading ? '加载中…' : '加载更多')
                .width('100%').height(48).textAlign(TextAlign.Center).fontSize(12).fontColor('#9499A0')
                .onClick(() => this.load(false).catch(() => {
                }))
            }
          }
        }
        .width('100%').layoutWeight(1).cachedCount(4).scrollBar(BarState.Off)
        .onReachEnd(() => this.load(false).catch(() => {
        }))
      }
    }
    .width('100%').height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
