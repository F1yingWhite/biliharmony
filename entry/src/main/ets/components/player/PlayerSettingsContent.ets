import { DanmakuItem, DmFilterRule, VideoChapter } from '../../api/BiliApi';
import { SponsorBlockCategory, SponsorBlockSegment } from '../../common/SponsorBlock';
import { BasicDataSource } from '../../common/BasicDataSource';
import { SubtitleTrack, VideoQualityOption } from '../../model/Models';
import { DanmakuListPanel } from './DanmakuListPanel';
import { DmFilterPanel } from './DmFilterPanel';
import { PlayerMoreSheet } from './PlayerMoreSheet';
import { PlayerPlaySettingsPage } from './PlayerPlaySettingsPage';
import { PlayerSettingsPanel } from './PlayerSettingsPanel';
import { SponsorBlockPanel } from './SponsorBlockPanel';

@Component
export struct PlayerSettingsContent {
  @Prop page: string = 'menu';
  @Prop fullscreen: boolean = false;
  @Prop isDark: boolean = false;
  @Prop accent: string = '#FB7299';
  @Prop playbackRate: number = 1;
  @Prop playMode: number = 0;
  @Prop qualityLabel: string = '';
  @Prop qualityLoading: boolean = false;
  @Prop qualityPref: number = 0;
  @Prop downloadQualityLabel: string = '';
  @Prop downloadBusy: boolean = false;
  @Prop downloadProgress: number = -1;
  @Prop mirrorOn: boolean = false;
  @Prop timerMinutes: number = 0;
  @Prop sponsorOn: boolean = false;
  @Link sponsorCategories: Array<SponsorBlockCategory>;
  @Link sponsorSegments: Array<SponsorBlockSegment>;
  @Link sponsorDraftStart: number;
  @Link sponsorDraftEnd: number;
  @Link sponsorDraftCategory: string;
  @Link sponsorDraftAction: string;
  @Link sponsorSubmitting: boolean;
  @Link sponsorUserLoading: boolean;
  @Link sponsorUserName: string;
  @Link sponsorUserStats: string;
  @Link sponsorWarningReason: string;
  @Prop subtitleOn: boolean = false;
  @Prop backgroundPlaybackEnabled: boolean = false;
  @Prop subtitleIndex: number = -1;
  @Prop subtitles: Array<SubtitleTrack> = [];
  @Prop chapters: Array<VideoChapter> = [];
  @Prop currentTime: number = 0;
  @Prop duration: number = 0;
  @Prop qualityOptions: Array<VideoQualityOption> = [];
  @Prop activeQuality: number = 0;
  @Prop dmOpacity: number = 0.85;
  @Prop dmFrameRate: number = 60;
  @Prop dmSpeed: number = 1;
  @Prop dmFontScale: number = 1;
  @Prop dmSpacing: number = 1;
  @Prop dmDensity: number = 22;
  @Prop dmBlockLevel: number = 0;
  @Prop blockScrollDm: boolean = false;
  @Prop blockTopDm: boolean = false;
  @Prop blockBottomDm: boolean = false;
  @Prop blockColorDm: boolean = false;
  @Prop dmListCount: number = 0;
  @Prop dmFilterLoading: boolean = false;
  @Prop dmFilterType: number = 0;
  @Prop dmFilterDraft: string = '';
  @Prop dmFilterRulesCount: number = 0;
  dmListSource: BasicDataSource<DanmakuItem> = new BasicDataSource<DanmakuItem>();
  dmFilterRuleSource: BasicDataSource<DmFilterRule> = new BasicDataSource<DmFilterRule>();
  onBack: () => void = () => {};
  onClose: () => void = () => {};
  onOpenPage: (page: string) => void = () => {};
  onDmFilterOpen: () => void = () => {};
  onSeek: (seconds: number) => void = () => {};
  onReportDm: (item: DanmakuItem) => void = () => {};
  onFilterTypeChange: (type: number) => void = () => {};
  onFilterDraftChange: (draft: string) => void = () => {};
  onFilterAdd: () => void = () => {};
  onFilterDelete: (id: number) => void = () => {};
  onQualityPrefChange: (pref: number) => void = () => {};
  onDownloadQuality: () => void = () => {};
  onDownload: () => void = () => {};
  onSubtitleChange: (index: number) => void = () => {};
  onResetDanmaku: () => void = () => {};
  onDmOpacityChange: (value: number) => void = () => {};
  onDmFrameRateChange: (value: number) => void = () => {};
  onDmSpeedChange: (value: number) => void = () => {};
  onDmFontScaleChange: (value: number) => void = () => {};
  onDmSpacingChange: (value: number) => void = () => {};
  onDmDensityChange: (value: number) => void = () => {};
  onDmBlockLevelChange: (value: number) => void = () => {};
  onToggleDmBlock: (kind: string) => void = () => {};
  onQualityChange: (qn: number) => void = () => {};
  onChapterChange: (seconds: number) => void = () => {};
  onSpeedChange: (rate: number) => void = () => {};
  onPlayModeChange: (mode: number) => void = () => {};
  onTimerChange: (minutes: number) => void = () => {};
  onMirrorChange: (next: boolean) => void = () => {};
  onSubtitleToggle: (next: boolean) => void = () => {};
  onPictureInPicture: () => void = () => {};
  onReportVideo: () => void = () => {};
  onBackgroundPlaybackChange: (next: boolean) => void = () => {};
  onSponsorToggle: (next: boolean) => void = () => {};
  onSponsorModeChange: (category: string, mode: number) => void = () => {};
  onSponsorRefresh: () => void = () => {};
  onSponsorMarkStart: () => void = () => {};
  onSponsorMarkEnd: () => void = () => {};
  onSponsorDraftStartChange: (value: number) => void = () => {};
  onSponsorDraftEndChange: (value: number) => void = () => {};
  onSponsorDraftCategoryChange: (value: string) => void = () => {};
  onSponsorDraftActionChange: (value: string) => void = () => {};
  onSponsorPreview: () => void = () => {};
  onSponsorClear: () => void = () => {};
  onSponsorSubmit: () => void = () => {};
  onSponsorSegmentSeek: (segment: SponsorBlockSegment) => void = () => {};
  onSponsorSegmentVote: (segment: SponsorBlockSegment, type: number) => void = () => {};
  onSponsorUserNameChange: (value: string) => void = () => {};
  onSponsorSaveUserName: () => void = () => {};
  onSponsorAcknowledgeWarning: () => void = () => {};
  onShare: () => void = () => {};
  onWatchLater: () => void = () => {};
  onCopyLink: () => void = () => {};
  onStub: (message: string) => void = () => {};

