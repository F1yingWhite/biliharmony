import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 与小电视空降助手 CategorySkipOption 保持一致。 */
export class SponsorBlockMode {
  static readonly DISABLED: number = -1;
  static readonly SHOW: number = 0;
  static readonly MANUAL: number = 1;
  static readonly AUTO: number = 2;
}

export class SponsorBlockCategory {
  name: string = '';
  label: string = '';
  color: string = '#FFFFFF';
  mode: number = SponsorBlockMode.DISABLED;

  constructor(name: string, label: string, color: string, mode: number) {
    this.name = name;
    this.label = label;
    this.color = color;
    this.mode = mode;
  }
}

export class SponsorBlockSegment {
  start: number = 0;
  end: number = 0;
  cid: string = '';
  category: string = '';
  actionType: string = 'skip';
  uuid: string = '';
  locked: boolean = false;
  votes: number = 0;
  description: string = '';
  videoDuration: number = 0;
}

export class SponsorBlockDraft {
  start: number = -1;
  end: number = -1;
  category: string = 'sponsor';
  actionType: string = 'skip';

  reset(): void {
    this.start = -1;
    this.end = -1;
    this.category = 'sponsor';
    this.actionType = 'skip';
  }
}

/** 固定顺序用于落盘；颜色与上游默认 preview bar 配置一致。 */
export function sponsorBlockCategories(): Array<SponsorBlockCategory> {
  return [
    new SponsorBlockCategory('sponsor', '赞助广告', '#00D400', SponsorBlockMode.AUTO),
    new SponsorBlockCategory('selfpromo', '自我推广', '#FFFF00', SponsorBlockMode.MANUAL),
    new SponsorBlockCategory('exclusive_access', '整片商业合作', '#008A5C', SponsorBlockMode.SHOW),
    new SponsorBlockCategory('interaction', '互动提醒', '#CC00FF', SponsorBlockMode.MANUAL),
    new SponsorBlockCategory('intro', '片头/过场', '#00FFFF', SponsorBlockMode.MANUAL),
    new SponsorBlockCategory('outro', '片尾/鸣谢', '#0202ED', SponsorBlockMode.MANUAL),
    new SponsorBlockCategory('preview', '预告/回顾', '#008FD6', SponsorBlockMode.SHOW),
    new SponsorBlockCategory('padding', '无意义留白', '#A6A6A6', SponsorBlockMode.AUTO),
    new SponsorBlockCategory('filler', '离题内容', '#7300FF', SponsorBlockMode.DISABLED),
    new SponsorBlockCategory('music_offtopic', '音乐中的非音乐片段', '#FF9900', SponsorBlockMode.AUTO),
    new SponsorBlockCategory('poi_highlight', '精彩时刻', '#FF1684', SponsorBlockMode.MANUAL),
  ];
}

export function sponsorBlockCategory(name: string): SponsorBlockCategory {
  const list: Array<SponsorBlockCategory> = SponsorBlockStore.categories();
  for (let i: number = 0; i < list.length; i++) {
    if (list[i].name === name) return list[i];
  }
  return new SponsorBlockCategory(name, name.length > 0 ? name : '未知片段', '#FFFFFF', SponsorBlockMode.DISABLED);
}

export function sponsorBlockModeLabel(mode: number): string {
  if (mode === SponsorBlockMode.AUTO) return '自动跳过';
  if (mode === SponsorBlockMode.MANUAL) return '手动跳过';
  if (mode === SponsorBlockMode.SHOW) return '仅显示';
  return '关闭';
}

export function sponsorBlockActionLabel(actionType: string): string {
  if (actionType === 'mute') return '静音';
  if (actionType === 'full') return '整片标签';
  if (actionType === 'poi') return '空降点';
  return '跳过';
}

export function sponsorBlockSupportedActions(category: string): Array<string> {
  if (category === 'exclusive_access') return ['full'];
  if (category === 'poi_highlight') return ['poi'];
  if (category === 'music_offtopic' || category === 'padding') return ['skip'];
  if (category === 'sponsor' || category === 'selfpromo') return ['skip', 'mute', 'full'];
  return ['skip', 'mute'];
}

/**
 * SponsorBlock 偏好单独存储，避免把投稿身份和播放器类别配置混入主题设置。
 * AppStorage revision 只用于通知已挂载播放器刷新，不承载业务数据。
 */
export class SponsorBlockStore {
  private static readonly PREF_NAME: string = 'sponsor_block_state';
  private static readonly KEY_MODES: string = 'categoryModes';
  private static readonly KEY_USER_ID: string = 'userID';
  private static readonly KEY_SKIP_COUNT: string = 'skipCount';
  private static readonly KEY_SECONDS_SAVED: string = 'secondsSaved';
  private static store: preferences.Preferences | null = null;
  private static categoryModes: string = '';
  private static anonymousUserID: string = '';

