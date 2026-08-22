import { SponsorBlockCategory, SponsorBlockMode, SponsorBlockSegment, sponsorBlockActionLabel,
  sponsorBlockCategory, sponsorBlockModeLabel, sponsorBlockSupportedActions } from '../../common/SponsorBlock';
import { formatDuration } from '../../common/Utils';

@Component
export struct SponsorBlockPanel {
  @Prop forceDark: boolean = false;
  @Prop accent: string = '#FB7299';
  @Prop currentTime: number = 0;
  @Prop duration: number = 0;
  @Link categories: Array<SponsorBlockCategory>;
  @Link segments: Array<SponsorBlockSegment>;
  @Link draftStart: number;
  @Link draftEnd: number;
  @Link draftCategory: string;
  @Link draftAction: string;
  @Link submitting: boolean;
  @Link userLoading: boolean;
  @Link userName: string;
  @Link userStats: string;
  @Link warningReason: string;
  onModeChange: (category: string, mode: number) => void = () => {};
  onRefresh: () => void = () => {};
  onMarkStart: () => void = () => {};
  onMarkEnd: () => void = () => {};
  onDraftStartChange: (value: number) => void = () => {};
  onDraftEndChange: (value: number) => void = () => {};
  onDraftCategoryChange: (value: string) => void = () => {};
  onDraftActionChange: (value: string) => void = () => {};
  onPreview: () => void = () => {};
  onClear: () => void = () => {};
  onSubmit: () => void = () => {};
  onSegmentSeek: (segment: SponsorBlockSegment) => void = () => {};
  onSegmentVote: (segment: SponsorBlockSegment, type: number) => void = () => {};
  onUserNameChange: (value: string) => void = () => {};
  onSaveUserName: () => void = () => {};
  onAcknowledgeWarning: () => void = () => {};

  private titleColor(): string {
    return this.forceDark ? '#F2FFFFFF' : '#18191C';
  }

  private subColor(): string {
    return this.forceDark ? '#A8FFFFFF' : '#6D7278';
  }

  private dividerColor(): string {
    return this.forceDark ? '#24FFFFFF' : '#14000000';
  }

  private fieldColor(): string {
    return this.forceDark ? '#20FFFFFF' : '#FFFFFFFF';
  }

  private nextMode(mode: number): number {
    return mode >= SponsorBlockMode.AUTO ? SponsorBlockMode.DISABLED : mode + 1;
  }

  private changeCategoryMode(category: SponsorBlockCategory): void {
    const mode: number = this.nextMode(category.mode);
    category.mode = mode;
    this.categories = this.categories.slice();
    this.onModeChange(category.name, mode);
  }

  private parseTime(value: string, fallback: number): number {
    if (value.trim().length === 0) return -1;
    const parsed: number = Number(value);
    if (Number.isNaN(parsed)) return fallback;
    return Math.max(0, Math.min(this.duration > 0 ? this.duration : parsed, parsed));
  }

