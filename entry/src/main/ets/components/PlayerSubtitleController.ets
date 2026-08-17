/**
 * 播放器 CC 字幕控制器：字幕轨道选择、加载、二分匹配与开关。
 * 从 PlayerView 抽离，状态仍通过回调同步给组件 @State。
 */
import { SubtitleCue, SubtitleTrack } from '../model/Models';
import { BiliApi } from '../api/BiliApi';

export class PlayerSubtitleController {
  tracks: Array<SubtitleTrack> = [];
  index: number = -1;
  enabled: boolean = false;
  loading: boolean = false;
  text: string = '';
  private cues: Array<SubtitleCue> = [];
  private requestSeq: number = 0;
  private onStateChange: () => void;

  constructor(onStateChange: () => void) {
    this.onStateChange = onStateChange;
  }


  reset(): void {
    this.tracks = [];
    this.index = -1;
    this.enabled = false;
    this.loading = false;
    this.text = '';
    this.cues = [];
    this.requestSeq++;
    this.onStateChange();
  }

  /** 轨道列表变化：清空或自动选择第一条并加载。 */
  setTracks(tracks: Array<SubtitleTrack>, refreshTime: number): void {
    this.tracks = tracks;
    if (this.tracks.length === 0) {
      this.index = -1;
      this.enabled = false;
      this.text = '';
      this.cues = [];
      this.onStateChange();
      return;
    }
    if (this.index < 0 || this.index >= this.tracks.length) {
      this.index = 0;
    }
    this.load(this.index, refreshTime);
  }

  label(): string {
    if (this.index < 0 || this.index >= this.tracks.length) return '关闭';
    return this.tracks[this.index].lanDoc.length > 0 ?
      this.tracks[this.index].lanDoc : this.tracks[this.index].lan;
  }

  async load(index: number, refreshTime: number = -1): Promise<void> {
    if (index < 0 || index >= this.tracks.length) {
      this.cues = [];
      this.text = '';
      this.index = index;
      this.onStateChange();
      return;
    }
    const track: SubtitleTrack = this.tracks[index];
    this.index = index;
    this.loading = true;
    const seq: number = ++this.requestSeq;
    this.onStateChange();
    try {
      const cues: Array<SubtitleCue> = await BiliApi.getSubtitleCues(track.url);
      if (seq !== this.requestSeq || this.index !== index) return;
      this.cues = cues;
      this.text = '';
      if (refreshTime >= 0) this.update(refreshTime);
      this.onStateChange();
    } catch (e) {
      if (seq === this.requestSeq) {
        this.cues = [];
        this.text = '';
        this.loading = false;
        this.onStateChange();
      }
    } finally {
      if (seq === this.requestSeq) this.loading = false;
    }
  }

  /** 当前播放头更新字幕。 */
  update(timeSec: number): void {
    const nextText: string = this.match(timeSec);
    if (nextText !== this.text) {
      this.text = nextText;
      this.onStateChange();
    }
  }

  /** 切换字幕轨道；-1 为关闭。 */
  changeSubtitle(index: number): void {
    if (this.loading && index === this.index) return;
    this.index = index;
    if (index < 0) {
      this.enabled = false;
      this.text = '';
      this.cues = [];
      this.onStateChange();
      return;
    }
    this.enabled = true;
    this.text = '';
    this.onStateChange();
    this.load(index, -1);
  }

  private match(timeSec: number): string {
    if (!this.enabled || this.cues.length === 0) return '';
    let lo: number = 0;
    let hi: number = this.cues.length - 1;
    let hit: number = -1;
    while (lo <= hi) {
      const mid: number = Math.floor((lo + hi) / 2);
      const cue: SubtitleCue = this.cues[mid];
      if (timeSec < cue.from) {
        hi = mid - 1;
      } else if (timeSec >= cue.to) {
        lo = mid + 1;
      } else {
        hit = mid;
        break;
      }
    }
    if (hit < 0) return '';
    return this.cues[hit].content;
  }

  /** 供 load 结束后用当前播放头刷新一次字幕。 */
  refreshAt(timeSec: number): void {
    this.update(timeSec);
  }
}
