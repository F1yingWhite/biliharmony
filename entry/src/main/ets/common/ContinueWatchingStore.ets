/**
 * 继续观看记录：最近一次正在看的视频（标题/封面/进度）持久化，
 * 供「继续观看」服务卡片（FormExtensionAbility）与站内深链使用。
 * 写入点：PlayerView 起播与周期性进度回调（节流 15 秒）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class ContinueWatchRecord {
  bvid: string = '';
  aid: number = 0;
  title: string = '';
  cover: string = '';
  /** 展示文案（"看到 12:34 / 25:00"）。 */
  progressText: string = '';
  /** 恢复定位（秒）。 */
  position: number = 0;
  updatedAt: number = 0;

  static from(o: Object): ContinueWatchRecord {
    const j: Record<string, Object> = o as Record<string, Object>;
    const r: ContinueWatchRecord = new ContinueWatchRecord();
    r.bvid = typeof j['bvid'] === 'string' ? j['bvid'] as string : '';
    r.aid = typeof j['aid'] === 'number' ? j['aid'] as number : 0;
    r.title = typeof j['title'] === 'string' ? j['title'] as string : '';
    r.cover = typeof j['cover'] === 'string' ? j['cover'] as string : '';
    r.progressText = typeof j['progressText'] === 'string' ? j['progressText'] as string : '';
    r.position = typeof j['position'] === 'number' ? j['position'] as number : 0;
    r.updatedAt = typeof j['updatedAt'] === 'number' ? j['updatedAt'] as number : 0;
    return r;
  }
}

export class ContinueWatchingStore {
  private static readonly PREFS_NAME: string = 'continue_watching';
  private static readonly KEY_LATEST: string = 'latest';
  private static readonly KEY_POSITION: string = 'latest_position';
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;
  private static lastWriteAt: number = 0;
  /** 最小写入间隔（毫秒）：进度回调高频，卡片数据不需要秒级新鲜。 */
  private static readonly WRITE_INTERVAL: number = 15000;

  static ensure(context: common.Context): Promise<void> {
    if (ContinueWatchingStore.ready !== null) return ContinueWatchingStore.ready;
    ContinueWatchingStore.ready = preferences.getPreferences(context, { name: ContinueWatchingStore.PREFS_NAME })
      .then((store: preferences.Preferences) => {
        ContinueWatchingStore.store = store;
      }).catch(() => {
      });
    return ContinueWatchingStore.ready;
  }

  /** 播放器周期调用：记录当前视频与进度（节流；标题变化立即写入）。 */
  static async report(context: common.Context, bvid: string, aid: number, title: string, cover: string,
    positionSec: number, durationSec: number): Promise<void> {
    if (bvid.length === 0 && aid <= 0) return;
    const now: number = Date.now();
    const current: ContinueWatchRecord | null = ContinueWatchingStore.latest();
    const sameVideo: boolean = current !== null && (current as ContinueWatchRecord).bvid === bvid &&
      (current as ContinueWatchRecord).aid === aid;
    if (sameVideo && now - ContinueWatchingStore.lastWriteAt < ContinueWatchingStore.WRITE_INTERVAL) return;
    ContinueWatchingStore.lastWriteAt = now;
    await ContinueWatchingStore.ensure(context);
    if (ContinueWatchingStore.store === null) return;
    const record: ContinueWatchRecord = new ContinueWatchRecord();
    record.bvid = bvid;
    record.aid = aid;
    record.title = title;
    record.cover = cover;
    record.position = positionSec;
    record.updatedAt = now;
    record.progressText = ContinueWatchingStore.progressText(positionSec, durationSec);
    try {
      ContinueWatchingStore.store.putSync(ContinueWatchingStore.KEY_LATEST, JSON.stringify(record));
      await ContinueWatchingStore.store.flush();
    } catch (e) {
      // 卡片数据写入失败不影响播放。
    }
  }

  /** 深链恢复定位：EntryAbility 读出（与卡片展示同一条记录）。 */
  static async latestPosition(context: common.Context, bvid: string, aid: number): Promise<number> {
    const record: ContinueWatchRecord | null = ContinueWatchingStore.latest();
    if (record === null) return 0;
    const r: ContinueWatchRecord = record;
    if (r.bvid !== bvid && (aid <= 0 || r.aid !== aid)) return 0;
    return r.position;
  }

  static latest(): ContinueWatchRecord | null {
    if (ContinueWatchingStore.store === null) return null;
    try {
      const raw: string = ContinueWatchingStore.store.getSync(ContinueWatchingStore.KEY_LATEST, '') as string;
      if (raw.length === 0) return null;
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed === null || typeof parsed !== 'object') return null;
      return ContinueWatchRecord.from(parsed);
    } catch (e) {
      return null;
    }
  }

  private static progressText(position: number, duration: number): string {
    if (position <= 0) return '刚开始看';
    if (duration > 0 && position >= duration - 30) return '已看完';
    return '看到 ' + ContinueWatchingStore.clock(position) +
      (duration > 0 ? ' / ' + ContinueWatchingStore.clock(duration) : '');
  }

  private static clock(seconds: number): string {
    const total: number = Math.max(0, Math.floor(seconds));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const pad = (v: number): string => (v < 10 ? '0' : '') + String(v);
    return h > 0 ? String(h) + ':' + pad(m) + ':' + pad(s) : String(m) + ':' + pad(s);
  }
}