  @Builder
  SectionTitle(title: string, subtitle: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.titleColor())
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(11)
          .fontColor(this.subColor())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  IconButton(icon: Resource, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Image(icon)
        .width(18)
        .height(18)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.titleColor())
    }
    .width(34)
    .height(34)
    .onClick(() => onTap())
  }

  @Builder
  Command(getLabel: () => string, primary: boolean, getEnabled: () => boolean, onTap: () => void) {
    Text(getLabel())
      .fontSize(13)
      .fontWeight(primary ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(getEnabled() ? (primary ? '#FFFFFF' : this.titleColor()) : this.subColor())
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(4)
      .backgroundColor(primary && getEnabled() ? this.accent : this.fieldColor())
      .opacity(getEnabled() ? 1 : 0.55)
      .onClick(() => {
        if (getEnabled()) onTap();
      })
  }

  @Builder
  CategoryStrategies() {
    Column() {
      ForEach(this.categories, (category: SponsorBlockCategory, index: number) => {
        Row({ space: 10 }) {
          Row()
            .width(10)
            .height(28)
            .borderRadius(2)
            .backgroundColor(category.color)
          Column({ space: 2 }) {
            Text(category.label)
              .fontSize(14)
              .fontColor(this.titleColor())
            Text(category.name)
              .fontSize(10)
              .fontColor(this.subColor())
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(sponsorBlockModeLabel(category.mode))
            .fontSize(12)
            .fontColor(category.mode === SponsorBlockMode.AUTO ? this.accent : this.subColor())
          Image($r('app.media.ic_arrow_right'))
            .width(12)
            .height(12)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.subColor())
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .onClick(() => this.changeCategoryMode(category))
        if (index < this.categories.length - 1) {
          Divider().strokeWidth(0.5).color(this.dividerColor()).margin({ left: 20 })
        }
      }, (category: SponsorBlockCategory) => category.name + '-' + String(category.mode))
    }
    .width('100%')
  }

  @Builder
  TimeField(label: string, getValue: () => number, onChange: (value: number) => void) {
    Column({ space: 4 }) {
      Text(label).fontSize(11).fontColor(this.subColor())
      TextInput({ text: getValue() >= 0 ? getValue().toFixed(3) : '', placeholder: '--:--' })
        .type(InputType.Normal)
        .inputFilter('[0-9.]')
        .fontSize(13)
        .fontColor(this.titleColor())
        .backgroundColor(this.fieldColor())
        .borderRadius(4)
        .height(38)
        .onChange((text: string) => onChange(this.parseTime(text, getValue())))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  SubmissionEditor() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        this.TimeField('开始（秒）', () => this.draftStart,
          (value: number) => this.onDraftStartChange(value))
        this.TimeField('结束（秒）', () => this.draftEnd,
          (value: number) => this.onDraftEndChange(value))
      }
      .width('100%')

      Row({ space: 8 }) {
        this.Command(() => '标记开始', false, () => true, () => this.onMarkStart())
        this.Command(() => '标记结束', false, () => true, () => this.onMarkEnd())
        Text('播放头 ' + formatDuration(this.currentTime))
          .fontSize(11)
          .fontColor(this.subColor())
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Text('分类').fontSize(11).fontColor(this.subColor()).width('100%')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.categories, (category: SponsorBlockCategory) => {
          if (category.name !== 'exclusive_access' || this.draftAction === 'full') {
            Text(category.label)
              .fontSize(12)
              .fontWeight(this.draftCategory === category.name ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.draftCategory === category.name ? category.color : this.subColor())
              .decoration({ type: this.draftCategory === category.name ? TextDecorationType.Underline :
                TextDecorationType.None, color: category.color })
              .padding({ right: 14, top: 5, bottom: 5 })
              .onClick(() => this.onDraftCategoryChange(category.name))
          }
        }, (category: SponsorBlockCategory) => 'draft-' + category.name + '-' +
          String(this.draftCategory === category.name) + '-' + this.draftAction)
      }
      .width('100%')

      Text('动作').fontSize(11).fontColor(this.subColor()).width('100%')
      Row({ space: 18 }) {
        ForEach(sponsorBlockSupportedActions(this.draftCategory), (action: string) => {
          Text(sponsorBlockActionLabel(action))
            .fontSize(12)
            .fontWeight(this.draftAction === action ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.draftAction === action ? this.accent : this.subColor())
            .decoration({ type: this.draftAction === action ? TextDecorationType.Underline :
              TextDecorationType.None, color: this.accent })
            .onClick(() => this.onDraftActionChange(action))
        }, (action: string) => action + '-' + String(this.draftAction === action))
      }
      .width('100%')

      Row({ space: 8 }) {
        this.Command(() => '预览', false, () => this.draftStart >= 0, () => this.onPreview())
        this.Command(() => '清除', false, () => this.draftStart >= 0 || this.draftEnd >= 0,
          () => this.onClear())
        Blank()
        this.Command(() => this.submitting ? '提交中' : '提交片段', true,
          () => !this.submitting && this.draftStart >= 0, () => this.onSubmit())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 4, bottom: 8 })
  }

  @Builder
  SegmentList() {
    Column() {
      if (this.segments.length === 0) {
        Text('当前分 P 暂无社区片段')
          .fontSize(13)
          .fontColor(this.subColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 18, bottom: 18 })
      } else {
        ForEach(this.segments, (segment: SponsorBlockSegment, index: number) => {
          Row({ space: 8 }) {
            Row()
              .width(4)
              .height(34)
              .borderRadius(2)
              .backgroundColor(sponsorBlockCategory(segment.category).color)
            Column({ space: 2 }) {
              Text(sponsorBlockCategory(segment.category).label + ' · ' + sponsorBlockActionLabel(segment.actionType))
                .fontSize(13)
                .fontColor(this.titleColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(formatDuration(segment.start) + ' - ' + formatDuration(segment.end) +
                (segment.votes !== 0 ? ' · ' + String(segment.votes) + ' 票' : ''))
                .fontSize(10)
                .fontColor(this.subColor())
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            this.IconButton($r('app.media.ic_play_feedback'), () => this.onSegmentSeek(segment))
            if (segment.uuid.length > 0) {
              this.IconButton($r('app.media.ic_like'), () => this.onSegmentVote(segment, 1))
              this.IconButton($r('app.media.ic_dislike'), () => this.onSegmentVote(segment, 0))
            }
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          if (index < this.segments.length - 1) {
            Divider().strokeWidth(0.5).color(this.dividerColor()).margin({ left: 12 })
          }
        }, (segment: SponsorBlockSegment, index: number) => segment.uuid + '-' + String(index) + '-' +
          String(segment.votes))
      }
    }
    .width('100%')
  }

  @Builder
  CommunityProfile() {
    Column({ space: 9 }) {
      if (this.warningReason.length > 0) {
        Column({ space: 7 }) {
          Text('社区提醒')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFB44C')
          Text(this.warningReason)
            .fontSize(12)
            .fontColor(this.titleColor())
            .width('100%')
          Row() {
            Blank()
            this.Command(() => '我已了解', true, () => true, () => this.onAcknowledgeWarning())
          }
          .width('100%')
        }
        .width('100%')
        .padding(10)
        .border({ width: 1, color: '#66FFB44C' })
        .borderRadius(4)
      }
      TextInput({ text: this.userName, placeholder: this.userLoading ? '正在读取社区身份' : '设置空降昵称' })
        .fontSize(13)
        .fontColor(this.titleColor())
        .backgroundColor(this.fieldColor())
        .borderRadius(4)
        .height(40)
        .onChange((value: string) => this.onUserNameChange(value))
      Row() {
        Text(this.userStats.length > 0 ? this.userStats : '匿名身份仅用于投稿与投票')
          .fontSize(11)
          .fontColor(this.subColor())
          .layoutWeight(1)
          .maxLines(2)
        this.Command(() => '保存昵称', false, () => !this.userLoading, () => this.onSaveUserName())
      }
      .width('100%')
    }
    .width('100%')
  }

  build() {
    Column({ space: 8 }) {
      this.SectionTitle('社区身份', '')
      this.CommunityProfile()
      Divider().strokeWidth(0.7).color(this.dividerColor()).margin({ top: 6, bottom: 6 })
      Row() {
        Column({ space: 2 }) {
          Text('分类策略')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Text('点击每一项切换：关闭、仅显示、手动跳过、自动跳过')
            .fontSize(11)
            .fontColor(this.subColor())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        this.IconButton($r('app.media.ic_refresh'), () => this.onRefresh())
      }
      .width('100%')
      this.CategoryStrategies()
      Divider().strokeWidth(0.7).color(this.dividerColor()).margin({ top: 6, bottom: 6 })
      this.SectionTitle('标注片段', '标记当前分 P 的片段并提交到空降指挥部')
      this.SubmissionEditor()
      Divider().strokeWidth(0.7).color(this.dividerColor()).margin({ top: 6, bottom: 6 })
      this.SectionTitle('社区片段', String(this.segments.length) + ' 个片段')
      this.SegmentList()
    }
    .width('100%')
  }
}