  @Builder
  EmbeddedPanel(which: number) {
    PlayerSettingsPanel({
      which: which,
      fullscreen: this.fullscreen,
      embedded: true,
      forceDark: this.fullscreen,
      accent: this.accent,
      dmOpacity: this.dmOpacity,
      dmFrameRate: this.dmFrameRate,
      dmSpeed: this.dmSpeed,
      dmFontScale: this.dmFontScale,
      dmSpacing: this.dmSpacing,
      dmDensity: this.dmDensity,
      dmBlockLevel: this.dmBlockLevel,
      blockScrollDm: this.blockScrollDm,
      blockTopDm: this.blockTopDm,
      blockBottomDm: this.blockBottomDm,
      blockColorDm: this.blockColorDm,
      qualityOptions: this.qualityOptions,
      activeQuality: this.activeQuality,
      chapters: this.chapters,
      currentTime: this.currentTime,
      playbackRate: this.playbackRate,
      subtitles: this.subtitles,
      subtitleIndex: this.subtitleIndex,
      subtitleOn: this.subtitleOn,
      dmFilterRulesCount: this.dmFilterRulesCount,
      onSubtitleChange: (index: number) => this.onSubtitleChange(index),
      onResetDanmaku: () => this.onResetDanmaku(),
      onDmOpacityChange: (value: number) => this.onDmOpacityChange(value),
      onDmFrameRateChange: (value: number) => this.onDmFrameRateChange(value),
      onDmSpeedChange: (value: number) => this.onDmSpeedChange(value),
      onDmFontScaleChange: (value: number) => this.onDmFontScaleChange(value),
      onDmSpacingChange: (value: number) => this.onDmSpacingChange(value),
      onDmDensityChange: (value: number) => this.onDmDensityChange(value),
      onDmBlockLevelChange: (value: number) => this.onDmBlockLevelChange(value),
      onDmFilterTap: () => this.onDmFilterOpen(),
      onBlockAdvancedToggle: (next: boolean) => this.onDmBlockLevelChange(next ? 1 : 0),
      onToggleDmBlock: (kind: string) => this.onToggleDmBlock(kind),
      onQualityChange: (qn: number) => this.onQualityChange(qn),
      onChapterChange: (seconds: number) => this.onChapterChange(seconds),
      onSpeedChange: (rate: number) => this.onSpeedChange(rate),
    })
  }

