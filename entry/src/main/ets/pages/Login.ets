/**
 * 登录页：扫码（TV）/ 密码 / 短信验证码 三种方式
 * 密码与短信登录移植自 PiliPlus lib/pages/login/controller.dart
 */
import { promptAction } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';
import { AppNavStack } from '../common/AppRouter';
import { BiliApi, CookiePair, LoginResult, SmsSendResult } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';

// 登录表单输入框统一样式
@Extend(TextInput)
function loginInput(isDark: boolean) {
  .height(48)
  .fontSize(15)
  .fontColor(isDark ? '#FFFFFF' : '#18191C')
  .placeholderColor('#9499A0')
  .backgroundColor(isDark ? '#2F3136' : '#FFFFFF')
  .borderRadius(10)
  .padding({ left: 14, right: 14 })
}

@Component
export struct LoginPage {
  // ===== 扫码登录（原有逻辑，勿动） =====
  @State qrUrl: string = '';
  @State authCode: string = '';
  @State statusText: string = '加载二维码中...';
  @State statusColor: string = '#9499A0';
  @State expired: boolean = false;
  @State qrError: boolean = false;
  // ===== 登录方式切换：0 扫码 / 1 密码 / 2 短信 =====
  @State tab: number = 0;
  // ===== 密码登录 =====
  @State username: string = '';
  @State password: string = '';
  @State pwdLoading: boolean = false;
  // ===== 短信登录 =====
  @State tel: string = '';
  @State smsCode: string = '';
  @State captchaKey: string = '';
  @State smsSending: boolean = false;
  @State smsCountdown: number = 0;
  @State smsLoading: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private pollTimer: number = -1;
  private smsTimer: number = -1;
  private loggedIn: boolean = false;

  aboutToAppear(): void {
    this.requestCode();
  }

  aboutToDisappear(): void {
    this.stopPoll();
    this.stopSmsCountdown();
  }

  // ===== 扫码登录 =====
  async requestCode(): Promise<void> {
    this.stopPoll();
    this.expired = false;
    this.qrError = false;
    this.qrUrl = '';
    this.statusText = '获取登录二维码...';
    this.statusColor = '#9499A0';
    const result = await BiliApi.getTVCode();
    if (result === null) {
      this.qrError = true;
      this.statusText = '获取二维码失败，请检查网络后点击重试';
      this.statusColor = '#FB4A4A';
      return;
    }
    this.authCode = result.authCode;
    this.qrUrl = result.url;
    this.statusText = '请使用哔哩哔哩 App 扫码登录';
    this.statusColor = this.isDark ? '#D0D0D0' : '#61666D';
    this.startPoll();
  }

  startPoll(): void {
    this.pollTimer = setInterval(() => {
      this.poll();
    }, 3000);
  }

  stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  async poll(): Promise<void> {
    if (this.loggedIn || this.authCode.length === 0) {
      return;
    }
    const result = await BiliApi.pollTVCode(this.authCode);
    if (result.code === 0) {
      // 登录成功
      this.stopPoll();
      this.loggedIn = true;
      this.statusText = '登录成功！';
      this.statusColor = '#2FB96A';
      await UserStore.applyLoginCookies(result.cookies);
      promptAction.showToast({ message: '登录成功，欢迎回来' });
      setTimeout(() => {
        AppNavStack.pop();
      }, 600);
    } else if (result.code === 86039) {
      this.statusText = '二维码尚未扫描，请使用 App 扫码';
    } else if (result.code === 86090) {
      this.statusText = '已扫码，请在手机上确认登录';
      this.statusColor = '#2FB96A';
    } else if (result.code === 86038) {
      this.stopPoll();
      this.expired = true;
      this.statusText = '二维码已过期，点击刷新';
      this.statusColor = '#FB4A4A';
    } else {
      this.statusText = result.message.length > 0 ? result.message : '登录失败，请重试';
    }
  }

