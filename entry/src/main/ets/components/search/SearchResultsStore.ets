import { BasicDataSource } from '../../common/BasicDataSource';
import { SearchApi } from '../../api/SearchApi';
import { VideoItem, UserSearchItem, PgcSearchItem, ArticleSearchItem, SearchAllSection,
  SearchTypes } from '../../model/Models';
import { LiveRoomItem } from '../../model/LiveModels';
import { SearchCategory, SearchQuery } from './SearchQuery';

/** 接口结果只在请求代际校验后入库；API 返回期间不改变任何可见数据源。 */
export class SearchPageResult {
  videos: Array<VideoItem> = [];
  users: Array<UserSearchItem> = [];
  media: Array<PgcSearchItem> = [];
  rooms: Array<LiveRoomItem> = [];
  articles: Array<ArticleSearchItem> = [];
  sections: Array<SearchAllSection> = [];
  totals: Map<string, number> = new Map<string, number>();
  total: number = 0;

  static async fetch(keyword: string, tab: SearchCategory, page: number,
    query: SearchQuery): Promise<SearchPageResult> {
    const result: SearchPageResult = new SearchPageResult();
    if (tab === SearchCategory.All) {
      const response = await SearchApi.searchAll(keyword, page, query.videoOrder,
        query.durationValue(), query.pubtimeBegin(), query.tids);
      result.sections = response.sections;
      result.totals = response.totals;
    } else if (tab === SearchCategory.Video) {
      const response = await SearchApi.searchVideosByType(keyword, page, query.videoOrder,
        query.durationValue(), query.pubtimeBegin(), query.tids);
      result.videos = response.videos;
      result.total = response.numResults;
    } else if (tab === SearchCategory.Bangumi || tab === SearchCategory.Film) {
      const response = await SearchApi.searchMedia(keyword,
        tab === SearchCategory.Bangumi ? SearchTypes.mediaBangumi : SearchTypes.mediaFt, page);
      result.media = response.items;
      result.total = response.numResults;
    } else if (tab === SearchCategory.Live) {
      const response = await SearchApi.searchLiveRooms(keyword, page, query.liveOrder);
      result.rooms = response.rooms;
      result.total = response.numResults;
    } else if (tab === SearchCategory.Article) {
      const response = await SearchApi.searchArticles(keyword, page);
      result.articles = response.articles;
      result.total = response.numResults;
    } else {
      const response = await SearchApi.searchUsers(keyword, page, query.userOrder, query.userType);
      result.users = response.users;
      result.total = response.numResults;
    }
    return result;
  }
}

function videoKey(video: VideoItem): string {
  return video.bvid + ':' + video.aid;
}

/** 同一页及跨页都去重，保证 LazyForEach 的键稳定。 */
function uniqueItems<T>(current: Array<T>, incoming: Array<T>, key: (item: T) => string): Array<T> {
  const seen: Set<string> = new Set<string>();
  current.forEach((item: T) => seen.add(key(item)));
  return incoming.filter((item: T) => {
    const id: string = key(item);
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

function updateSource<T>(source: BasicDataSource<T>, incoming: Array<T>, reset: boolean,
  key: (item: T) => string, total: number): boolean {
  const fresh: Array<T> = uniqueItems(reset ? [] : source.getAll(), incoming, key);
  if (reset) source.reset(fresh);
  else source.append(fresh);
  return incoming.length > 0 && source.totalCount() < total;
}

/** 数据源的身份在页面生命周期内稳定，翻页只发送新增通知。 */
export class SearchResultsStore {
  readonly videos: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  readonly users: BasicDataSource<UserSearchItem> = new BasicDataSource<UserSearchItem>();
  readonly bangumi: BasicDataSource<PgcSearchItem> = new BasicDataSource<PgcSearchItem>();
  readonly films: BasicDataSource<PgcSearchItem> = new BasicDataSource<PgcSearchItem>();
  readonly live: BasicDataSource<LiveRoomItem> = new BasicDataSource<LiveRoomItem>();
  readonly articles: BasicDataSource<ArticleSearchItem> = new BasicDataSource<ArticleSearchItem>();
  readonly allVideos: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  sections: Array<SearchAllSection> = [];
  totals: Array<number> = [-1, -1, -1, -1, -1, -1, -1];

  clear(): void {
    this.videos.clear();
    this.users.clear();
    this.bangumi.clear();
    this.films.clear();
    this.live.clear();
    this.articles.clear();
    this.allVideos.clear();
    this.sections = [];
    this.totals = [-1, -1, -1, -1, -1, -1, -1];
  }

  media(isBangumi: boolean): BasicDataSource<PgcSearchItem> {
    return isBangumi ? this.bangumi : this.films;
  }

  apply(tab: SearchCategory, result: SearchPageResult, reset: boolean): boolean {
    if (tab === SearchCategory.All) return this.applyAll(result, reset);
    this.totals[tab] = result.total;
    if (tab === SearchCategory.Video) {
      return updateSource(this.videos, result.videos, reset, videoKey, result.total);
    }
    if (tab === SearchCategory.Bangumi || tab === SearchCategory.Film) {
      return updateSource(this.media(tab === SearchCategory.Bangumi), result.media, reset,
        (item: PgcSearchItem) => String(item.seasonId), result.total);
    }
    if (tab === SearchCategory.Live) {
      return updateSource(this.live, result.rooms, reset, (item: LiveRoomItem) => String(item.roomId), result.total);
    }
    if (tab === SearchCategory.Article) {
      return updateSource(this.articles, result.articles, reset, (item: ArticleSearchItem) => String(item.id), result.total);
    }
    return updateSource(this.users, result.users, reset, (item: UserSearchItem) => String(item.mid), result.total);
  }

  private applyAll(result: SearchPageResult, reset: boolean): boolean {
    const types: Array<string> = ['', SearchTypes.video, SearchTypes.mediaBangumi, SearchTypes.mediaFt,
      SearchTypes.liveRoom, SearchTypes.article, SearchTypes.biliUser];
    for (let tab: number = 1; tab < types.length; tab++) {
      const total: number | undefined = result.totals.get(types[tab]);
      if (total !== undefined) this.totals[tab] = total;
    }
    let incoming: Array<VideoItem> = [];
    result.sections.forEach((section: SearchAllSection) => {
      if (section.type === SearchTypes.video) incoming = incoming.concat(section.videos);
    });
    const fresh: Array<VideoItem> = uniqueItems(reset ? [] : this.allVideos.getAll(), incoming, videoKey);
    if (reset) this.allVideos.reset(fresh);
    else this.allVideos.append(fresh);
    // 非视频分区只来自第一页。视频总表始终与懒加载源一致，不因分页而重建旧行。
    const sections: Array<SearchAllSection> = (reset ? result.sections : this.sections)
      .filter((section: SearchAllSection) => section.type !== SearchTypes.video);
    if (!this.allVideos.isEmpty()) {
      const videoSection: SearchAllSection = new SearchAllSection();
      videoSection.type = SearchTypes.video;
      videoSection.videos = this.allVideos.getAll().slice();
      sections.unshift(videoSection);
    }
    this.sections = sections;
    return incoming.length > 0 && (this.totals[SearchCategory.Video] <= 0 ||
      this.allVideos.totalCount() < this.totals[SearchCategory.Video]);
  }
}