  static async init(context: common.UIAbilityContext): Promise<void> {
    AppStorage.setOrCreate<number>('sponsorBlockSettingsRevision', 0);
    try {
      SponsorBlockStore.store = await preferences.getPreferences(context, { name: SponsorBlockStore.PREF_NAME });
      const storedModes: string = SponsorBlockStore.store.getSync(SponsorBlockStore.KEY_MODES, '') as string;
      const storedUserID: string = SponsorBlockStore.store.getSync(SponsorBlockStore.KEY_USER_ID, '') as string;
      if (storedModes.length > 0) SponsorBlockStore.categoryModes = storedModes;
      else if (SponsorBlockStore.categoryModes.length > 0) {
        SponsorBlockStore.putString(SponsorBlockStore.KEY_MODES, SponsorBlockStore.categoryModes);
      }
      if (storedUserID.length > 0) SponsorBlockStore.anonymousUserID = storedUserID;
      else if (SponsorBlockStore.anonymousUserID.length > 0) {
        SponsorBlockStore.putString(SponsorBlockStore.KEY_USER_ID, SponsorBlockStore.anonymousUserID);
      }
      const revision: number = AppStorage.get<number>('sponsorBlockSettingsRevision') ?? 0;
      AppStorage.setOrCreate<number>('sponsorBlockSettingsRevision', revision + 1);
    } catch (e) {
      SponsorBlockStore.store = null;
    }
  }

  static categories(): Array<SponsorBlockCategory> {
    const list: Array<SponsorBlockCategory> = sponsorBlockCategories();
    if (SponsorBlockStore.categoryModes.length === 0) return list;
    const values: Array<string> = SponsorBlockStore.categoryModes.split(',');
    for (let i: number = 0; i < list.length && i < values.length; i++) {
      const value: number = Number(values[i]);
      if (!Number.isNaN(value) && value >= SponsorBlockMode.DISABLED && value <= SponsorBlockMode.AUTO) {
        list[i].mode = value;
      }
    }
    return list;
  }

  static modeFor(category: string): number {
    const list: Array<SponsorBlockCategory> = SponsorBlockStore.categories();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].name === category) return list[i].mode;
    }
    return SponsorBlockMode.DISABLED;
  }

  static setMode(category: string, mode: number): void {
    const list: Array<SponsorBlockCategory> = SponsorBlockStore.categories();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].name === category) list[i].mode = mode;
    }
    const values: Array<string> = [];
    for (let i: number = 0; i < list.length; i++) values.push(String(list[i].mode));
    SponsorBlockStore.categoryModes = values.join(',');
    SponsorBlockStore.putString(SponsorBlockStore.KEY_MODES, SponsorBlockStore.categoryModes);
    const revision: number = AppStorage.get<number>('sponsorBlockSettingsRevision') ?? 0;
    AppStorage.setOrCreate<number>('sponsorBlockSettingsRevision', revision + 1);
  }

  static userID(): string {
    if (SponsorBlockStore.anonymousUserID.length === 0) {
      const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      let id: string = '';
      for (let i: number = 0; i < 36; i++) id += chars.charAt(Math.floor(Math.random() * chars.length));
      SponsorBlockStore.anonymousUserID = id;
      SponsorBlockStore.putString(SponsorBlockStore.KEY_USER_ID, id);
    }
    return SponsorBlockStore.anonymousUserID;
  }

  static recordSkip(seconds: number): void {
    const target: preferences.Preferences | null = SponsorBlockStore.store;
    if (target === null || seconds <= 0) return;
    try {
      const count: number = Number(target.getSync(SponsorBlockStore.KEY_SKIP_COUNT, '0') as string);
      const saved: number = Number(target.getSync(SponsorBlockStore.KEY_SECONDS_SAVED, '0') as string);
      target.putSync(SponsorBlockStore.KEY_SKIP_COUNT, String((Number.isNaN(count) ? 0 : count) + 1));
      target.putSync(SponsorBlockStore.KEY_SECONDS_SAVED,
        String((Number.isNaN(saved) ? 0 : saved) + seconds));
      target.flush();
    } catch (e) {
    }
  }

  private static putString(key: string, value: string): void {
    const target: preferences.Preferences | null = SponsorBlockStore.store;
    if (target === null) return;
    try {
      target.putSync(key, value);
      target.flush();
    } catch (e) {
    }
  }
}
