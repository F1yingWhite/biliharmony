/**
 * 搜索页：热搜榜 / 搜索建议 / 搜索结果
 * 结果态：视频 | 用户 二级 Tab + 排序 chips + 视频筛选面板（search/type 接口）
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, NAV_USER_SPACE, VideoDetailParam, UserSpaceParam } from '../common/AppRouter';
import {
  VideoItem, HotSearchItem, UserSearchItem, SearchOption, SearchNumOption, VideoSearchResult, UserSearchResult,
  VIDEO_ORDER_OPTIONS, USER_ORDER_OPTIONS, VIDEO_DURATION_OPTIONS, VIDEO_PUBTIME_OPTIONS, VIDEO_ZONE_OPTIONS
} from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { LoadingView } from '../components/LoadingView';
import { formatCount } from '../common/Utils';
import { AppTheme } from '../common/AppTheme';
import { HotSearchStore } from '../common/HotSearchStore';
import { SearchHistoryStore } from '../common/SearchHistoryStore';

@Component
export struct SearchPage {
  @State keyword: string = '';
  @State hotList: Array<HotSearchItem> = [];
  @State suggests: Array<string> = [];
  // ===== 结果态 =====
  @State searching: boolean = false;
  @State searchTab: number = 0;              // 0 视频 1 用户
  @State results: Array<VideoItem> = [];
  @State userResults: Array<UserSearchItem> = [];
  @State videoTotal: number = -1;            // numResults 总数徽标，-1 未加载
  @State userTotal: number = -1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State videoPage: number = 1;
  @State userPage: number = 1;
  @State videoOrder: string = 'totalrank';
  @State userOrder: string = '';
  @State filterDuration: number = 0;         // VIDEO_DURATION_OPTIONS 下标
  @State filterPubtime: number = 0;          // VIDEO_PUBTIME_OPTIONS 下标
  @State filterTids: number = 0;             // 分区 id，0 不限
  @State showFilter: boolean = false;
  @State tmpDuration: number = 0;            // 筛选面板中的暂存值，点"完成"后生效
  @State tmpPubtime: number = 0;
  @State tmpTids: number = 0;
  @State showSuggest: boolean = false;
  @State history: Array<string> = [];
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('glassLevel') glassLevel: number = 1;
  @StorageProp('searchSuggestedKeyword') suggestedKeyword: string = '';

  async aboutToAppear(): Promise<void> {
    this.history = await SearchHistoryStore.ensureLoaded();
    this.loadHotSearch();
  }

  async loadHotSearch(): Promise<void> {
    const list: Array<HotSearchItem> = await HotSearchStore.load();
    this.hotList = list;
  }

  async onInput(value: string): Promise<void> {
    this.keyword = value;
    if (value.length === 0) {
      this.showSuggest = false;
      this.suggests = [];
      return;
    }
    const s: Array<string> = await BiliApi.searchSuggest(value);
    this.suggests = s;
    this.showSuggest = s.length > 0;
  }

  async doSearch(reset: boolean): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.showSuggest = false;
    this.searching = true;
    this.loading = reset;
    if (this.searchTab === 0) {
      if (reset) {
        this.videoPage = 1;
      }
      const page: number = this.videoPage;
      // 发布时间筛选：客户端换算为秒级时间戳起点
      let pubtimeBegin: number = 0;
      if (this.filterPubtime > 0) {
        pubtimeBegin = Math.floor(Date.now() / 1000) - VIDEO_PUBTIME_OPTIONS[this.filterPubtime].value;
      }
      const res: VideoSearchResult = await BiliApi.searchVideosByType(kw, page, this.videoOrder,
        VIDEO_DURATION_OPTIONS[this.filterDuration].value, pubtimeBegin, this.filterTids);
      this.results = reset ? res.videos : this.results.concat(res.videos);
      this.videoTotal = res.numResults;
      this.videoPage = page + 1;
    } else {
      if (reset) {
        this.userPage = 1;
      }
      const page: number = this.userPage;
      const res: UserSearchResult = await BiliApi.searchUsers(kw, page, this.userOrder);
      this.userResults = reset ? res.users : this.userResults.concat(res.users);
      this.userTotal = res.numResults;
      this.userPage = page + 1;
    }
    this.loading = false;
    this.loadingMore = false;
  }

  // 新关键词搜索：回到视频 Tab 重新加载
  submitSearch(): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0 && this.suggestedKeyword.length > 0) {
      this.keyword = this.suggestedKeyword;
    }
    if (this.keyword.trim().length === 0) return;
    this.history = SearchHistoryStore.add(this.keyword);
    this.searchTab = 0;
    this.doSearch(true);
  }

  @Builder
  SearchHistory() {
    Column({ space: 8 }) {
      Row() {
        Text('搜索历史')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
        Text('清空')
          .fontSize(12)
          .fontColor('#9499A0')
          .onClick(() => {
            SearchHistoryStore.clear();
            this.history = [];
          })
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.history, (word: string) => {
          Row({ space: 5 }) {
            Text(word)
              .fontSize(12)
              .fontColor(this.isDark ? '#E6E6E6' : '#454A50')
              .maxLines(1)
              .constraintSize({ maxWidth: 150 })
              .onClick(() => {
                this.keyword = word;
                this.submitSearch();
              })
            Image($r('app.media.ic_close'))
              .width(10)
              .height(10)
              .fillColor('#9499A0')
              .onClick(() => {
                this.history = SearchHistoryStore.remove(word);
              })
          }
          .padding({ left: 10, right: 8, top: 6, bottom: 6 })
          .margin({ right: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor(this.isDark ? '#2E3136' : '#E9EBEE')
        }, (word: string) => word)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 2 })
    .alignItems(HorizontalAlign.Start)
  }

  onTabChanged(index: number): void {
    this.searchTab = index;
    // 切到未加载过的 Tab 时拉取首屏
    if (index === 0 && this.results.length === 0) {
      this.doSearch(true);
    } else if (index === 1 && this.userResults.length === 0) {
      this.doSearch(true);
    }
  }

  hasVideoFilter(): boolean {
    return this.filterDuration > 0 || this.filterPubtime > 0 || this.filterTids > 0;
  }

  @Builder
  BackButton() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .translate({ y: -1 })
    }
    .width(32)
    .height(32)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      AppNavStack.pop();
    })
  }

  @Builder
  HotList() {
    Column() {
      Row() {
        Text('热搜榜')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 8 })

      List() {
        ForEach(this.hotList, (item: HotSearchItem, index: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(String(index + 1))
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(index < 3 ? this.accent : '#9499A0')
                .width(24)
                .textAlign(TextAlign.Center)
              if (item.icon.length > 0) {
                Image(item.icon)
                  .width(16)
                  .height(16)
              }
              Text(item.showName)
                .fontSize(14)
                .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(item.heatScore > 0 ? formatCount(item.heatScore) + ' 热度' : '')
                .fontSize(11)
                .fontColor('#9499A0')
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .onClick(() => {
              this.keyword = item.keyword;
              this.submitSearch();
            })
          }
        }, (item: HotSearchItem) => item.keyword)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  SuggestList() {
    Column() {
      ForEach(this.suggests, (s: string) => {
        Row({ space: 8 }) {
          Image($r('app.media.ic_search'))
            .width(18)
            .height(18)
            .fillColor(this.accent)
          Text(s)
            .fontSize(14)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          this.keyword = s;
          this.showSuggest = false;
          this.submitSearch();
        })
      }, (s: string) => s)
    }
    .width('100%')
    .backgroundColor(this.isDark ? '#2A2C31' : '#FFFFFF')
    .borderRadius(10)
    .margin({ left: 10, right: 10 })
  }

  // ===== 结果态：排序/筛选 chip（选中主题色填充，未选灰底） =====
  @Builder
  Chip(label: string, selected: boolean, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(selected ? '#FFFFFF' : (this.isDark ? '#C6C7CB' : '#61666D'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(selected ? this.accent : (this.isDark ? '#2E3136' : '#ECEEF0'))
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        onTap();
      })
  }

  // ===== 结果态：二级 Tab 栏（轻量文字样式 + 主题色下划线） =====
  @Builder
  ResultTabBar(index: number, label: string) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.searchTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.searchTab === index ? (this.isDark ? '#FFFFFF' : '#18191C') : '#9499A0')
      Text('')
        .width(18)
        .height(2.5)
        .borderRadius(1.5)
        .backgroundColor(this.searchTab === index ? this.accent : '#00000000')
    }
    .padding({ left: 18, right: 18, top: 6 })
  }

  // ===== 结果态：视频排序行（5 个排序 chips + 右侧筛选按钮） =====
  @Builder
  VideoSortRow() {
    Row() {
      Scroll() {
        Row() {
          ForEach(VIDEO_ORDER_OPTIONS, (opt: SearchOption) => {
            this.Chip(opt.label, this.videoOrder === opt.value, () => {
              this.videoOrder = opt.value;
              this.doSearch(true);
            })
          }, (opt: SearchOption) => opt.value)
        }
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)

      Row({ space: 3 }) {
        Image($r('app.media.ic_filter'))
          .width(13)
          .height(13)
          .fillColor(this.hasVideoFilter() ? this.accent : (this.isDark ? '#C6C7CB' : '#61666D'))
        Text('筛选')
          .fontSize(12)
          .fontColor(this.hasVideoFilter() ? this.accent : (this.isDark ? '#C6C7CB' : '#61666D'))
      }
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.isDark ? '#2E3136' : '#ECEEF0')
      .borderRadius(14)
      .margin({ left: 4, bottom: 8 })
      .onClick(() => {
        this.tmpDuration = this.filterDuration;
        this.tmpPubtime = this.filterPubtime;
        this.tmpTids = this.filterTids;
        this.showFilter = true;
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2 })
  }

  // ===== 结果态：用户排序行 =====
  @Builder
  UserSortRow() {
    Row() {
      ForEach(USER_ORDER_OPTIONS, (opt: SearchOption) => {
        this.Chip(opt.label, this.userOrder === opt.value, () => {
          this.userOrder = opt.value;
          this.doSearch(true);
        })
      }, (opt: SearchOption) => opt.label)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2 })
  }

  // ===== 结果态：筛选面板单选组（kind: 0 发布时间 1 时长 2 分区） =====
  @Builder
  FilterGroup(title: string, options: Array<SearchNumOption>, selected: number, kind: number) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(13)
        .fontColor(this.isDark ? '#C6C7CB' : '#61666D')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(options, (opt: SearchNumOption, idx: number) => {
          this.Chip(opt.label, kind === 2 ? opt.value === selected : idx === selected, () => {
            if (kind === 0) {
              this.tmpPubtime = idx;
            } else if (kind === 1) {
              this.tmpDuration = idx;
            } else {
              this.tmpTids = opt.value;
            }
          })
        }, (opt: SearchNumOption) => String(opt.value))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 结果态：筛选面板（bindSheet 底部弹层） =====
  @Builder
  FilterPanel() {
    Column({ space: 16 }) {
      Text('筛选')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .width('100%')
        .textAlign(TextAlign.Center)

      this.FilterGroup('发布时间', VIDEO_PUBTIME_OPTIONS, this.tmpPubtime, 0)
      this.FilterGroup('时长', VIDEO_DURATION_OPTIONS, this.tmpDuration, 1)
      this.FilterGroup('分区', VIDEO_ZONE_OPTIONS, this.tmpTids, 2)

      Row({ space: 12 }) {
        Text('重置')
          .fontSize(14)
          .fontColor(this.isDark ? '#C6C7CB' : '#61666D')
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.isDark ? '#2E3136' : '#ECEEF0')
          .borderRadius(18)
          .onClick(() => {
            this.tmpDuration = 0;
            this.tmpPubtime = 0;
            this.tmpTids = 0;
          })
        Text('完成')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .padding({ top: 9, bottom: 9 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.accent)
          .borderRadius(18)
          .onClick(() => {
            this.filterDuration = this.tmpDuration;
            this.filterPubtime = this.tmpPubtime;
            this.filterTids = this.tmpTids;
            this.showFilter = false;
            this.doSearch(true);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
  }

  @Builder
  ResultRow(item: VideoItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.cover)
          .width(130)
          .height(74)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
        Text(item.playText + ' · ' + item.danmakuText)
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#88000000')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .margin({ right: 4, bottom: 4 })
      }
      .width(130)
      .clip(true)
      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(13)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
        Text(item.upName)
          .fontSize(11)
          .fontColor('#9499A0')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .onClick(() => {
      const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
      AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
    })
  }

  // ===== 结果态：用户卡片（头像 + 昵称 + 等级/认证 + 粉丝/视频数 + 简介） =====
  @Builder
  UserRow(item: UserSearchItem) {
    Row({ space: 10 }) {
      Image(item.face)
        .width(52)
        .height(52)
        .borderRadius(26)
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(item.uname)
            .fontSize(14)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 150 })
          Text('Lv' + item.level)
            .fontSize(10)
            .fontColor(this.accent)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor(this.isDark ? '#33FB7299' : '#1AFB7299')
            .borderRadius(3)
          if (item.verifyDesc.length > 0) {
            Text(item.verifyDesc)
              .fontSize(10)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        Text('粉丝 ' + formatCount(item.fans) + ' · 视频 ' + formatCount(item.videos))
          .fontSize(11)
          .fontColor('#9499A0')
        if (item.usign.length > 0) {
          Text(item.usign)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .onClick(() => {
      const param: UserSpaceParam = { mid: item.mid };
      AppNavStack.pushPathByName(NAV_USER_SPACE, param);
    })
  }

  // ===== 结果态：底部"加载更多" =====
  @Builder
  LoadMoreFooter() {
    Row() {
      if (this.loadingMore) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(this.accent)
      } else {
        Text('加载更多')
          .fontSize(13)
          .fontColor(this.accent)
          .onClick(() => {
            this.loadingMore = true;
            this.doSearch(false);
          })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 20 })
  }

  // ===== 结果态：视频 Tab 内容 =====
  @Builder
  VideoResultTab() {
    Column() {
      this.VideoSortRow()
      if (this.loading) {
        LoadingView({ loading: true })
      } else if (this.results.length === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: '没有找到相关视频',
          onRetry: () => {
            this.doSearch(true);
          },
        })
      } else {
        List() {
          ForEach(this.results, (item: VideoItem) => {
            ListItem() {
              this.ResultRow(item)
            }
          }, (item: VideoItem) => item.bvid + String(item.aid))
          ListItem() {
            this.LoadMoreFooter()
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：用户 Tab 内容 =====
  @Builder
  UserResultTab() {
    Column() {
      this.UserSortRow()
      if (this.loading) {
        LoadingView({ loading: true })
      } else if (this.userResults.length === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: '没有找到相关用户',
          onRetry: () => {
            this.doSearch(true);
          },
        })
      } else {
        List() {
          ForEach(this.userResults, (item: UserSearchItem) => {
            ListItem() {
              this.UserRow(item)
            }
          }, (item: UserSearchItem) => String(item.mid))
          ListItem() {
            this.LoadMoreFooter()
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        // 顶部搜索栏
        Row({ space: 8 }) {
          this.BackButton()
          Row({ space: 6 }) {
            Image($r('app.media.ic_search'))
              .width(21)
              .height(21)
              .fillColor(this.accent)
            TextInput({ placeholder: this.suggestedKeyword.length > 0 ? this.suggestedKeyword : '搜索视频', text: this.keyword })
              .height(36)
              .layoutWeight(1)
              .fontSize(14)
              .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
              .placeholderColor('#9499A0')
              .backgroundColor('#00000000')
              .onChange((value: string) => {
                this.onInput(value);
              })
              .onSubmit(() => {
                this.submitSearch();
              })
          }
          .height(36)
          .layoutWeight(1)
          .padding({ left: 10, right: 10 })
          .borderRadius(18)
          .backgroundColor(this.isDark ? '#4DFFFFFF' : '#B3FFFFFF')
          .backgroundBlurStyle(AppTheme.floatBlur(this.glassOn, this.glassLevel))
          .border({ width: 0.5, color: this.isDark ? '#2EFFFFFF' : '#26000000' })
          Text('搜索')
            .fontSize(14)
            .fontColor(this.accent)
            .onClick(() => {
              this.submitSearch();
            })
        }
        .width('100%')
        .padding({ left: 10, right: 12, top: Immersive.statusBarHeight() + 6, bottom: 8 })

        if (this.searching) {
          // 结果态：视频 | 用户 二级 Tab
          Tabs({ barPosition: BarPosition.Start, index: $$this.searchTab }) {
            TabContent() {
              this.VideoResultTab()
            }
            .tabBar(this.ResultTabBar(0, this.videoTotal >= 0 ? '视频 ' + formatCount(this.videoTotal) : '视频'))
            TabContent() {
              this.UserResultTab()
            }
            .tabBar(this.ResultTabBar(1, this.userTotal >= 0 ? '用户 ' + formatCount(this.userTotal) : '用户'))
          }
          .barHeight(40)
          .divider(null)
          .animationDuration(200)
          .onChange((index: number) => {
            this.onTabChanged(index);
          })
          .width('100%')
          .layoutWeight(1)
        } else if (this.showSuggest) {
          Column() {
            this.SuggestList()
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          if (this.history.length > 0) {
            this.SearchHistory()
          }
          this.HotList()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .bindSheet($$this.showFilter, this.FilterPanel(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      radius: { topLeft: 20, topRight: 20 },
      backgroundColor: AppTheme.sheetBg(this.isDark, this.glassOn),
      blurStyle: AppTheme.sheetBlur(this.glassOn, this.glassLevel),
    })
  }
}
