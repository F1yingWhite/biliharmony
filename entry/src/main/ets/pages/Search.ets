/** 搜索页只组合输入、分类列表与筛选弹层；查询生命周期由搜索域控制器负责。 */
import { Immersive } from '../common/Immersive';
import { LayoutTokens } from '../common/LayoutTokens';
import { AppTheme } from '../common/AppTheme';
import { formatCount } from '../common/Utils';
import { inputMethod } from '@kit.IMEKit';
import { VideoItem, UserSearchItem, PgcSearchItem, ArticleSearchItem, SearchAllSection, SearchTypes } from '../model/Models';
import { LiveRoomItem } from '../model/LiveModels';
import { LoadingView } from '../components/LoadingView';
import { BackButton } from '../components/BackButton';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { SearchResultList } from '../components/SearchResultList';
import { VideoCard } from '../components/video/VideoCard';
import { LiveRoomCard } from '../components/live/LiveRoomCard';
import { SearchQuery } from '../components/search/SearchQuery';
import { SearchResultsController, SearchResultsView } from '../components/search/SearchResultsController';
import { SearchDiscoveryController, SearchDiscoveryView } from '../components/search/SearchDiscoveryController';
import { SearchDiscoveryContent } from '../components/search/SearchDiscoveryContent';
import { SearchSortBar } from '../components/search/SearchSortBar';
import { SearchFilterPanel } from '../components/search/SearchFilterPanel';
import { SearchUserCard } from '../components/search/SearchUserCard';
import { SearchMediaCard } from '../components/search/SearchMediaCard';
import { SearchArticleCard } from '../components/search/SearchArticleCard';

@Component
export struct SearchPage {
  @Prop initialKeyword: string = '';
  @State keyword: string = '';
  @State searchTab: number = 0;
  @State showFilter: boolean = false;
  @State query: SearchQuery = new SearchQuery();
  @State results: SearchResultsView = new SearchResultsView();
  @State discovery: SearchDiscoveryView = new SearchDiscoveryView();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('searchSuggestedKeyword') suggestedKeyword: string = '';
  private resultsController: SearchResultsController = new SearchResultsController();
  private discoveryController: SearchDiscoveryController = new SearchDiscoveryController();
  private lifecycle: number = 0;
  private active: boolean = false;
  private initialKeywordConsumed: boolean = false;

  async aboutToAppear(): Promise<void> {
    const lifecycle: number = ++this.lifecycle;
    this.active = true;
    const routeKeyword: string = !this.initialKeywordConsumed && typeof this.initialKeyword === 'string' ?
      this.initialKeyword.trim() : '';
    this.initialKeywordConsumed = true;
    // Capture the compatibility entry before awaiting discovery: an older page
    // must never consume a keyword subsequently written for another destination.
    const storedPrefill: string | undefined = AppStorage.get<string>('searchPrefillKeyword');
    const prefill: string = typeof storedPrefill === 'string' ? storedPrefill.trim() : '';
    if (typeof storedPrefill === 'string' && storedPrefill.length > 0) {
      AppStorage.setOrCreate<string>('searchPrefillKeyword', '');
    }
    const initial: string = routeKeyword.length > 0 ? routeKeyword : prefill;
    this.resultsController.onChange = (view: SearchResultsView): void => {
      if (!this.active || lifecycle !== this.lifecycle) return;
      this.results = view;
      this.searchTab = view.tab;
    };
    this.discoveryController.onChange = (view: SearchDiscoveryView): void => {
      if (this.active && lifecycle === this.lifecycle) this.discovery = view;
    };
    this.discoveryController.onDefault = (keyword: string): void => {
      if (!this.active || lifecycle !== this.lifecycle) return;
      if (this.suggestedKeyword.length === 0) AppStorage.setOrCreate<string>('searchSuggestedKeyword', keyword);
    };
    this.resultsController.activate();
    await this.discoveryController.activate();
    if (!this.active || lifecycle !== this.lifecycle) return;
    if (initial.length > 0) {
      this.keyword = initial;
      this.submitSearch();
    }
  }

  aboutToDisappear(): void {
    this.active = false;
    this.lifecycle++;
    this.resultsController.dispose();
    this.discoveryController.dispose();
  }

  onInput(value: string): void {
    this.keyword = value;
    this.discoveryController.input(value);
    if (value.length === 0) this.resultsController.clear();
  }

