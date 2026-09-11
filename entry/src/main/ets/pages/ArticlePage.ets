import { LoadingView } from '../components/LoadingView';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { ArticlePageParam } from '../common/AppRouter';
import { ArticleApi, ArticleDocument } from '../api/ArticleApi';
import { articleHtml } from '../common/ArticleHtml';
import { RequestEpoch } from '../common/RequestEpoch';
import { HttpClient } from '../services/network/HttpClient';

@Component
export struct ArticlePage {
  param: ArticlePageParam = { id: 0, title: '' };
  private controller: webview.WebviewController = new webview.WebviewController();
  private request: RequestEpoch = new RequestEpoch();
  private htmlLoaded: boolean = false;
  private article: ArticleDocument = new ArticleDocument();
  @State loading: boolean = true;
  @State errorText: string = '';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToAppear(): void { this.loadArticle(); }
  aboutToDisappear(): void { this.request.invalidate(); }

  private async loadArticle(): Promise<void> {
    const token: number = this.request.next();
    this.loading = true;
    this.errorText = '';
    this.htmlLoaded = false;
    try {
      const article: ArticleDocument = await ArticleApi.getArticle(this.param.id);
      if (!this.request.isCurrent(token)) return;
      this.article = article;
    } catch (e) {
      if (this.request.isCurrent(token)) this.errorText = (e as Error).message || '文章加载失败，请稍后重试';
    } finally {
      if (this.request.isCurrent(token)) this.loading = false;
    }
  }

  private async openArticleLink(url: string): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink(url);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '网页打开失败，请稍后重试' });
    }
  }

  private interceptNavigation(url: string, mainFrame: boolean, gesture: boolean): boolean {
    if (!mainFrame) return false;
    const lower: string = url.toLowerCase();
    const articleUrl: string = 'https://www.bilibili.com/read/cv' + String(this.param.id);
    if (url.startsWith(articleUrl + '#') || url.startsWith(articleUrl + '/#')) return false;
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      if (gesture) {
        this.openArticleLink(url);
        return true;
      }
      return false;
    }
    return !lower.startsWith('data:text/html') && lower !== 'about:blank';
  }

  private async loadImage(url: string, response: WebResourceResponse): Promise<void> {
    try {
      const headers: Record<string, string> = { 'Cookie': '', 'Referer': 'https://www.bilibili.com/' };
      const bytes: ArrayBuffer | null = await HttpClient.getBinary(url, headers);
      if (bytes !== null && bytes.byteLength > 0) {
        response.setResponseData(bytes);
        response.setResponseCode(200);
        response.setReasonMessage('OK');
      } else {
        response.setResponseCode(502);
        response.setReasonMessage('Image unavailable');
      }
    } catch (e) {
      response.setResponseCode(502);
      response.setReasonMessage('Image unavailable');
    } finally {
      response.setResponseIsReady(true);
    }
  }

  build() {
    Column() {
      PageHeader({ title: this.param.title.length > 0 ? this.param.title : '专栏' })
      if (this.loading || this.errorText.length > 0) {
        LoadingView({ loading: this.loading, skeleton: 'detail', errorText: this.errorText,
          onRetry: () => { this.loadArticle(); } })
      } else {
        Web({ src: 'about:blank', controller: this.controller })
          .onControllerAttached(() => {
            this.controller.loadData(articleHtml(this.article, this.isDark), 'text/html', 'UTF-8',
              'https://www.bilibili.com/read/cv' + String(this.param.id));
          })
          .onPageEnd((event) => {
            if (this.htmlLoaded || event.url !== 'about:blank') return;
            this.htmlLoaded = true;
            this.controller.loadData(articleHtml(this.article, this.isDark), 'text/html', 'UTF-8',
              'https://www.bilibili.com/read/cv' + String(this.param.id));
          })
          .onInterceptRequest((event) => {
            const url: string = event.request.getRequestUrl();
            if (!/^https:[/][/][a-z0-9.-]+[.]hdslb[.]com[/]/i.test(url)) return null;
            const response: WebResourceResponse = new WebResourceResponse();
            response.setResponseIsReady(false);
            response.setResponseMimeType(/[.]gif(?:[?]|$)/i.test(url) ? 'image/gif' :
              (/[.]png(?:[?]|$)/i.test(url) ? 'image/png' : (/[.]webp(?:[?]|$)/i.test(url) ? 'image/webp' : 'image/jpeg')));
            this.loadImage(url, response);
            return response;
          })
          .javaScriptAccess(false)
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
          .onLoadIntercept((event) => {
            return this.interceptNavigation(event.data.getRequestUrl(), event.data.isMainFrame(),
              event.data.isRequestGesture());
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
