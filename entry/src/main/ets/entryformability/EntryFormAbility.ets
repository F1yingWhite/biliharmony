/**
 * 服务卡片「继续观看」的 FormExtensionAbility：
 * 卡片定时（updateDuration 30 分钟）或添加时由系统回调，读取 ContinueWatchingStore
 * 的最近观看记录刷新卡片数据。点击卡片跳应用由卡片内 postCardAction router 事件完成，
 * 无需这里处理。
 */
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { ContinueWatchingStore, ContinueWatchRecord } from '../common/ContinueWatchingStore';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';

const TAG: string = 'BiliHarmonyForm';

export default class EntryFormAbility extends FormExtensionAbility {
  private coverVersions: Map<string, number> = new Map<string, number>();
  private nextCoverVersion: number = 0;

  onAddForm(want: Want): formBindingData.FormBindingData {
    const data = this.buildCardData();
    const formId: string = String(want.parameters?.['ohos.extra.param.key.form_identity'] ?? '');
    if (formId.length > 0) this.updateCover(formId).catch(() => {});
    return data;
  }

  onUpdateForm(formId: string): void {
    // 定时刷新：把最新观看记录推给指定卡片实例。
    try {
      formProvider.updateForm(formId, this.buildCardData()).catch(() => {
      });
      this.updateCover(formId).catch(() => {});
    } catch (e) {
      // 卡片可能已被移除；异常无需上抛。
    }
  }

  onCastToNormal(formId: string): void {
    this.onUpdateForm(formId);
  }

  onRemoveForm(formId: string): void {
    this.coverVersions.delete(formId);
  }

  private async updateCover(formId: string): Promise<void> {
    const version: number = ++this.nextCoverVersion;
    this.coverVersions.set(formId, version);
    const record = ContinueWatchingStore.latest();
    if (record === null || record.cover.length === 0) return;
    RemoteAssetCache.attach(this.context);
    const uri: string = await RemoteAssetCache.ensureThumbnail(record.cover.replace(/^http:/, 'https:'));
    if (!uri.startsWith('file://') || this.coverVersions.get(formId) !== version) return;
    const latest = ContinueWatchingStore.latest();
    if (latest === null || latest.bvid !== record.bvid || latest.aid !== record.aid || latest.cover !== record.cover) return;
    const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      // 使用共享图片数据传给卡片宿主，不能把应用的网络 URL 当成卡片图片源。
      if (fs.statSync(file.fd).size > 2 * 1024 * 1024) return;
      const key: string = 'cover_' + Date.now() + '_' + version;
      await formProvider.updateForm(formId, this.buildCardData(key, file.fd));
    } finally {
      fs.closeSync(file);
    }
  }

  private buildCardData(imageKey: string = '', imageFd: number = -1): formBindingData.FormBindingData {
    ContinueWatchingStore.ensureSync(this.context);
    const record: ContinueWatchRecord | null = ContinueWatchingStore.latest();
    const empty: boolean = record === null ||
      ((record as ContinueWatchRecord).bvid.length === 0 && (record as ContinueWatchRecord).aid <= 0);
    const params: Record<string, Object> = {
      'title': empty ? 'BiliHaromny' : (record as ContinueWatchRecord).title,
      'cover': imageFd >= 0 ? 'memory://' + imageKey : '',
      'progressText': empty ? '去首页看看新内容吧' : (record as ContinueWatchRecord).progressText,
      'hasRecord': !empty,
      'bvid': empty ? '' : (record as ContinueWatchRecord).bvid,
      'aid': empty ? 0 : (record as ContinueWatchRecord).aid,
      'cachedAt': Date.now(),
    };
    if (imageFd >= 0) {
      const images: Record<string, number> = {};
      images[imageKey] = imageFd;
      params['formImages'] = images;
    }
    return formBindingData.createFormBindingData(params);
  }
}
