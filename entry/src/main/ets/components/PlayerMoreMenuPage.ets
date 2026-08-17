/**
 * 播放器“更多功能”菜单首页：清晰度/倍速/弹幕设置/弹幕列表/屏蔽/分段/字幕/自动连播/广告空降。
 */
import { PlayerMenuItem, PlayerSponsorItem, PlayerToggleItem } from './PlayerMenuItems';

@Component
export struct PlayerMoreMenuPage {
  @Prop qualityValue: string = '清晰度';
  @Prop speedValue: string = '1.0x';
  @Prop danmakuCount: number = 0;
  @Prop chapterCount: number = 0;
  @Prop subtitleOn: boolean = false;
  @Prop subtitleValue: string = '关闭';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onQuality: () => void = () => {};
  onSpeed: () => void = () => {};
  onDmSettings: () => void = () => {};
  onDmList: () => void = () => {};
  onDmFilter: () => void = () => {};
  onChapter: () => void = () => {};
  onSubtitle: () => void = () => {};
  onAutoContinue: (next: boolean) => void = () => {};
  onSponsor: (current: boolean) => void = () => {};
  @Prop autoContinue: boolean = false;
  @Prop sponsorOn: boolean = false;
  @Prop subtitleCount: number = 0;

  build() {
    Column({ space: 4 }) {
      PlayerMenuItem({
        icon: $r('app.media.ic_play'),
        label: '清晰度',
        value: this.qualityValue,
        onTap: (): void => this.onQuality(),
      })
      PlayerMenuItem({
        icon: $r('app.media.ic_video_replay'),
        label: '倍速',
        value: this.speedValue,
        onTap: (): void => this.onSpeed(),
      })
      PlayerMenuItem({
        icon: $r('app.media.ic_danmaku_settings'),
        label: '弹幕设置',
        value: '',
        onTap: (): void => this.onDmSettings(),
      })
      PlayerMenuItem({
        icon: $r('app.media.ic_danmaku_on'),
        label: '弹幕列表',
        value: this.danmakuCount > 0 ? String(this.danmakuCount) + ' 条' : '',
        onTap: (): void => this.onDmList(),
      })
      PlayerMenuItem({
        icon: $r('app.media.ic_filter'),
        label: '屏蔽管理',
        value: '',
        onTap: (): void => this.onDmFilter(),
      })
      if (this.chapterCount > 0) {
        PlayerMenuItem({
          icon: $r('app.media.ic_sort'),
          label: '分段视频',
          value: String(this.chapterCount) + ' 段',
          onTap: (): void => this.onChapter(),
        })
      }
      if (this.subtitleCount > 0) {
        PlayerMenuItem({
          icon: $r('app.media.ic_comment'),
          label: 'CC字幕',
          value: this.subtitleValue,
          onTap: (): void => this.onSubtitle(),
        })
      }
      PlayerToggleItem({
        icon: $r('app.media.ic_video_replay'),
        label: '自动连播',
        isOn: this.autoContinue,
        onChange: (next: boolean): void => this.onAutoContinue(next),
      })
      PlayerSponsorItem({
        sponsorOn: this.sponsorOn,
        onToggle: (current: boolean): void => this.onSponsor(current),
      })
    }
    .width('100%')
  }
}
