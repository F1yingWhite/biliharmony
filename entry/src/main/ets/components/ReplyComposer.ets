import { BiliEmote, BiliEmotePackage } from '../model/Models';

/** 视频评论与动态评论共用的底部发送栏。父页面只负责草稿与请求。 */
@Component
export struct ReplyComposer {
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop @Watch('onPackagesChanged') emotePackages: Array<BiliEmotePackage> = [];
  @Prop placeholder: string = '发一条友善的评论';
  @Prop sending: boolean = false;
  @Prop emoteOpen: boolean = false;
  @Prop showEmoteButton: boolean = true;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @State focused: boolean = false;
  private editorController: RichEditorController = new RichEditorController();
  private editorReady: boolean = false;
  private syncingEditor: boolean = false;
  onChange: (value: string) => void = () => {};
  onSend: () => void = () => {};
  onToggleEmote: () => void = () => {};
  onRequestKeyboard: () => void = () => {};

  private expanded(): boolean {
    return this.focused || this.emoteOpen || this.text.length > 0;
  }

  private textStyle(): RichEditorTextStyle {
    return {
      fontSize: 14,
      fontColor: this.isDark ? '#FFFFFF' : '#18191C',
    };
  }

  private allEmotes(): Array<BiliEmote> {
    const result: Array<BiliEmote> = [];
    for (let i: number = 0; i < this.emotePackages.length; i++) {
      const items: Array<BiliEmote> = this.emotePackages[i].emotes;
      for (let j: number = 0; j < items.length; j++) result.push(items[j]);
    }
    // 某些表情 token 互为前缀，优先匹配更长的一个。
    result.sort((left: BiliEmote, right: BiliEmote) => right.text.length - left.text.length);
    return result;
  }

  private emoteAt(value: string, offset: number, emotes: Array<BiliEmote>): BiliEmote | null {
    for (let i: number = 0; i < emotes.length; i++) {
      const item: BiliEmote = emotes[i];
      if (item.text.length > 0 && value.substring(offset, offset + item.text.length) === item.text) return item;
    }
    return null;
  }

  private tokenForImage(value: ResourceStr | undefined): string {
    if (value === undefined) return '';
    const url: string = String(value);
    const emotes: Array<BiliEmote> = this.allEmotes();
    for (let i: number = 0; i < emotes.length; i++) {
      if (emotes[i].url === url) return emotes[i].text;
    }
    return '';
  }

  /** RichEditor 内图片占一个字符；提交前再还原成 B 站接口需要的 [token]。 */
  private editorPlainText(): string {
    if (!this.editorReady) return this.text;
    const spans: Array<RichEditorImageSpanResult | RichEditorTextSpanResult> = this.editorController.getSpans();
    let value: string = '';
    for (let i: number = 0; i < spans.length; i++) {
      const imageSpan: RichEditorImageSpanResult = spans[i] as RichEditorImageSpanResult;
      if (imageSpan.valueResourceStr !== undefined) {
        value += this.tokenForImage(imageSpan.valueResourceStr);
      } else {
        const textSpan: RichEditorTextSpanResult = spans[i] as RichEditorTextSpanResult;
        value += textSpan.value;
      }
    }
    return value;
  }

  private syncFromProp(force: boolean = false): void {
    if (!this.editorReady || this.syncingEditor) return;
    if (!force && this.editorPlainText() === this.text) return;
    this.syncingEditor = true;
    this.editorController.deleteSpans();
    this.editorController.setTypingStyle(this.textStyle());
    const emotes: Array<BiliEmote> = this.allEmotes();
    let plainStart: number = 0;
    let offset: number = 0;
    let editorOffset: number = 0;
    while (offset < this.text.length) {
      const emote: BiliEmote | null = this.emoteAt(this.text, offset, emotes);
      if (emote === null) {
        offset++;
        continue;
      }
      if (offset > plainStart) {
        const content: string = this.text.substring(plainStart, offset);
        this.editorController.addTextSpan(content, { style: this.textStyle() });
        editorOffset += content.length;
      }
      this.editorController.addImageSpan(emote.url, {
        imageStyle: {
          size: [22, 22],
          verticalAlign: ImageSpanAlignment.CENTER,
          objectFit: ImageFit.Contain,
        },
      });
      editorOffset++;
      offset += emote.text.length;
      plainStart = offset;
    }
    if (plainStart < this.text.length) {
      const content: string = this.text.substring(plainStart);
      this.editorController.addTextSpan(content, { style: this.textStyle() });
      editorOffset += content.length;
    }
    this.editorController.setCaretOffset(editorOffset);
    this.syncingEditor = false;
  }

  private onTextChanged(): void {
    this.syncFromProp();
  }

  private onPackagesChanged(): void {
    // 表情包异步到达时，把草稿里已经存在的 token 就地升级成图片 span。
    this.syncFromProp(true);
  }

  @Builder
  EmoteButton() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.emoteOpen ? $r('app.media.ic_keyboard') : $r('app.media.ic_emoji'))
        .width(24)
        .height(24)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.emoteOpen ? this.accent : '#8E939B')
    }
    .width(38)
    .height(38)
    .borderRadius(19)
    .onClick(() => this.onToggleEmote())
  }

  build() {
    Column({ space: this.expanded() ? 6 : 0 }) {
      Row({ space: 8 }) {
        RichEditor({ controller: this.editorController })
          .height(this.expanded() ? 48 : 38)
          .layoutWeight(1)
          .caretColor(this.accent)
          .placeholder(this.placeholder, {
            font: { size: this.expanded() ? 14 : 13 },
            fontColor: '#B8BCC3',
          })
          .padding({ left: this.expanded() ? 12 : 14, right: this.expanded() ? 12 : 14, top: 8, bottom: 8 })
          .backgroundColor('#00000000')
          .enterKeyType(EnterKeyType.Send)
          .enableKeyboardOnFocus(true)
          .maxLines(2)
          .barState(BarState.Off)
          .onReady(() => {
            this.editorReady = true;
            this.syncFromProp(true);
          })
          .onFocus(() => {
            this.focused = true;
            this.onRequestKeyboard();
          })
          .onBlur(() => this.focused = false)
          .onClick(() => this.onRequestKeyboard())
          .onDidChange(() => {
            if (this.syncingEditor) return;
            const value: string = this.editorPlainText();
            if (value !== this.text) this.onChange(value);
          })
          .onSubmit(() => this.onSend())
        if (!this.expanded() && this.showEmoteButton) this.EmoteButton()
      }
      .width('100%')
      .height(this.expanded() ? 48 : 40)
      .padding({ left: this.expanded() ? 0 : 0, right: this.expanded() ? 0 : 0 })
      .borderRadius(this.expanded() ? 0 : 19)
      .backgroundColor(this.expanded() ? '#00000000' : (this.isDark ? '#292A2E' : '#F5F7F9'))

      if (this.expanded()) {
        Row({ space: 8 }) {
          if (this.showEmoteButton) this.EmoteButton()
          Blank()
          Button(this.sending ? '发布中…' : '发布')
            .height(36)
            .padding({ left: 18, right: 18 })
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accent)
            .borderRadius(18)
            .opacity(!this.sending && this.text.trim().length > 0 ? 1 : 0.45)
            .enabled(!this.sending && this.text.trim().length > 0)
            .onClick(() => this.onSend())
        }
        .width('100%')
        .height(40)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.expanded() ? 6 : 8, bottom: 8 })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }
}