  // ===== 密码登录 =====
  async doPasswordLogin(): Promise<void> {
    if (this.pwdLoading) {
      return;
    }
    const name: string = this.username.trim();
    if (name.length === 0 || this.password.length === 0) {
      promptAction.showToast({ message: '请输入账号和密码' });
      return;
    }
    this.pwdLoading = true;
    const result: LoginResult = await BiliApi.loginByPassword(name, this.password);
    this.pwdLoading = false;
    if (result.code === 0 && result.cookies.length > 0) {
      await this.finishLogin(result.cookies);
      return;
    }
    if (result.code === 0 && result.dataStatus === 2) {
      // 风控：需手机号二次验证，v1 不做内嵌验证流程
      promptAction.showToast({ message: '本次登录环境存在风险，需手机验证，请改用扫码登录' });
    } else if (result.code === -105) {
      // 触发极验滑块验证码，v1 不支持内嵌验证
      promptAction.showToast({ message: '需要完成滑块验证，请改用扫码登录' });
    } else {
      promptAction.showToast({ message: result.message.length > 0 ? result.message : '登录失败，请检查账号密码' });
    }
  }

  // ===== 短信登录：发送验证码 =====
  async doSendSms(): Promise<void> {
    if (this.smsSending || this.smsCountdown > 0) {
      return;
    }
    const tel: string = this.tel.trim();
    if (tel.length === 0) {
      promptAction.showToast({ message: '请输入手机号' });
      return;
    }
    this.smsSending = true;
    const result: SmsSendResult = await BiliApi.sendSmsCode(tel);
    this.smsSending = false;
    if (result.code === 0 && result.captchaKey.length > 0) {
      this.captchaKey = result.captchaKey;
      promptAction.showToast({ message: '验证码已发送，请查收' });
      this.startSmsCountdown();
    } else if (result.needCaptcha) {
      // 触发极验滑块验证码，v1 不支持内嵌验证
      promptAction.showToast({ message: '需要先完成滑块验证，请改用扫码登录' });
    } else {
      promptAction.showToast({ message: result.message.length > 0 ? result.message : '发送失败，请稍后重试' });
    }
  }

  startSmsCountdown(): void {
    this.smsCountdown = 60;
    this.smsTimer = setInterval(() => {
      this.smsCountdown--;
      if (this.smsCountdown <= 0) {
        this.stopSmsCountdown();
      }
    }, 1000);
  }

  stopSmsCountdown(): void {
    if (this.smsTimer >= 0) {
      clearInterval(this.smsTimer);
      this.smsTimer = -1;
    }
    this.smsCountdown = 0;
  }

  // ===== 短信登录：提交验证码 =====
  async doSmsLogin(): Promise<void> {
    if (this.smsLoading) {
      return;
    }
    const tel: string = this.tel.trim();
    const code: string = this.smsCode.trim();
    if (tel.length === 0) {
      promptAction.showToast({ message: '请输入手机号' });
      return;
    }
    if (this.captchaKey.length === 0) {
      promptAction.showToast({ message: '请先点击获取验证码' });
      return;
    }
    if (code.length === 0) {
      promptAction.showToast({ message: '请输入短信验证码' });
      return;
    }
    this.smsLoading = true;
    const result: LoginResult = await BiliApi.loginBySms(tel, code, this.captchaKey);
    this.smsLoading = false;
    if (result.code === 0 && result.cookies.length > 0) {
      await this.finishLogin(result.cookies);
      return;
    }
    promptAction.showToast({ message: result.message.length > 0 ? result.message : '登录失败，请检查验证码' });
  }

  // ===== 登录成功统一收尾：写回 cookie 并返回 =====
  async finishLogin(cookies: Array<CookiePair>): Promise<void> {
    this.stopPoll();
    this.loggedIn = true;
    await UserStore.applyLoginCookies(cookies);
    promptAction.showToast({ message: '登录成功，欢迎回来' });
    setTimeout(() => {
      AppNavStack.pop();
    }, 600);
  }