  build() {
    Column({ space: 4 }) {
      if (this.page !== 'menu') {
        Column() {
          Row({ space: 8 }) {
            Image($r('app.media.ic_back'))
              .width(24)
              .height(24)
              .renderMode(ImageRenderMode.Template)
              .fillColor((this.fullscreen || this.isDark) ? '#FFFFFF' : '#18191C')
            Text('返回')
              .fontSize(15)
              .fontColor((this.fullscreen || this.isDark) ? '#FFFFFF' : '#18191C')
            Blank()
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 4, bottom: 10 })
          .onClick(() => this.onBack())
          Column() {
            if (this.page === 'danmakuList' || this.page === 'dmFilter') {
              if (this.page === 'danmakuList') {
                DanmakuListPanel({
                  source: this.dmListSource,
                  count: this.dmListCount,
                  embedded: true,
                  forceDark: this.fullscreen,
                  onSeek: (seconds: number) => this.onSeek(seconds),
                  onReport: (item: DanmakuItem) => this.onReportDm(item),
                  onClose: () => this.onClose(),
                })
              } else {
                DmFilterPanel({
                  source: this.dmFilterRuleSource,
                  loading: this.dmFilterLoading,
                  filterType: this.dmFilterType,
                  draft: this.dmFilterDraft,
                  rulesCount: this.dmFilterRulesCount,
                  embedded: true,
                  forceDark: this.fullscreen,
                  onTypeChange: (type: number) => this.onFilterTypeChange(type),
                  onDraftChange: (draft: string) => this.onFilterDraftChange(draft),
                  onAdd: () => this.onFilterAdd(),
                  onDelete: (id: number) => this.onFilterDelete(id),
                })
              }
            } else {
              Scroll() {
                Column({ space: 10 }) {
                  if (this.page === 'quality') {
                    this.EmbeddedPanel(1)
                    PlayerPlaySettingsPage({
                      forceDark: this.fullscreen,
                      qualityPref: this.qualityPref,
                      downloadQualityLabel: this.downloadQualityLabel,
                      downloadBusy: this.downloadBusy,
                      downloadProgress: this.downloadProgress,
                      onQualityPrefChange: (pref: number) => this.onQualityPrefChange(pref),
                      onDownloadQuality: () => this.onDownloadQuality(),
                      onDownload: () => this.onDownload(),
                      onStub: (message: string) => this.onStub(message),
                    })
                  } else if (this.page === 'speed') {
                    this.EmbeddedPanel(3)
                  } else if (this.page === 'dm') {
                    this.EmbeddedPanel(0)
                  } else if (this.page === 'chapters') {
                    this.EmbeddedPanel(2)
                  } else if (this.page === 'sponsor') {
                    SponsorBlockPanel({
                      forceDark: this.fullscreen || this.isDark,
                      accent: this.accent,
                      currentTime: this.currentTime,
                      duration: this.duration,
                      categories: $sponsorCategories,
                      segments: $sponsorSegments,
                      draftStart: $sponsorDraftStart,
                      draftEnd: $sponsorDraftEnd,
                      draftCategory: $sponsorDraftCategory,
                      draftAction: $sponsorDraftAction,
                      submitting: $sponsorSubmitting,
                      userLoading: $sponsorUserLoading,
                      userName: $sponsorUserName,
                      userStats: $sponsorUserStats,
                      warningReason: $sponsorWarningReason,
                      onModeChange: (category: string, mode: number) => this.onSponsorModeChange(category, mode),
                      onRefresh: () => this.onSponsorRefresh(),
                      onMarkStart: () => this.onSponsorMarkStart(),
                      onMarkEnd: () => this.onSponsorMarkEnd(),
                      onDraftStartChange: (value: number) => this.onSponsorDraftStartChange(value),
                      onDraftEndChange: (value: number) => this.onSponsorDraftEndChange(value),
                      onDraftCategoryChange: (value: string) => this.onSponsorDraftCategoryChange(value),
                      onDraftActionChange: (value: string) => this.onSponsorDraftActionChange(value),
                      onPreview: () => this.onSponsorPreview(),
                      onClear: () => this.onSponsorClear(),
                      onSubmit: () => this.onSponsorSubmit(),
                      onSegmentSeek: (segment: SponsorBlockSegment) => this.onSponsorSegmentSeek(segment),
                      onSegmentVote: (segment: SponsorBlockSegment, type: number) =>
                        this.onSponsorSegmentVote(segment, type),
                      onUserNameChange: (value: string) => this.onSponsorUserNameChange(value),
                      onSaveUserName: () => this.onSponsorSaveUserName(),
                      onAcknowledgeWarning: () => this.onSponsorAcknowledgeWarning(),
                    })
                  }
                }
                .width('100%')
              }
              .layoutWeight(1)
              .width('100%')
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
            }
          }
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)
        .transition(TransitionEffect.move(TransitionEdge.END).combine(TransitionEffect.opacity(0.5)))
      } else {
        PlayerMoreSheet({
          forceDark: this.fullscreen,
          playbackRate: this.playbackRate,
          playMode: this.playMode,
          qualityLabel: this.qualityLabel,
          qualityLoading: this.qualityLoading,
          mirrorOn: this.mirrorOn,
          timerMinutes: this.timerMinutes,
          chaptersCount: this.chapters.length,
          sponsorOn: this.sponsorOn,
          subtitleOn: this.subtitleOn,
          backgroundPlaybackEnabled: this.backgroundPlaybackEnabled,
          downloadBusy: this.downloadBusy,
          downloadProgress: this.downloadProgress,
          onSpeedChange: (rate: number) => this.onSpeedChange(rate),
          onPlayModeChange: (mode: number) => this.onPlayModeChange(mode),
          onTimerChange: (minutes: number) => this.onTimerChange(minutes),
          onMirrorChange: (next: boolean) => this.onMirrorChange(next),
          onQuality: () => this.onOpenPage('quality'),
          onDmSettings: () => this.onOpenPage('dm'),
          onChapters: () => this.onOpenPage('chapters'),
          onSubtitleToggle: (next: boolean) => this.onSubtitleToggle(next),
          onPictureInPicture: () => this.onPictureInPicture(),
          onReportVideo: () => this.onReportVideo(),
          onBackgroundPlaybackChange: (next: boolean) => this.onBackgroundPlaybackChange(next),
          onSponsorToggle: (next: boolean) => this.onSponsorToggle(next),
          onSponsorSettings: () => this.onOpenPage('sponsor'),
          onShare: () => this.onShare(),
          onWatchLater: () => this.onWatchLater(),
          onCopyLink: () => this.onCopyLink(),
          onDownload: () => this.onDownload(),
          onStub: (message: string) => this.onStub(message),
        })
        .transition(TransitionEffect.move(TransitionEdge.START).combine(TransitionEffect.opacity(0.5)))
      }
    }
    .width('100%')
    .height('100%')
    .padding(this.page === 'menu' ?
      { left: 0, right: 0, top: 0, bottom: 0 } :
      { left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor((this.fullscreen || this.isDark) ? '#18191C' : '#F5F6F7')
  }
}
