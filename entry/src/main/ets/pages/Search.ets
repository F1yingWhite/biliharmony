/**
 * 搜索页：热搜榜 / 搜索建议 / 搜索结果
 * 结果态：综合 | 视频 | 番剧 | 影视 | 直播 | 专栏 | 用户 二级 Tab
 * （综合走 search/all/v2 分区混排，其余走 search/type；视频带排序 chips + 筛选面板）
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, ArticlePageParam, LiveRoomParam, NAV_ARTICLE, NAV_BANGUMI_DETAIL, NAV_LIVE_ROOM,
  NAV_VIDEO_DETAIL, NAV_USER_SPACE, BangumiDetailParam, VideoDetailParam, UserSpaceParam } from '../common/AppRouter';
import {
  VideoItem, HotSearchItem, UserSearchItem, SearchOption, SearchNumOption, VideoSearchResult, UserSearchResult,
  PgcSearchItem, PgcSearchResult, ArticleSearchItem, ArticleSearchResult, SearchAllResult, SearchAllSection,
  SearchTypes, VIDEO_ORDER_OPTIONS, USER_ORDER_OPTIONS, USER_TYPE_OPTIONS, LIVE_ORDER_OPTIONS,
  VIDEO_DURATION_OPTIONS, VIDEO_PUBTIME_OPTIONS, VIDEO_ZONE_OPTIONS
} from '../model/Models';
import { LiveRoomItem, LiveSearchResult } from '../model/LiveModels';
import { BiliApi } from '../api/BiliApi';
import { LoadingView } from '../components/LoadingView';
import { BackButton } from '../components/BackButton';
import { FilterChip } from '../components/FilterChip';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { SearchResultList } from '../components/SearchResultList';
import { VideoRowCard } from '../components/VideoRowCard';
import { VideoCard } from '../components/VideoCard';
import { LiveRoomCard } from '../components/LiveRoomCard';
import { formatCount } from '../common/Utils';
import { AppTheme } from '../common/AppTheme';
import { BasicDataSource } from '../common/BasicDataSource';
import { HotSearchStore } from '../common/HotSearchStore';
import { SearchHistoryStore } from '../common/SearchHistoryStore';
import { LayoutTokens } from '../common/LayoutTokens';
import { inputMethod } from '@kit.IMEKit';
import { SearchApi } from '../api/SearchApi';

@Component
export struct SearchPage {
  @State keyword: string = '';
  @State hotList: Array<HotSearchItem> = [];
  @State trendingList: Array<HotSearchItem> = [];
  @State suggests: Array<string> = [];
  // ===== 结果态 =====
  @State searching: boolean = false;
  @State searchTab: number = 0;              // 0 综合 1 视频 2 番剧 3 影视 4 直播 5 专栏 6 用户
  @State videoTotal: number = -1;            // numResults 总数徽标，-1 未加载
  @State userTotal: number = -1;
  @State bangumiTotal: number = -1;
  @State ftTotal: number = -1;
  @State liveTotal: number = -1;
  @State articleTotal: number = -1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State allPage: number = 1;
  @State videoPage: number = 1;
  @State userPage: number = 1;
  @State bangumiPage: number = 1;
  @State ftPage: number = 1;
  @State livePage: number = 1;
  @State articlePage: number = 1;
  @State videoOrder: string = 'totalrank';
  @State userOrder: string = '';
  @State userType: number = 0;
  @State liveOrder: string = 'online';
  @State filterDuration: number = 0;         // VIDEO_DURATION_OPTIONS 下标
  @State filterPubtime: number = 0;          // VIDEO_PUBTIME_OPTIONS 下标
  @State filterTids: number = 0;             // 分区 id，0 不限
  @State showFilter: boolean = false;
  @State tmpDuration: number = 0;            // 筛选面板中的暂存值，点"完成"后生效
  @State tmpPubtime: number = 0;
  @State tmpTids: number = 0;
  @State showSuggest: boolean = false;
  @State history: Array<string> = [];
  // 综合 Tab 分区列表（all/v2 聚合结果，整体替换触发刷新）
  @State allSections: Array<SearchAllSection> = [];
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('searchSuggestedKeyword') suggestedKeyword: string = '';
  private resultsSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private userSource: BasicDataSource<UserSearchItem> = new BasicDataSource<UserSearchItem>();
  private bangumiSource: BasicDataSource<PgcSearchItem> = new BasicDataSource<PgcSearchItem>();
  private ftSource: BasicDataSource<PgcSearchItem> = new BasicDataSource<PgcSearchItem>();
  private liveSource: BasicDataSource<LiveRoomItem> = new BasicDataSource<LiveRoomItem>();
  private articleSource: BasicDataSource<ArticleSearchItem> = new BasicDataSource<ArticleSearchItem>();
  // 搜索建议：300ms 防抖 + 请求序号（慢响应乱序到达时丢弃旧结果）
  private suggestTimer: number = -1;
  private suggestSeq: number = 0;
  // 结果请求防重入；destroyed 阻止销毁后异步回调写 @State
  private searchInflight: boolean = false;
  private pendingResetSearch: boolean = false;
  private destroyed: boolean = false;

  async aboutToAppear(): Promise<void> {
    this.destroyed = false;
    this.history = await SearchHistoryStore.ensureLoaded();
    this.loadHotSearch().catch(() => {
    });
    // 拉取 B 站搜索默认词作为占位（失败时保持现有占位不变）。
    const def: string = await SearchApi.getSearchDefault();
    if (this.destroyed || def.length === 0) {
      return;
    }
    if (this.suggestedKeyword.length === 0) {
      AppStorage.setOrCreate<string>('searchSuggestedKeyword', def);
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.suggestTimer >= 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
  }

  async loadHotSearch(): Promise<void> {
    const list: Array<HotSearchItem> = await HotSearchStore.load();
    if (this.destroyed) {
      return;
    }
    this.hotList = list;
    // 趋势榜独立拉取（轻量、失败不阻塞热搜展示）。
    SearchApi.getSearchTrending().then((trending: Array<HotSearchItem>) => {
      if (!this.destroyed && trending.length > 0) {
        this.trendingList = trending;
      }
    }).catch(() => {
    });
  }

  onInput(value: string): void {
    this.keyword = value;
    this.suggestSeq++;
    if (this.suggestTimer >= 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    if (value.length === 0) {
      // 清空输入回到热搜/历史首页面；searching 若不复位，结果 Tabs 会一直霸屏。
      this.searching = false;
      this.showSuggest = false;
      this.suggests = [];
      return;
    }
    const seq: number = this.suggestSeq;
    this.suggestTimer = setTimeout(() => {
      this.suggestTimer = -1;
      this.fetchSuggest(value, seq).catch(() => {
      });
    }, 300);
  }

  async fetchSuggest(value: string, seq: number): Promise<void> {
    const s: Array<string> = await SearchApi.searchSuggest(value);
    if (this.destroyed || seq !== this.suggestSeq) {
      return;
    }
    this.suggests = s;
    this.showSuggest = s.length > 0;
  }

  private loadMoreSearch(): void {
    if (this.loadingMore === false && this.searchInflight === false) {
      this.doSearch(false).catch(() => {
      });
    }
  }

  async doSearch(reset: boolean): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    if (this.searchInflight) {
      // 用户在旧请求中切换关键词/Tab/排序时，保留最后一次首页请求，不让新操作被并发守卫吞掉。
      if (reset) this.pendingResetSearch = true;
      return;
    }
    this.searchInflight = true;
    this.showSuggest = false;
    this.searching = true;
    this.loading = reset;
    if (!reset) {
      this.loadingMore = true;
    }
    try {
      if (this.searchTab === 0) {
        // 综合：聚合分区混排；page>1 只返回视频分区，追加进已有视频分区
        if (reset) {
          this.allPage = 1;
        }
        const page: number = this.allPage;
        const res: SearchAllResult = await SearchApi.searchAll(kw, page);
        if (this.destroyed) {
          return;
        }
        if (reset) {
          this.allSections = res.sections;
        } else {
          this.allSections = this.mergeAllSections(this.allSections, res.sections);
        }
        this.applyAllTotals(res.totals);
        this.allPage = page + 1;
      } else if (this.searchTab === 1) {
        if (reset) {
          this.videoPage = 1;
        }
        const page: number = this.videoPage;
        // 发布时间筛选：客户端换算为秒级时间戳起点
        let pubtimeBegin: number = 0;
        if (this.filterPubtime > 0) {
          pubtimeBegin = Math.floor(Date.now() / 1000) - VIDEO_PUBTIME_OPTIONS[this.filterPubtime].value;
        }
        const res: VideoSearchResult = await SearchApi.searchVideosByType(kw, page, this.videoOrder,
          VIDEO_DURATION_OPTIONS[this.filterDuration].value, pubtimeBegin, this.filterTids);
        if (this.destroyed) {
          return;
        }
        if (reset) {
          this.resultsSource.reset(res.videos);
        } else {
          // 分类搜索同样可能跨页重复（排序漂移），追加前去重防 ForEach 键冲突。
          const existing: Set<string> = new Set<string>();
          const cur: Array<VideoItem> = this.resultsSource.getAll();
          for (let i: number = 0; i < cur.length; i++) {
            existing.add(cur[i].bvid + String(cur[i].aid));
          }
          this.resultsSource.append(res.videos.filter((v: VideoItem) => !existing.has(v.bvid + String(v.aid))));
        }
        this.videoTotal = res.numResults;
        this.videoPage = page + 1;
      } else if (this.searchTab === 2 || this.searchTab === 3) {
        // 番剧 / 影视：同一接口不同 search_type
        const isBangumi: boolean = this.searchTab === 2;
        if (reset) {
          if (isBangumi) {
            this.bangumiPage = 1;
          } else {
            this.ftPage = 1;
          }
        }
        const page: number = isBangumi ? this.bangumiPage : this.ftPage;
        const res: PgcSearchResult = await SearchApi.searchMedia(kw,
          isBangumi ? SearchTypes.mediaBangumi : SearchTypes.mediaFt, page);
        if (this.destroyed) {
          return;
        }
        if (reset) {
          this.mediaSource(isBangumi).reset(res.items);
        } else {
          this.mediaSource(isBangumi).append(res.items);
        }
        if (isBangumi) {
          this.bangumiTotal = res.numResults;
          this.bangumiPage = page + 1;
        } else {
          this.ftTotal = res.numResults;
          this.ftPage = page + 1;
        }
      } else if (this.searchTab === 4) {
        if (reset) {
          this.livePage = 1;
        }
        const page: number = this.livePage;
        const res: LiveSearchResult = await SearchApi.searchLiveRooms(kw, page, this.liveOrder);
        if (this.destroyed) {
          return;
        }
        if (reset) {
          this.liveSource.reset(res.rooms);
        } else {
          this.liveSource.append(res.rooms);
        }
        this.liveTotal = res.numResults;
        this.livePage = page + 1;
      } else if (this.searchTab === 5) {
        if (reset) {
          this.articlePage = 1;
        }
        const page: number = this.articlePage;
        const res: ArticleSearchResult = await SearchApi.searchArticles(kw, page);
        if (this.destroyed) {
          return;
        }
        if (reset) {
          this.articleSource.reset(res.articles);
        } else {
          this.articleSource.append(res.articles);
        }
        this.articleTotal = res.numResults;
        this.articlePage = page + 1;
      } else {
        if (reset) {
          this.userPage = 1;
        }
        const page: number = this.userPage;
        const res: UserSearchResult = await SearchApi.searchUsers(kw, page, this.userOrder, this.userType);
        if (this.destroyed) {
          return;
        }
        if (reset) {
          this.userSource.reset(res.users);
        } else {
          this.userSource.append(res.users);
        }
        this.userTotal = res.numResults;
        this.userPage = page + 1;
      }
    } finally {
      this.searchInflight = false;
      this.loading = false;
      this.loadingMore = false;
      if (this.pendingResetSearch && !this.destroyed) {
        this.pendingResetSearch = false;
        this.doSearch(true).catch(() => {
        });
      }
    }
  }

  /** 综合搜索翻页合并：后续页只含视频分区，并入现有视频分区（新建数组触发 @State 刷新）。 */
  private mergeAllSections(current: Array<SearchAllSection>,
    incoming: Array<SearchAllSection>): Array<SearchAllSection> {
    let videoIncoming: SearchAllSection | null = null;
    for (let i: number = 0; i < incoming.length; i++) {
      if (incoming[i].type === SearchTypes.video) {
        videoIncoming = incoming[i];
      }
    }
    if (videoIncoming === null) {
      return current;
    }
    const out: Array<SearchAllSection> = [];
    let merged: boolean = false;
    const videos: Array<VideoItem> = (videoIncoming as SearchAllSection).videos;
    for (let i: number = 0; i < current.length; i++) {
      const section: SearchAllSection = current[i];
      if (section.type === SearchTypes.video) {
        // 搜索排序漂移会让相邻页返回重复稿件；合并时按键去重，
        // 否则 ForEach 键冲突会导致整个视频分区停止渲染。
        const existing: Set<string> = new Set<string>();
        for (let k: number = 0; k < section.videos.length; k++) {
          existing.add(section.videos[k].bvid + String(section.videos[k].aid));
        }
        const fresh: Array<VideoItem> = videos.filter((v: VideoItem) => !existing.has(v.bvid + String(v.aid)));
        const ns: SearchAllSection = new SearchAllSection();
        ns.type = section.type;
        ns.videos = section.videos.concat(fresh);
        out.push(ns);
        merged = true;
      } else {
        out.push(section);
      }
    }
    if (!merged) {
      out.push(videoIncoming);
    }
    return out;
  }

  /** all/v2 的 pageinfo 提供各分类结果总数，同步到对应 Tab 徽标。 */
  private applyAllTotals(totals: Map<string, number>): void {
    const video: number | undefined = totals.get(SearchTypes.video);
    if (video !== undefined) {
      this.videoTotal = video;
    }
    const user: number | undefined = totals.get(SearchTypes.biliUser);
    if (user !== undefined) {
      this.userTotal = user;
    }
    const bangumi: number | undefined = totals.get(SearchTypes.mediaBangumi);
    if (bangumi !== undefined) {
      this.bangumiTotal = bangumi;
    }
    const ft: number | undefined = totals.get(SearchTypes.mediaFt);
    if (ft !== undefined) {
      this.ftTotal = ft;
    }
    const live: number | undefined = totals.get(SearchTypes.liveRoom);
    if (live !== undefined) {
      this.liveTotal = live;
    }
    const article: number | undefined = totals.get(SearchTypes.article);
    if (article !== undefined) {
      this.articleTotal = article;
    }
  }

  private mediaSource(isBangumi: boolean): BasicDataSource<PgcSearchItem> {
    return isBangumi ? this.bangumiSource : this.ftSource;
  }

  // 新关键词搜索：清空各分类缓存与徽标，回到综合 Tab 重新加载
  submitSearch(): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0 && this.suggestedKeyword.length > 0) {
      this.keyword = this.suggestedKeyword;
    }
    if (this.keyword.trim().length === 0) return;
    // 结果页露出前收起输入法，避免键盘遮挡半屏结果列表。
    inputMethod.getController().hideTextInput().catch(() => {
    });
    this.history = SearchHistoryStore.add(this.keyword);
    this.resultsSource.clear();
    this.userSource.clear();
    this.bangumiSource.clear();
    this.ftSource.clear();
    this.liveSource.clear();
    this.articleSource.clear();
    this.allSections = [];
    this.videoTotal = -1;
    this.userTotal = -1;
    this.bangumiTotal = -1;
    this.ftTotal = -1;
    this.liveTotal = -1;
    this.articleTotal = -1;
    this.searchTab = 0;
    this.doSearch(true).catch(() => {
    });
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
    const needLoad: boolean =
      (index === 0 && this.allSections.length === 0) ||
      (index === 1 && this.resultsSource.isEmpty()) ||
      (index === 2 && this.bangumiSource.isEmpty()) ||
      (index === 3 && this.ftSource.isEmpty()) ||
      (index === 4 && this.liveSource.isEmpty()) ||
      (index === 5 && this.articleSource.isEmpty()) ||
      (index === 6 && this.userSource.isEmpty());
    if (needLoad) {
      this.doSearch(true).catch(() => {
      });
    }
  }

  hasVideoFilter(): boolean {
    return this.filterDuration > 0 || this.filterPubtime > 0 || this.filterTids > 0;
  }

  @Builder
  HotList() {
    Column() {
      List() {
        ListItemGroup({ header: this.HotSectionHeader('热搜榜') }) {
          ForEach(this.hotList, (item: HotSearchItem, index: number) => {
            ListItem() {
              this.HotRow(item, index)
            }
          }, (item: HotSearchItem) => 'hot' + item.keyword)
        }
        if (this.trendingList.length > 0) {
          ListItemGroup({ header: this.HotSectionHeader('趋势榜') }) {
            ForEach(this.trendingList, (item: HotSearchItem, index: number) => {
              ListItem() {
                this.HotRow(item, index)
              }
            }, (item: HotSearchItem) => 'trend' + item.keyword)
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
      .alignSelf(ItemAlign.Center)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  HotSectionHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 6 })
  }

  @Builder
  HotRow(item: HotSearchItem, index: number) {
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
    .padding({ left: 13, right: 13, top: 6 })
    .animation({ duration: 180, curve: Curve.EaseOut })
  }

  // ===== 结果态：视频排序行（5 个排序 chips + 右侧筛选按钮） =====
  @Builder
  VideoSortRow() {
    Row() {
      Scroll() {
        Row() {
          ForEach(VIDEO_ORDER_OPTIONS, (opt: SearchOption) => {
            FilterChip({
              label: opt.label,
              selected: this.videoOrder === opt.value,
              bottomMargin: 8,
              onTap: () => {
                this.videoOrder = opt.value;
                this.doSearch(true).catch(() => {
                });
              },
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

  // ===== 结果态：用户类型筛选 + 排序 =====
  @Builder
  UserSortRow() {
    Column({ space: 8 }) {
      Row() {
        ForEach(USER_TYPE_OPTIONS, (opt: SearchOption) => {
          FilterChip({
            label: opt.label,
            selected: this.userType === Number(opt.value),
            bottomMargin: 0,
            onTap: () => {
              this.userType = Number(opt.value);
              this.doSearch(true).catch(() => {
              });
            },
          })
        }, (opt: SearchOption) => 'ut' + opt.label)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })
      Row() {
        ForEach(USER_ORDER_OPTIONS, (opt: SearchOption) => {
          FilterChip({
            label: opt.label,
            selected: this.userOrder === opt.value,
            bottomMargin: 8,
            onTap: () => {
              this.userOrder = opt.value;
              this.doSearch(true).catch(() => {
              });
            },
          })
        }, (opt: SearchOption) => opt.label)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })
    }
    .width('100%')
  }

  // ===== 结果态：直播排序行（人气 / 最新开播） =====
  @Builder
  LiveSortRow() {
    Row() {
      ForEach(LIVE_ORDER_OPTIONS, (opt: SearchOption) => {
        FilterChip({
          label: opt.label,
          selected: this.liveOrder === opt.value,
          bottomMargin: 8,
          onTap: () => {
            this.liveOrder = opt.value;
            this.doSearch(true).catch(() => {
            });
          },
        })
      }, (opt: SearchOption) => opt.value)
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
          FilterChip({
            label: opt.label,
            selected: kind === 2 ? opt.value === selected : idx === selected,
            bottomMargin: 8,
            onTap: () => {
              if (kind === 0) {
                this.tmpPubtime = idx;
              } else if (kind === 1) {
                this.tmpDuration = idx;
              } else {
                this.tmpTids = opt.value;
              }
            },
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
            this.doSearch(true).catch(() => {
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
  }

  // ===== 结果态：用户卡片（头像 + 昵称 + 等级/认证 + 粉丝/视频数 + 简介） =====
  private openUserSpace(item: UserSearchItem): void {
    const param: UserSpaceParam = { mid: item.mid };
    AppNavStack.pushPathByName(NAV_USER_SPACE, param);
  }

  private openUserLive(item: UserSearchItem): void {
    if (item.liveStatus !== 1 || item.liveRoomId <= 0) {
      this.openUserSpace(item);
      return;
    }
    const param: LiveRoomParam = {
      roomId: item.liveRoomId, uid: item.mid, title: '', uname: item.uname, face: item.face, cover: '',
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  @Builder
  UserRow(item: UserSearchItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(item.face.length > 0 ? item.face : $r('app.media.placeholder_avatar_noface'))
          .width(52)
          .height(52)
          .borderRadius(26)
          .objectFit(ImageFit.Cover)
        if (item.liveStatus === 1 && item.liveRoomId > 0) {
          Text('直播')
            .width(38).height(17).textAlign(TextAlign.Center)
            .fontSize(10).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
            .backgroundColor(this.accent).borderRadius(9)
        }
      }
      .width(56).height(58)
      .onClick(() => this.openUserLive(item))
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
      .onClick(() => this.openUserSpace(item))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  }

  // ===== 结果态：视频 Tab 内容 =====
  @Builder
  VideoListContent() {
    LazyForEach(this.resultsSource, (item: VideoItem) => {
      ListItem() {
        VideoRowCard({
          cover: item.cover,
          title: item.title,
          upName: item.upName,
          overlayText: item.playText + ' · ' + item.danmakuText,
          compact: true,
          onTap: () => {
            const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
            AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
          },
        })
      }
    }, (item: VideoItem) => item.bvid + String(item.aid))
  }

  @Builder
  VideoResultTab() {
    Column() {
      this.VideoSortRow()
      SearchResultList({
        loading: this.loading,
        loadingMore: this.loadingMore,
        count: this.resultsSource.totalCount(),
        emptyText: '没有找到相关视频',
        onRetry: (): void => {
          this.doSearch(true).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.loadMoreSearch();
        },
        content: (): void => {
          this.VideoListContent()
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：用户 Tab 内容 =====
  @Builder
  UserListContent() {
    LazyForEach(this.userSource, (item: UserSearchItem) => {
      ListItem() {
        this.UserRow(item)
      }
    }, (item: UserSearchItem) => String(item.mid))
  }

  @Builder
  UserResultTab() {
    Column() {
      this.UserSortRow()
      SearchResultList({
        loading: this.loading,
        loadingMore: this.loadingMore,
        count: this.userSource.totalCount(),
        emptyText: '没有找到相关用户',
        onRetry: (): void => {
          this.doSearch(true).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.loadMoreSearch();
        },
        content: (): void => {
          this.UserListContent()
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：番剧/影视卡片（番剧 Tab、影视 Tab、综合分区共用） =====
  @Builder
  PgcRow(item: PgcSearchItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image(item.cover)
          .width(84)
          .height(112)
          .objectFit(ImageFit.Cover)
        if (item.seasonTypeName.length > 0) {
          Text(item.seasonTypeName)
            .fontSize(9)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accent)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius({ topLeft: 6, bottomRight: 6 })
        }
      }
      .width(84)
      .height(112)
      .clip(true)
      .borderRadius(6)
      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          if (item.scoreText().length > 0) {
            Text(item.scoreText())
              .fontSize(11)
              .fontColor(this.accent)
          }
          if (item.indexShow.length > 0) {
            Text(item.indexShow)
              .fontSize(11)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        if (item.areas.length > 0 || item.styles.length > 0) {
          Text((item.areas.length > 0 ? item.areas : '') +
            (item.areas.length > 0 && item.styles.length > 0 ? ' · ' : '') + item.styles)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (item.desc.length > 0) {
          Text(item.desc)
            .fontSize(11)
            .fontColor('#B0B3B8')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .onClick(() => {
      const param: BangumiDetailParam = { seasonId: item.seasonId, epId: 0, title: item.title };
      AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
    })
  }

  // ===== 结果态：番剧 / 影视 Tab 内容（isBangumi 区分 search_type 与数据源） =====
  @Builder
  BangumiListContent() {
    LazyForEach(this.bangumiSource, (item: PgcSearchItem) => {
      ListItem() {
        this.PgcRow(item)
      }
    }, (item: PgcSearchItem) => String(item.seasonId))
  }

  @Builder
  FtListContent() {
    LazyForEach(this.ftSource, (item: PgcSearchItem) => {
      ListItem() {
        this.PgcRow(item)
      }
    }, (item: PgcSearchItem) => String(item.seasonId))
  }

  @Builder
  MediaResultTab(isBangumi: boolean, emptyText: string) {
    Column() {
      SearchResultList({
        loading: this.loading,
        loadingMore: this.loadingMore,
        count: this.mediaSource(isBangumi).totalCount(),
        emptyText: emptyText,
        onRetry: (): void => {
          this.doSearch(true).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.loadMoreSearch();
        },
        content: (): void => {
          if (isBangumi) {
            this.BangumiListContent()
          } else {
            this.FtListContent()
          }
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：直播 Tab 内容（双列直播间卡片 + 排序 chips） =====
  @Builder
  LiveListContent() {
    LazyForEach(this.liveSource, (item: LiveRoomItem) => {
      ListItem() {
        LiveRoomCard({ room: item })
      }
    }, (item: LiveRoomItem) => String(item.roomId))
  }

  @Builder
  LiveResultTab() {
    Column() {
      this.LiveSortRow()
      SearchResultList({
        loading: this.loading,
        loadingMore: this.loadingMore,
        count: this.liveSource.totalCount(),
        emptyText: '没有找到相关直播间',
        listSpace: 10,
        lanes: 2,
        horizontalPadding: 12,
        onRetry: (): void => {
          this.doSearch(true).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.loadMoreSearch();
        },
        content: (): void => {
          this.LiveListContent()
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：专栏卡片（应用内 Web 阅读页） =====
  private openArticle(item: ArticleSearchItem): void {
    const param: ArticlePageParam = { id: item.id, title: item.title };
    AppNavStack.pushPathByName(NAV_ARTICLE, param);
  }

  @Builder
  ArticleRow(item: ArticleSearchItem) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(13)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
        if (item.desc.length > 0) {
          Text(item.desc)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text((item.upName.length > 0 ? item.upName + ' · ' : '') +
          formatCount(item.view) + '阅读 · ' + formatCount(item.reply) + '评论')
          .fontSize(11)
          .fontColor('#B0B3B8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (item.cover.length > 0) {
        Image(item.cover)
          .width(110)
          .height(74)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .onClick(() => {
      this.openArticle(item);
    })
  }

  // ===== 结果态：专栏 Tab 内容 =====
  @Builder
  ArticleListContent() {
    LazyForEach(this.articleSource, (item: ArticleSearchItem) => {
      ListItem() {
        this.ArticleRow(item)
      }
    }, (item: ArticleSearchItem) => String(item.id))
  }

  @Builder
  ArticleResultTab() {
    Column() {
      SearchResultList({
        loading: this.loading,
        loadingMore: this.loadingMore,
        count: this.articleSource.totalCount(),
        emptyText: '没有找到相关专栏',
        onRetry: (): void => {
          this.doSearch(true).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.loadMoreSearch();
        },
        content: (): void => {
          this.ArticleListContent()
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：综合 Tab 分区小标题 =====
  @Builder
  AllSectionHeader(type: string) {
    Text(type === SearchTypes.video ? '视频' :
      (type === SearchTypes.biliUser ? '用户' : (type === SearchTypes.mediaBangumi ? '番剧' : '影视')))
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 4 })
  }

  // ===== 结果态：综合 Tab 用户分区（横滑行，跳用户空间） =====
  @Builder
  AllUserRow(section: SearchAllSection) {
    Scroll() {
      Row({ space: 16 }) {
        ForEach(section.users, (user: UserSearchItem) => {
          Column({ space: 6 }) {
            Image(user.face.length > 0 ? user.face : $r('app.media.placeholder_avatar_noface'))
              .width(52)
              .height(52)
              .borderRadius(26)
              .objectFit(ImageFit.Cover)
            Text(user.uname)
              .fontSize(12)
              .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 72 })
          }
          .width(72)
          .onClick(() => {
            this.openUserSpace(user);
          })
        }, (user: UserSearchItem) => String(user.mid))
      }
      .padding({ left: 14, right: 14, top: 4, bottom: 10 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  // ===== 结果态：综合 Tab 视频分区（双列卡片流） =====
  @Builder
  AllVideoGrid(section: SearchAllSection) {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
      ForEach(section.videos, (item: VideoItem) => {
        Column() {
          VideoCard({ video: item, idPrefix: 'search-' })
        }
        .width('48.5%')
      }, (item: VideoItem) => item.bvid + String(item.aid))
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
  }

  // ===== 结果态：综合 Tab 内容（番剧/影视分区 + 用户横滑行 + 视频双列流） =====
  @Builder
  AllResultTab() {
    Column() {
      if (this.loading) {
        LoadingView({ loading: true })
      } else if (this.allSections.length === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: '没有找到相关内容',
          onRetry: () => {
            this.doSearch(true).catch(() => {
            });
          },
        })
      } else {
        List() {
          ForEach(this.allSections, (section: SearchAllSection) => {
            ListItemGroup({ header: this.AllSectionHeader(section.type) }) {
              if (section.type === SearchTypes.biliUser) {
                ListItem() {
                  this.AllUserRow(section)
                }
              } else if (section.type === SearchTypes.mediaBangumi || section.type === SearchTypes.mediaFt) {
                ForEach(section.pgc, (item: PgcSearchItem) => {
                  ListItem() {
                    this.PgcRow(item)
                  }
                }, (item: PgcSearchItem) => String(item.seasonId))
              } else if (section.type === SearchTypes.video) {
                ListItem() {
                  this.AllVideoGrid(section)
                }
              }
            }
          }, (section: SearchAllSection) => section.type)
          ListItem() {
            LoadMoreFooter({
              loading: this.loadingMore,
              hasMore: true,
              moreText: this.loadingMore ? '' : '上滑加载更多',
              endText: '',
              fixedHeight: 44,
              onLoadMore: () => {
                this.loadMoreSearch();
              },
            })
          }
        }
        .width('100%')
        .height('100%')
        .cachedCount(5)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.loadMoreSearch();
        })
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
          BackButton()
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
          .backgroundBlurStyle(AppTheme.floatBlur(this.glassOn))
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
          // 结果态：综合 | 视频 | 番剧 | 影视 | 直播 | 专栏 | 用户 二级 Tab
          Tabs({ barPosition: BarPosition.Start, index: $$this.searchTab }) {
            TabContent() {
              this.AllResultTab()
            }
            .tabBar(this.ResultTabBar(0, '综合'))
            TabContent() {
              this.VideoResultTab()
            }
            .tabBar(this.ResultTabBar(1, this.videoTotal >= 0 ? '视频 ' + formatCount(this.videoTotal) : '视频'))
            TabContent() {
              this.MediaResultTab(true, '没有找到相关番剧')
            }
            .tabBar(this.ResultTabBar(2, this.bangumiTotal >= 0 ? '番剧 ' + formatCount(this.bangumiTotal) : '番剧'))
            TabContent() {
              this.MediaResultTab(false, '没有找到相关影视')
            }
            .tabBar(this.ResultTabBar(3, this.ftTotal >= 0 ? '影视 ' + formatCount(this.ftTotal) : '影视'))
            TabContent() {
              this.LiveResultTab()
            }
            .tabBar(this.ResultTabBar(4, this.liveTotal >= 0 ? '直播 ' + formatCount(this.liveTotal) : '直播'))
            TabContent() {
              this.ArticleResultTab()
            }
            .tabBar(this.ResultTabBar(5, this.articleTotal >= 0 ? '专栏 ' + formatCount(this.articleTotal) : '专栏'))
            TabContent() {
              this.UserResultTab()
            }
            .tabBar(this.ResultTabBar(6, this.userTotal >= 0 ? '用户 ' + formatCount(this.userTotal) : '用户'))
          }
          .barMode(BarMode.Scrollable)
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
      .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
      .alignSelf(ItemAlign.Center)
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
      blurStyle: AppTheme.sheetBlur(this.glassOn),
    })
  }
}