  submitSearch(): void {
    if (!this.active) return;
    if (this.keyword.trim().length === 0) this.keyword = this.suggestedKeyword;
    const keyword: string = this.keyword.trim();
    if (keyword.length === 0) return;
    inputMethod.getController().hideTextInput().catch(() => {});
    this.discoveryController.submit(keyword);
    this.resultsController.submit(keyword, this.query).catch(() => {});
  }

  @Builder
  SortRow() {
    SearchSortBar({
      query: this.query,
      tab: this.searchTab,
      onChange: (query: SearchQuery): void => {
        this.query = query;
        this.resultsController.refresh(query).catch(() => {});
      },
      onFilter: (): void => { this.showFilter = true; },
    })
  }

  @Builder
  FilterPanel() {
    SearchFilterPanel({
      duration: this.query.duration,
      pubtime: this.query.pubtime,
      tids: this.query.tids,
      onApply: (duration: number, pubtime: number, tids: number): void => {
        const query: SearchQuery = this.query.copy();
        query.duration = duration;
        query.pubtime = pubtime;
        query.tids = tids;
        this.query = query;
        this.showFilter = false;
        this.resultsController.refresh(query).catch(() => {});
      },
    })
  }

  // ===== 结果态：二级 Tab 栏（轻量文字样式 + 主题色下划线） =====
  @Builder
  ResultTabBar(index: number) {
    Column({ space: 3 }) {
      Text(index === 0 ? '综合' :
        (index === 1 ? (this.results.totals[1] >= 0 ? '视频 ' +
          (this.results.totals[1] === 1000 ? '1000+' : formatCount(this.results.totals[1])) : '视频') :
        (index === 2 ? (this.results.totals[2] >= 0 ? '番剧 ' + formatCount(this.results.totals[2]) : '番剧') :
        (index === 3 ? (this.results.totals[3] >= 0 ? '影视 ' + formatCount(this.results.totals[3]) : '影视') :
        (index === 4 ? (this.results.totals[4] >= 0 ? '直播 ' + formatCount(this.results.totals[4]) : '直播') :
        (index === 5 ? (this.results.totals[5] >= 0 ? '专栏 ' + formatCount(this.results.totals[5]) : '专栏') :
        (this.results.totals[6] >= 0 ? '用户 ' + formatCount(this.results.totals[6]) : '用户')))))))
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

  // ===== 结果态：视频 Tab 内容 =====
  @Builder
  VideoListContent() {
    LazyForEach(this.resultsController.store.videos, (item: VideoItem) => {
      ListItem() {
        this.SearchVideoRow(item, 'search-video-')
      }
    }, (item: VideoItem) => item.bvid + String(item.aid))
  }

  @Builder
  VideoResultTab() {
    Column() {
      this.SortRow()
      SearchResultList({
        loading: this.results.loading,
        errorText: this.results.error,
        moreError: this.results.moreError,
        hasMore: this.results.hasMore,
        loadingMore: this.results.loadingMore,
        count: this.resultsController.store.videos.totalCount(),
        emptyText: '没有找到相关视频',
        onRetry: (): void => {
          this.resultsController.refresh(this.query).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.resultsController.loadMore(true);
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
    LazyForEach(this.resultsController.store.users, (item: UserSearchItem) => {
      ListItem() {
        SearchUserCard({ item: item, keyword: this.results.keyword })
      }
    }, (item: UserSearchItem) => String(item.mid))
  }

  @Builder
  UserResultTab() {
    Column() {
      this.SortRow()
      SearchResultList({
        skeleton: 'sessions',
        loading: this.results.loading,
        errorText: this.results.error,
        moreError: this.results.moreError,
        hasMore: this.results.hasMore,
        loadingMore: this.results.loadingMore,
        count: this.resultsController.store.users.totalCount(),
        emptyText: '没有找到相关用户',
        onRetry: (): void => {
          this.resultsController.refresh(this.query).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.resultsController.loadMore(true);
        },
        content: (): void => {
          this.UserListContent()
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：番剧 / 影视 Tab 内容（isBangumi 区分 search_type 与数据源） =====
  @Builder
  BangumiListContent() {
    LazyForEach(this.resultsController.store.bangumi, (item: PgcSearchItem) => {
      ListItem() {
        SearchMediaCard({ item: item, keyword: this.results.keyword })
      }
    }, (item: PgcSearchItem) => String(item.seasonId))
  }

  @Builder
  FtListContent() {
    LazyForEach(this.resultsController.store.films, (item: PgcSearchItem) => {
      ListItem() {
        SearchMediaCard({ item: item, keyword: this.results.keyword })
      }
    }, (item: PgcSearchItem) => String(item.seasonId))
  }

  @Builder
  MediaResultTab(isBangumi: boolean, emptyText: string) {
    Column() {
      SearchResultList({
        skeleton: 'mediaList',
        loading: this.results.loading,
        errorText: this.results.error,
        moreError: this.results.moreError,
        hasMore: this.results.hasMore,
        loadingMore: this.results.loadingMore,
        count: this.resultsController.store.media(isBangumi).totalCount(),
        emptyText: emptyText,
        onRetry: (): void => {
          this.resultsController.refresh(this.query).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.resultsController.loadMore(true);
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
    LazyForEach(this.resultsController.store.live, (item: LiveRoomItem) => {
      ListItem() {
        LiveRoomCard({ room: item, highlightKeyword: this.results.keyword })
      }
    }, (item: LiveRoomItem) => String(item.roomId))
  }

  @Builder
  LiveResultTab() {
    Column() {
      this.SortRow()
      SearchResultList({
        loading: this.results.loading,
        errorText: this.results.error,
        moreError: this.results.moreError,
        hasMore: this.results.hasMore,
        loadingMore: this.results.loadingMore,
        count: this.resultsController.store.live.totalCount(),
        emptyText: '没有找到相关直播间',
        listSpace: 10,
        lanes: 2,
        horizontalPadding: 12,
        onRetry: (): void => {
          this.resultsController.refresh(this.query).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.resultsController.loadMore(true);
        },
        content: (): void => {
          this.LiveListContent()
        },
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 结果态：专栏 Tab 内容 =====
  @Builder
  ArticleListContent() {
    LazyForEach(this.resultsController.store.articles, (item: ArticleSearchItem) => {
      ListItem() {
        SearchArticleCard({ item: item, keyword: this.results.keyword })
      }
    }, (item: ArticleSearchItem) => String(item.id))
  }

  @Builder
  ArticleResultTab() {
    Column() {
      SearchResultList({
        loading: this.results.loading,
        errorText: this.results.error,
        moreError: this.results.moreError,
        hasMore: this.results.hasMore,
        loadingMore: this.results.loadingMore,
        count: this.resultsController.store.articles.totalCount(),
        emptyText: '没有找到相关专栏',
        onRetry: (): void => {
          this.resultsController.refresh(this.query).catch(() => {
          });
        },
        onLoadMore: (): void => {
          this.resultsController.loadMore(true);
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
      (type === SearchTypes.biliUser ? '用户' : (type === SearchTypes.mediaBangumi ? '番剧' :
        (type === SearchTypes.article ? '图文' : '影视'))))
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 4 })
  }

  @Builder
  AllUserRow(section: SearchAllSection) {
    Column() {
      ForEach(section.users.slice(0, 2), (user: UserSearchItem, index: number) => {
        SearchUserCard({ item: user, keyword: this.results.keyword, expanded: true })
        if (index + 1 < Math.min(section.users.length, 2)) {
          Divider().color(this.isDark ? '#34363B' : '#E3E5E7')
        }
      }, (user: UserSearchItem) => String(user.mid))
    }
    .width('100%')
  }

  // 综合与视频分类使用相同的横向结果行，保留整卡入场过渡。
  @Builder
  SearchVideoRow(item: VideoItem, prefix: string) {
    VideoCard({ video: item, highlightKeyword: this.results.keyword, horizontal: true, idPrefix: prefix, wholeCardTransition: true })
  }

  @Builder
  AllResultTab() {
    Column() {
      this.SortRow()
      if (this.results.loading) {
        LoadingView({ skeleton: 'list', loading: true })
      } else if (this.results.error.length > 0) {
        LoadingView({ skeleton: 'list', loading: false, errorText: this.results.error, onRetry: () => this.resultsController.refresh(this.query) })
      } else if (this.results.sections.length === 0) {
        LoadingView({ skeleton: 'list',
          loading: false,
          empty: true,
          emptyText: '没有找到相关内容',
          onRetry: () => {
            this.resultsController.refresh(this.query).catch(() => {
            });
          },
        })
      } else {
        List() {
          // 视频分区置顶：标题与行直接作为 List 子节点，由 allVideoSource 懒加载驱动。
          // LazyForEach 必须直接挂在滚动容器下，故视频分区不再包 ListItemGroup。
          if (!this.resultsController.store.allVideos.isEmpty()) {
            ListItem() {
              this.AllSectionHeader(SearchTypes.video)
            }
          }
          LazyForEach(this.resultsController.store.allVideos, (item: VideoItem) => {
            ListItem() {
              this.SearchVideoRow(item, 'search-all-')
            }
          }, (item: VideoItem) => item.bvid + String(item.aid))
          // 非视频分区（用户/番剧/影视/图文）只在第一页返回，key 用分区类型、不含条目数，
          // 翻页合并不会触发这些分区重建；视频分区已在上方由 LazyForEach 渲染，此处跳过。
          ForEach(this.results.sections, (section: SearchAllSection) => {
            if (section.type !== SearchTypes.video) {
              ListItemGroup({ header: this.AllSectionHeader(section.type) }) {
                if (section.type === SearchTypes.biliUser) {
                  ListItem() {
                    this.AllUserRow(section)
                  }
                  .margin({ left: 12, right: 12, bottom: 8 })
                  .borderRadius(7)
                  .backgroundColor(this.isDark ? '#24262B' : '#FFFFFF')
                  .clip(true)
                } else if (section.type === SearchTypes.mediaBangumi || section.type === SearchTypes.mediaFt) {
                  ForEach(section.pgc, (item: PgcSearchItem) => {
                    ListItem() {
                      SearchMediaCard({ item: item, keyword: this.results.keyword })
                    }
                    .margin({ left: 12, right: 12, bottom: 8 })
                    .borderRadius(7)
                    .backgroundColor(this.isDark ? '#24262B' : '#FFFFFF')
                    .clip(true)
                  }, (item: PgcSearchItem) => String(item.seasonId))
                } else if (section.type === SearchTypes.article) {
                  ForEach(section.articles, (item: ArticleSearchItem) => {
                    ListItem() {
                      SearchArticleCard({ item: item, keyword: this.results.keyword })
                    }
                  }, (item: ArticleSearchItem) => String(item.id))
                }
              }
              .margin({ bottom: 8 })
            }
          }, (section: SearchAllSection) => section.type)
          ListItem() {
            LoadMoreFooter({
              loading: this.results.loadingMore,
              hasMore: this.results.hasMore,
              moreText: this.results.moreError.length > 0 ? '加载失败 · 点击重试' : '上滑加载更多',
              endText: '没有更多结果了',
              fixedHeight: 44,
              onLoadMore: () => {
                this.resultsController.loadMore(true);
              },
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(5)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.resultsController.loadMore();
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

        if (this.results.searching) {
          // 结果态：综合 | 视频 | 番剧 | 影视 | 直播 | 专栏 | 用户 二级 Tab
          Tabs({ barPosition: BarPosition.Start, index: $$this.searchTab }) {
            TabContent() {
              this.AllResultTab()
            }
            .tabBar(this.ResultTabBar(0))
            TabContent() {
              this.VideoResultTab()
            }
            .tabBar(this.ResultTabBar(1))
            TabContent() {
              this.MediaResultTab(true, '没有找到相关番剧')
            }
            .tabBar(this.ResultTabBar(2))
            TabContent() {
              this.MediaResultTab(false, '没有找到相关影视')
            }
            .tabBar(this.ResultTabBar(3))
            TabContent() {
              this.LiveResultTab()
            }
            .tabBar(this.ResultTabBar(4))
            TabContent() {
              this.ArticleResultTab()
            }
            .tabBar(this.ResultTabBar(5))
            TabContent() {
              this.UserResultTab()
            }
            .tabBar(this.ResultTabBar(6))
          }
          .barMode(BarMode.Scrollable)
          .barBackgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
          .barHeight(40)
          .divider(null)
          .animationDuration(200)
          .onChange((index: number) => {
            this.resultsController.select(index, this.query);
          })
          .width('100%')
          .layoutWeight(1)
        } else {
          SearchDiscoveryContent({
            view: this.discovery,
            onSearch: (keyword: string): void => {
              this.keyword = keyword;
              this.submitSearch();
            },
            onRemoveHistory: (keyword: string): void => this.discoveryController.removeHistory(keyword),
            onClearHistory: (): void => this.discoveryController.clearHistory(),
          }).layoutWeight(1)
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