  // ===== 登录方式切换 chip =====
  @Builder
  TabChip(index: number, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.tab === index ? '#FFFFFF' : (this.isDark ? '#D0D0D0' : '#61666D'))
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.tab === index ? this.accent : (this.isDark ? '#2F3136' : '#FFFFFF'))
      .onClick(() => {
        this.tab = index;
      })
  }

  // ===== 密码登录面板 =====
  @Builder
  PasswordPanel() {
    Column({ space: 14 }) {
      TextInput({ placeholder: '手机号 / 邮箱', text: this.username })
        .loginInput(this.isDark)
        .onChange((value: string) => {
          this.username = value;
        })
      TextInput({ placeholder: '密码', text: this.password })
        .type(InputType.Password)
        .loginInput(this.isDark)
        .onChange((value: string) => {
          this.password = value;
        })
      Button(this.pwdLoading ? '登录中...' : '登录')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .borderRadius(10)
        .enabled(!this.pwdLoading)
        .opacity(this.pwdLoading ? 0.7 : 1)
        .onClick(() => {
          this.doPasswordLogin();
        })
      Text('密码登录可能触发哔哩哔哩风控，若反复失败请使用扫码登录')
        .fontSize(12)
        .fontColor('#9499A0')
        .margin({ top: 4 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 32, right: 32, top: 40 })
  }

  // ===== 短信登录面板 =====
  @Builder
  SmsPanel() {
    Column({ space: 14 }) {
      TextInput({ placeholder: '手机号', text: this.tel })
        .type(InputType.PhoneNumber)
        .loginInput(this.isDark)
        .onChange((value: string) => {
          this.tel = value;
        })
      Row({ space: 10 }) {
        TextInput({ placeholder: '短信验证码', text: this.smsCode })
          .type(InputType.Number)
          .loginInput(this.isDark)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.smsCode = value;
          })
        Button(this.smsCountdown > 0 ? String(this.smsCountdown) + 's 后重发' : (this.smsSending ? '发送中' : '获取验证码'))
          .height(48)
          .fontSize(13)
          .fontColor(this.smsCountdown > 0 ? '#9499A0' : this.accent)
          .backgroundColor(this.isDark ? '#2F3136' : '#FFFFFF')
          .borderRadius(10)
          .padding({ left: 14, right: 14 })
          .enabled(this.smsCountdown <= 0 && !this.smsSending)
          .onClick(() => {
            this.doSendSms();
          })
      }
      .width('100%')

      Button(this.smsLoading ? '登录中...' : '登录')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .borderRadius(10)
        .enabled(!this.smsLoading)
        .opacity(this.smsLoading ? 0.7 : 1)
        .onClick(() => {
          this.doSmsLogin();
        })
      Text('短信登录可能触发哔哩哔哩风控，若反复失败请使用扫码登录')
        .fontSize(12)
        .fontColor('#9499A0')
        .margin({ top: 4 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 32, right: 32, top: 40 })
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Row() {
          Text('‹')
            .fontSize(26)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            .translate({ y: -1 })
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          AppNavStack.pop();
        })
        Blank()
        Text('登录')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
        Row()
          .width(32)
          .height(32)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: Immersive.statusBarHeight() + 6, bottom: 8 })

      // 登录方式切换
      Row({ space: 10 }) {
        this.TabChip(0, '扫码登录')
        this.TabChip(1, '密码登录')
        this.TabChip(2, '短信登录')
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 4, bottom: 4 })

      if (this.tab === 0) {
        // 二维码卡片（白底黑码，任何主题下都清晰可见）
        Column({ space: 16 }) {
          Stack({ alignContent: Alignment.Center }) {
            Column() {
              if (this.qrUrl.length > 0 && !this.expired) {
                QRCode(this.qrUrl)
                  .width(200)
                  .height(200)
                  .color('#000000')
                  .backgroundColor('#FFFFFF')
              } else {
                Column({ space: 10 }) {
                  Text(this.qrError ? '⚠' : '↻')
                    .fontSize(44)
                    .fontColor(this.qrError ? '#FB4A4A' : this.accent)
                  Text(this.qrError ? '点击重新获取' : (this.expired ? '二维码已过期' : '加载中...'))
                    .fontSize(13)
                    .fontColor('#9499A0')
                }
                .width(200)
                .height(200)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.requestCode();
                })
              }
            }
            .width(224)
            .height(224)
            .borderRadius(12)
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#EEEEEE' })
            .justifyContent(FlexAlign.Center)

            // 过期遮罩
            if (this.expired) {
              Column({ space: 10 }) {
                Text('二维码已失效')
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                Text('点击刷新')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor(this.accent)
              }
              .width(224)
              .height(224)
              .justifyContent(FlexAlign.Center)
              .backgroundColor('#AA000000')
              .borderRadius(12)
              .onClick(() => {
                this.requestCode();
              })
            }
          }

          Text(this.statusText)
            .fontSize(14)
            .fontColor(this.statusColor)

          Column({ space: 6 }) {
            Text('1. 打开哔哩哔哩 App')
              .fontSize(12)
              .fontColor('#9499A0')
            Text('2. 点击右上角扫一扫')
              .fontSize(12)
              .fontColor('#9499A0')
            Text('3. 确认登录')
              .fontSize(12)
              .fontColor('#9499A0')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 60 })
      } else if (this.tab === 1) {
        this.PasswordPanel()
      } else {
        this.SmsPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
