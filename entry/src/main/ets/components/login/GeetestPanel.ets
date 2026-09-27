/**
 * 极验滑块验证弹层：本地 HTML + gt.js（static.geetest.com）渲染滑块，
 * 通过 console 桥回传校验三元组（challenge/validate/seccode）。
 *
 * 用 console 而不是 registerJavaScriptProxy：data: URL 上注册代理后必须 refresh()
 * 才生效，时序脆弱；console 桥零注册、行为可预期。gt/challenge 为服务端下发的
 * 字母数字串，拼进 JS 字面量前仍做白名单清洗。
 */
import { webview } from '@kit.ArkWeb';

const ANSWER_MARKER: string = '__BILI_GEETEST__';
const ERROR_MARKER: string = '__BILI_GEETEST_ERR__';

@CustomDialog
export struct GeetestPanel {
  controller?: CustomDialogController;
  @Link gt: string;
  @Link challenge: string;
  @State failed: boolean = false;
  @State loading: boolean = true;
  onAnswer: (challenge: string, validate: string, seccode: string) => void = () => {
  };
  private webController: webview.WebviewController = new webview.WebviewController();
  private startTimer: number = -1;

  private html(): string {
    return '<!DOCTYPE html><html><head><meta name="viewport" ' +
      'content="width=device-width,initial-scale=1,user-scalable=no">' +
      '<style>body{margin:0;background:#fff;font-family:sans-serif}' +
      '#c{display:flex;justify-content:center;padding-top:48px}</style></head><body>' +
      '<div id="c"></div>' +
      '<script src="https://static.geetest.com/static/tools/gt.js"><\/script>' +
      '<script>' +
      'function __biliReport(ok, payload){' +
      'console.log(ok ? "' + ANSWER_MARKER + '" : "' + ERROR_MARKER + '" + payload);}' +
      'function start(gt, challenge){' +
      'if (typeof initGeetest === "undefined"){__biliReport(false,"gt.js missing");return;}' +
      'initGeetest({gt:gt,challenge:challenge,product:"bind",new_captcha:true,lang:"zh-cn"},' +
      'function(o){o.onReady(function(){o.verify();});' +
      'o.onSuccess(function(){var r=o.getValidate();' +
      '__biliReport(true, JSON.stringify({challenge:r.geetest_challenge,' +
      'validate:r.geetest_validate,seccode:r.geetest_seccode}));});' +
      'o.onError(function(){__biliReport(false,"captcha error");});});}' +
      '<\/script></body></html>';
  }

  private start(): void {
    this.startTimer = setTimeout(() => {
      this.startTimer = -1;
      try {
        this.webController.runJavaScript(
          `start('${this.gt.replace(/[^A-Za-z0-9]/g, '')}','${this.challenge.replace(/[^A-Za-z0-9]/g, '')}')`);
      } catch (e) {
        // runJavaScript 失败时保持 loading 态，用户可关闭后重试。
      }
    }, 900);
  }

  build() {
    Column() {
      Row() {
        Text('安全验证')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#18191C')
          .layoutWeight(1)
        Text('✕')
          .fontSize(16)
          .fontColor('#9499A0')
          .padding(8)
          .onClick(() => {
            this.controller?.close();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 12, bottom: 4 })

      Stack() {
        Web({ src: 'data:text/html;charset=utf-8,' + encodeURIComponent(this.html()), controller: this.webController })
          .javaScriptAccess(true)
          .onPageEnd(() => {
            this.loading = false;
            this.start();
          })
          .onConsole((event: OnConsoleEvent): boolean => {
            const text: string = event.message.getMessage();
            if (text.startsWith(ANSWER_MARKER)) {
              // 校验通过：解析三元组交给调用方（gaia validate → 重试原请求）。
              try {
                const parsed: Record<string, Object> =
                  JSON.parse(text.substring(ANSWER_MARKER.length)) as Record<string, Object>;
                this.onAnswer(parsed['challenge'] === undefined ? '' : String(parsed['challenge']),
                  parsed['validate'] === undefined ? '' : String(parsed['validate']),
                  parsed['seccode'] === undefined ? '' : String(parsed['seccode']));
              } catch (e) {
                this.failed = true;
              }
              this.controller?.close();
            } else if (text.startsWith(ERROR_MARKER)) {
              this.failed = true;
            }
            return false;
          })
          .width('100%')
          .layoutWeight(1)

        if (this.loading && !this.failed) {
          LoadingProgress().width(32).height(32).color('#FB7299')
        }
        if (this.failed) {
          Column({ space: 10 }) {
            Text('验证组件加载失败，请检查网络后重试')
              .fontSize(13)
              .fontColor('#61666D')
            Button('重试')
              .fontSize(14)
              .onClick(() => {
                this.failed = false;
                this.loading = true;
                this.webController.refresh();
              })
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height(360)
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  aboutToDisappear(): void {
    if (this.startTimer >= 0) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
  }
}
