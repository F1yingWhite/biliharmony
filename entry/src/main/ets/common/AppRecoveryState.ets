/** Small, serializable view state alongside the system-managed Navigation stack. */
export interface RecoveryViewState {
  tab?: number;
  searchTab?: number;
  keyword?: string;
  submitted?: boolean;
  scrollX?: number;
  scrollY?: number;
  cid?: number;
  position?: number;
  playing?: boolean;
}

interface RecoveryViewEntry {
  key: string;
  state: RecoveryViewState;
}

interface RecoverySnapshot {
  version: number;
  rootTab: number;
  views: Array<RecoveryViewEntry>;
}

export class AppRecoveryState {
  static readonly WANT_KEY: string = 'biliharmony.viewRecovery';
  private static readonly MAX_LENGTH: number = 16384;
  private static readonly MAX_VIEWS: number = 40;
  private static views: Map<string, RecoveryViewState> = new Map<string, RecoveryViewState>();
  private static pending: Map<string, RecoveryViewState> = new Map<string, RecoveryViewState>();
  private static rootTab: number = 0;
  private static pendingRootTab: number | undefined = undefined;

  static saveRootTab(tab: number): void {
    if (Number.isInteger(tab) && tab >= 0 && tab <= 2) AppRecoveryState.rootTab = tab;
  }

  static takeRootTab(): number | undefined {
    const tab: number | undefined = AppRecoveryState.pendingRootTab;
    AppRecoveryState.pendingRootTab = undefined;
    return tab;
  }

  static saveView(key: string, state: RecoveryViewState): void {
    if (key.length === 0 || key.length > 256) return;
    if (!AppRecoveryState.views.has(key) && AppRecoveryState.views.size >= AppRecoveryState.MAX_VIEWS) {
      const oldest: string = Array.from(AppRecoveryState.views.keys())[0];
      AppRecoveryState.views.delete(oldest);
    }
    AppRecoveryState.views.set(key, AppRecoveryState.clean(state));
  }

  /** Consume only restored state; navigating to a new page never reuses a stale view. */
  static takeView(key: string): RecoveryViewState | undefined {
    const state: RecoveryViewState | undefined = AppRecoveryState.pending.get(key);
    AppRecoveryState.pending.delete(key);
    return state === undefined ? undefined : AppRecoveryState.clean(state);
  }

  static serialize(): string {
    const entries: Array<RecoveryViewEntry> = [];
    AppRecoveryState.views.forEach((state: RecoveryViewState, key: string): void => {
      entries.push({ key: key, state: AppRecoveryState.clean(state) });
    });
    const snapshot: RecoverySnapshot = { version: 1, rootTab: AppRecoveryState.rootTab, views: entries };
    let encoded: string = JSON.stringify(snapshot);
    // Leave ample space in the 200 KB Want budget for the native navigation stack.
    while (encoded.length > AppRecoveryState.MAX_LENGTH && snapshot.views.length > 0) {
      snapshot.views.shift();
      encoded = JSON.stringify(snapshot);
    }
    return encoded;
  }

  /** EntryAbility calls this only for LaunchReason.APP_RECOVERY. */
  static restore(value: Object | undefined): void {
    AppRecoveryState.views.clear();
    AppRecoveryState.pending.clear();
    AppRecoveryState.rootTab = 0;
    AppRecoveryState.pendingRootTab = undefined;
    if (typeof value !== 'string' || value.length > AppRecoveryState.MAX_LENGTH) return;
    try {
      const snapshot: RecoverySnapshot = JSON.parse(value) as RecoverySnapshot;
      if (snapshot === null || snapshot.version !== 1 || !Array.isArray(snapshot.views)) return;
      if (Number.isInteger(snapshot.rootTab) && snapshot.rootTab >= 0 && snapshot.rootTab <= 2) {
        AppRecoveryState.rootTab = snapshot.rootTab;
        AppRecoveryState.pendingRootTab = snapshot.rootTab;
      }
      for (const entry of snapshot.views.slice(0, AppRecoveryState.MAX_VIEWS)) {
        if (entry === null || typeof entry !== 'object' || typeof entry.key !== 'string' ||
          entry.key.length === 0 || entry.key.length > 256 || entry.state === null ||
          typeof entry.state !== 'object') continue;
        const state: RecoveryViewState = AppRecoveryState.clean(entry.state);
        AppRecoveryState.views.set(entry.key, state);
        AppRecoveryState.pending.set(entry.key, state);
      }
    } catch (e) {
      // Corrupt/older state cannot prevent a normal root page from loading.
    }
  }

  private static clean(state: RecoveryViewState): RecoveryViewState {
    const result: RecoveryViewState = {};
    if (Number.isInteger(state.tab) && state.tab !== undefined && state.tab >= 0 && state.tab <= 20) {
      result.tab = state.tab;
    }
    if (Number.isInteger(state.searchTab) && state.searchTab !== undefined && state.searchTab >= 0 &&
      state.searchTab <= 20) result.searchTab = state.searchTab;
    if (typeof state.keyword === 'string') result.keyword = state.keyword.slice(0, 512);
    if (typeof state.submitted === 'boolean') result.submitted = state.submitted;
    if (state.scrollX !== undefined && Number.isFinite(state.scrollX) && state.scrollX >= 0) {
      result.scrollX = Math.min(state.scrollX, 10000000);
    }
    if (state.scrollY !== undefined && Number.isFinite(state.scrollY) && state.scrollY >= 0) {
      result.scrollY = Math.min(state.scrollY, 10000000);
    }
    if (state.cid !== undefined && Number.isSafeInteger(state.cid) && state.cid > 0) result.cid = state.cid;
    if (state.position !== undefined && Number.isFinite(state.position) && state.position >= 0) {
      result.position = Math.min(state.position, 10000000);
    }
    if (typeof state.playing === 'boolean') result.playing = state.playing;
    return result;
  }
}
