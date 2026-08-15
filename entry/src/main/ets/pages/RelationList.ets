import { AppNavStack, NAV_USER_SPACE, RelationListParam, UserSpaceParam } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { RelationUserItem, RelationUserPageData } from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { PageHeader } from '../components/PageHeader';
import { DecoratedAvatar } from '../components/UserDecorations';
import { formatCount } from '../common/Utils';

@Component
export struct RelationListPage {
  param: RelationListParam = { mid: 0, mode: 'following' };
  @State users: Array<RelationUserItem> = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State failed: boolean = false;
  @State page: number = 1;
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
      const data: RelationUserPageData = await BiliApi.getRelationUsers(this.param.mid, this.param.mode, this.page);
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

  @Builder
  UserRow(item: RelationUserItem) {
    Row({ space: 12 }) {
      DecoratedAvatar({ face: item.face, avatarSize: 48, containerSize: 54 })
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Text(item.uname).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#F2F2F4' : '#18191C')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.special) {
            Text('特别关注').fontSize(9).fontColor(this.accent)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .border({ width: 0.5, color: this.accent, radius: 3 })
          }
        }
        Text(item.sign.length > 0 ? item.sign : '这个人很神秘，什么都没有写')
          .fontSize(11).fontColor('#9499A0').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text(item.attribute === 6 ? '互相关注' : (item.attribute === 2 ? '已关注' : ''))
        .fontSize(11).fontColor('#9499A0')
    }
    .width('100%').height(74).padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#303136' : '#ECEEF0' })
    .onClick(() => this.openUser(item))
  }

  build() {
    Column() {
      PageHeader({ title: (this.param.mode === 'follower' ? '粉丝' : '关注') +
        (this.total > 0 ? ' ' + formatCount(this.total) : '') })
      if (this.loading && this.users.length === 0) {
        LoadingProgress().width(28).height(28).color(this.accent).margin({ top: 60 })
      } else if (this.failed) {
        Text('列表加载失败，点击重试').fontSize(13).fontColor('#9499A0').margin({ top: 60 })
          .onClick(() => this.load(true).catch(() => {
          }))
      } else if (this.users.length === 0) {
        Text(this.param.mode === 'follower' ? '还没有粉丝' : '还没有关注用户')
          .fontSize(13).fontColor('#9499A0').margin({ top: 60 })
      } else {
        List() {
          ForEach(this.users, (item: RelationUserItem) => {
            ListItem() { this.UserRow(item) }
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
