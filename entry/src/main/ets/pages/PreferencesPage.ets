import { AppTheme } from '../common/AppTheme';
import { Handedness } from '../common/Handedness';
import { Immersive } from '../common/Immersive';
import { PlayerQualityPreference } from '../common/PlayerQualityPreference';
import { PageHeader } from '../components/PageHeader';

@Component
struct PreferenceRow {
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop value: string = '';
  @Prop toggle: boolean = false;
  @Prop checked: boolean = false;
  @Prop rowEnabled: boolean = true;
  onChange: (value: boolean) => void = () => {};
  onOpen: () => void = () => {};
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';

  build() {
    Row({ space: 14 }) {
      Column({ space: 6 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#F2F3F5' : '#202127')
        if (this.detail.length > 0) {
          Text(this.detail).fontSize(12).fontColor(this.isDark ? '#A1A5AE' : '#737985').lineHeight(18)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.toggle) {
        Toggle({ type: ToggleType.Switch, isOn: this.checked }).selectedColor(this.accent)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityText(this.title)
      } else {
        Text(this.value).fontSize(13).fontColor(this.accent).constraintSize({ maxWidth: 110 })
        Text('›').fontSize(22).fontColor('#9499A0')
      }
    }.width('100%').constraintSize({ minHeight: 76 }).padding(18)
    .enabled(this.rowEnabled).opacity(this.rowEnabled ? 1 : 0.45)
    .onClick(() => { if (this.toggle) this.onChange(!this.checked); else this.onOpen(); })
  }
}

@Component
export struct PreferencesPage {
  @Prop playback: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('userAccentColor') userAccent: string = '#FB7299';
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('autoDarkEnabled') autoDark: boolean = false;
  @StorageProp('autoDarkStart') start: string = '19:00';
  @StorageProp('autoDarkEnd') end: string = '07:00';
  @StorageProp('dockSearchSide') side: string = 'right';
  @StorageProp('dockSearchSidePinned') pinned: boolean = false;
  @StorageProp('backgroundPlaybackEnabled') backgroundOn: boolean = false;
  @StorageProp('autoContinuePlay') autoContinue: boolean = true;
  @StorageProp('videoQualityPref') quality: number = 0;
  @StorageProp('videoManualQuality') manualQuality: number = 0;
  @StorageProp('playerDoubleTapEnabled') doubleTap: boolean = true;
  @StorageProp('playerPanEnabled') pan: boolean = true;
  @StorageProp('playerHoldEnabled') hold: boolean = true;
  @StorageProp('recommendMode') recommendMode: string = 'web';
  @State editingTime: boolean = false;
  @State startHour: number = 19;
  @State startMinute: number = 0;
  @State endHour: number = 7;
  @State endMinute: number = 0;

  private surface(): string { return this.isDark ? '#25262C' : '#FFFFFF'; }
  private ink(): string { return this.isDark ? '#F2F3F5' : '#202127'; }

  private chooseHand(): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '搜索按钮位置',
      buttons: [{ text: '跟随操作手', color: this.ink() }, { text: '固定左侧', color: this.ink() }, { text: '固定右侧', color: this.ink() }],
    }).then((result) => {
      if (result.index === 0) Handedness.useAutomatic();
      else if (result.index === 1) Handedness.pin(Handedness.LEFT);
      else if (result.index === 2) Handedness.pin(Handedness.RIGHT);
    }).catch(() => {});
  }

  private chooseQuality(): void {
    this.getUIContext().getPromptAction().showActionMenu({ title: '默认画质策略',
      buttons: [{ text: '自动', color: this.ink() }, { text: '高码率', color: this.ink() }, { text: '高清高码', color: this.ink() }, { text: '智能省流', color: this.ink() }],
    }).then((result) => {
      if (result.index >= 0 && result.index <= 3) PlayerQualityPreference.useMode(result.index);
    }).catch(() => {});
  }

  private openTime(): void {
    this.startHour = Number(this.start.split(':')[0]);
    this.startMinute = Number(this.start.split(':')[1]);
    this.endHour = Number(this.end.split(':')[0]);
    this.endMinute = Number(this.end.split(':')[1]);
    this.editingTime = !this.editingTime;
  }

  private time(hour: number, minute: number): string {
    return String(hour).padStart(2, '0') + ':' + String(minute).padStart(2, '0');
  }

  private date(hour: number, minute: number): Date {
    const date: Date = new Date();
    date.setHours(hour, minute, 0, 0);
    return date;
  }

  private saveTime(): void {
    const start: string = this.time(this.startHour, this.startMinute);
    const end: string = this.time(this.endHour, this.endMinute);
    if (start === end) {
      this.getUIContext().getPromptAction().showToast({ message: '开始与结束时间不能相同' });
      return;
    }
    AppTheme.setAutoDarkWindow(start, end);
    this.editingTime = false;
  }

  @Builder
  Section(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#9297A2')
      .width('100%').padding({ left: 8, top: 10, bottom: 2 })
  }

  @Builder
  DividerLine() {
    Divider().strokeWidth(0.5).color(this.isDark ? '#18FFFFFF' : '#10000000').margin({ left: 18, right: 18 })
  }

  @Builder
  Preview() {
    Column({ space: 18 }) {
      Row() {
        Text('你的观看空间').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.ink())
        Blank()
        Text('实时预览').fontSize(10).fontColor(this.accent).padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(this.isDark ? '#18FFFFFF' : '#09000000').borderRadius(10)
      }
      Row({ space: 14 }) {
        Stack() {
          Rect().fill(this.accent).width('100%').height('100%').opacity(0.15)
          SymbolGlyph($r('sys.symbol.play_fill')).fontSize(25).fontColor([this.accent])
          Text('08:24').fontSize(10).fontColor(this.ink()).position({ right: 8, bottom: 7 })
        }.width(110).height(72).borderRadius(14).clip(true)
        Column({ space: 7 }) {
          Text('把喜欢的内容\n留给每一次打开').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.ink()).lineHeight(22)
          Text('视频卡片 · 播放进度').fontSize(11).fontColor('#9499A0')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Progress({ value: 38, total: 100, type: ProgressType.Linear }).color(this.accent)
        .backgroundColor(this.isDark ? '#15FFFFFF' : '#0A000000').width('100%')
      Row({ space: 10 }) {
        if (this.side === 'left') { this.PreviewSearch() }
        Row() {
          ForEach(['首页', '动态', '我的'], (label: string, index: number) => {
            Text(label).fontSize(12).fontWeight(index === 0 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(index === 0 ? this.accent : '#9297A2').layoutWeight(1).textAlign(TextAlign.Center)
          })
        }.height(42).layoutWeight(1).borderRadius(22)
          .backgroundColor(this.glassOn ? (this.isDark ? '#18FFFFFF' : '#BBFFFFFF') : (this.isDark ? '#34353D' : '#ECEEF2'))
          .border({ width: 0.5, color: this.isDark ? '#16FFFFFF' : '#15000000' })
        if (this.side !== 'left') { this.PreviewSearch() }
      }.width('100%')
    }.padding(22).width('100%').borderRadius(24).backgroundColor(this.surface())
  }

  @Builder
  PreviewSearch() {
    SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor([this.accent])
      .width(42).height(42).borderRadius(21).backgroundColor(this.isDark ? '#18FFFFFF' : '#09000000')
  }

  @Builder
  Appearance() {
    this.Preview()
    this.Section('色彩与显示')
    Column({ space: 16 }) {
      Text('显示模式').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink()).width('100%')
      Row({ space: 8 }) {
        ForEach(['跟随系统', '浅色', '深色'], (label: string, index: number) => {
          Button(label).fontSize(12).layoutWeight(1).height(38)
            .fontColor(this.themeMode === ['system', 'light', 'dark'][index] ? '#FFFFFF' : this.ink())
            .backgroundColor(this.themeMode === ['system', 'light', 'dark'][index] ? this.accent : (this.isDark ? '#34353D' : '#F0F1F5'))
            .onClick(() => AppTheme.setMode(['system', 'light', 'dark'][index]))
        })
      }.width('100%')
      this.DividerLine()
      Text('主题色').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink()).width('100%')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(AppTheme.PRESET_COLORS, (color: string) => {
          Stack() {
            Circle().fill(color).width(28).height(28)
            if (this.userAccent === color) {
              Circle().fill(Color.Transparent).stroke(color).strokeWidth(2).width(36).height(36)
            }
          }.width(40).height(44).accessibilityText('主题色 ' + color + (this.userAccent === color ? '，已选择' : ''))
            .onClick(() => AppTheme.setAccent(color))
        })
      }.width('100%')
    }.padding(18).width('100%').borderRadius(20).backgroundColor(this.surface())
    Column() {
      PreferenceRow({ title: '沉浸光感', detail: '为导航与浮层启用通透材质', toggle: true, checked: this.glassOn,
        onChange: (value: boolean) => AppTheme.setGlassEnabled(value) })
      this.DividerLine()
      PreferenceRow({ title: '首页推荐源', detail: this.recommendMode === 'app' ? 'App 推流：服务端个性化最强，翻页自动去重' : 'Web 个性化推荐：官方网页端同款会话协议',
        toggle: true, checked: this.recommendMode === 'app',
        onChange: (value: boolean) => {
          const mode: string = value ? 'app' : 'web';
          AppStorage.setOrCreate<string>('recommendMode', mode);
          AppTheme.persistRecommendMode(mode);
        } })
      this.DividerLine()
      PreferenceRow({ title: '定时深色', detail: this.themeMode === 'system' ? '按指定时段切换，支持跨午夜' : '切换为跟随系统后可用',
        toggle: true, checked: this.autoDark, rowEnabled: this.themeMode === 'system',
        onChange: (value: boolean) => { AppTheme.setAutoDarkEnabled(value); } })
      if (this.autoDark && this.themeMode === 'system') {
        this.DividerLine()
        PreferenceRow({ title: '深色时段', value: this.start + ' – ' + this.end, onOpen: () => this.openTime() })
        if (this.editingTime) {
          Row() {
            Column() {
              Text('开始').fontSize(12).fontColor('#9499A0')
              TimePicker({ selected: this.date(this.startHour, this.startMinute) }).useMilitaryTime(true).height(140)
                .onChange((value: TimePickerResult) => { this.startHour = value.hour; this.startMinute = value.minute; })
            }.layoutWeight(1)
            Column() {
              Text('结束').fontSize(12).fontColor('#9499A0')
              TimePicker({ selected: this.date(this.endHour, this.endMinute) }).useMilitaryTime(true).height(140)
                .onChange((value: TimePickerResult) => { this.endHour = value.hour; this.endMinute = value.minute; })
            }.layoutWeight(1)
          }.padding(12)
          Row({ space: 12 }) {
            Button('取消').layoutWeight(1).onClick(() => { this.editingTime = false; })
            Button('保存时段').layoutWeight(1).backgroundColor(this.accent).onClick(() => this.saveTime())
          }.padding(18)
        }
      }
    }.width('100%').borderRadius(20).backgroundColor(this.surface())
    this.Section('操作习惯')
    Column() {
      PreferenceRow({ title: '搜索按钮位置', detail: '自动跟随操作手，也可以固定在常用的一侧',
        value: !this.pinned ? '自动' : (this.side === 'left' ? '左侧' : '右侧'), onOpen: () => this.chooseHand() })
    }.width('100%').borderRadius(20).backgroundColor(this.surface())
  }

  @Builder
  Playback() {
    Column({ space: 9 }) {
      SymbolGlyph($r('sys.symbol.play_fill')).fontSize(25).fontColor([this.accent])
      Text('按你的习惯播放').fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.ink())
      Text('设置自动保存，播放器内的选项同步生效').fontSize(12).fontColor('#9499A0')
    }.width('100%').padding({ top: 22, bottom: 26 })
    this.Section('播放与后台')
    Column() {
      PreferenceRow({ title: '后台听视频', detail: '开启后，切到桌面继续播放声音；关闭时暂停', toggle: true, checked: this.backgroundOn,
        onChange: (value: boolean) => {
          AppStorage.setOrCreate<boolean>('backgroundPlaybackEnabled', value);
          AppTheme.persistBackgroundPlayback(value);
        } })
      this.DividerLine()
      PreferenceRow({ title: '自动连播', detail: '当前内容播完后继续下一集或推荐视频', toggle: true, checked: this.autoContinue,
        onChange: (value: boolean) => {
          AppStorage.setOrCreate<boolean>('autoContinuePlay', value);
          AppTheme.persistAutoContinue(value);
        } })
      this.DividerLine()
      PreferenceRow({ title: '默认画质', detail: '手选后记住上限，下次选择不高于它的最高可用画质',
        value: this.manualQuality > 0 ? '上次选择 · ' + PlayerQualityPreference.label(this.manualQuality) : ['自动', '高码率', '高清高码', '智能省流'][this.quality],
        onOpen: () => this.chooseQuality() })
    }.width('100%').borderRadius(20).backgroundColor(this.surface())
    this.Section('小窗播放')
    Row({ space: 14 }) {
      Image($r('app.media.ic_share_pip')).width(28).height(28).fillColor(this.accent)
      Column({ space: 7 }) {
        Text('从播放器进入小窗').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink())
        Text('播放时点右上角「⋮」→「小窗播放」。小窗在桌面继续播放画面与声音，不受后台听视频开关限制。')
          .fontSize(12).lineHeight(19).fontColor('#9499A0')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.padding(20).width('100%').borderRadius(20).backgroundColor(this.surface())
    this.Section('播放器手势')
    Column() {
      PreferenceRow({ title: '双击播放 / 暂停', detail: '双击画面快速切换播放状态', toggle: true, checked: this.doubleTap,
        onChange: (value: boolean) => AppTheme.setPlayerGesture('playerDoubleTapEnabled', value) })
      this.DividerLine()
      PreferenceRow({ title: '滑动调节', detail: '横滑调进度，左侧上下调亮度，右侧上下调音量', toggle: true, checked: this.pan,
        onChange: (value: boolean) => AppTheme.setPlayerGesture('playerPanEnabled', value) })
      this.DividerLine()
      PreferenceRow({ title: '长按倍速', detail: '长按画面临时加速，松开恢复原速', toggle: true, checked: this.hold,
        onChange: (value: boolean) => AppTheme.setPlayerGesture('playerHoldEnabled', value) })
    }.width('100%').borderRadius(20).backgroundColor(this.surface())
  }

  build() {
    Column() {
      PageHeader({ title: this.playback ? '播放设置' : '外观与交互', showDivider: false })
      Scroll() {
        Column({ space: 12 }) {
          if (this.playback) { this.Playback() } else { this.Appearance() }
          Text('更改自动保存').fontSize(11).fontColor('#9499A0').margin({ top: 10, bottom: 8 })
        }.width('100%').constraintSize({ maxWidth: 640 }).padding({ left: 18, right: 18, top: 12, bottom: 24 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191F' : '#F3F4F8')
  }
}
