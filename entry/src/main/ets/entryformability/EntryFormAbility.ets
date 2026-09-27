/**
 * 服务卡片「继续观看」的 FormExtensionAbility：
 * 卡片定时（updateDuration 30 分钟）或添加时由系统回调，读取 ContinueWatchingStore
 * 的最近观看记录刷新卡片数据。点击卡片跳应用由卡片内 postCardAction router 事件完成，
 * 无需这里处理。
 */
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { ContinueWatchingStore, ContinueWatchRecord } from '../common/ContinueWatchingStore';

const TAG: string = 'BiliHarmonyForm';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    return this.buildCardData();
  }

  onUpdateForm(formId: string): void {
    // 定时刷新：把最新观看记录推给指定卡片实例。
    try {
      formProvider.updateForm(formId, this.buildCardData()).catch(() => {
      });
    } catch (e) {
      // 卡片可能已被移除；异常无需上抛。
    }
  }

  onCastToNormal(formId: string): void {
    try {
      formProvider.updateForm(formId, this.buildCardData()).catch(() => {
      });
    } catch (e) {
      // 卡片可能已被移除。
    }
  }

  private buildCardData(): formBindingData.FormBindingData {
    ContinueWatchingStore.ensureSync(this.context);
    const record: ContinueWatchRecord | null = ContinueWatchingStore.latest();
    const empty: boolean = record === null ||
      ((record as ContinueWatchRecord).bvid.length === 0 && (record as ContinueWatchRecord).aid <= 0);
    const params: Record<string, Object> = {
      'title': empty ? 'BiliHaromny' : (record as ContinueWatchRecord).title,
      'cover': empty ? '' : (record as ContinueWatchRecord).cover,
      'progressText': empty ? '去首页看看新内容吧' : (record as ContinueWatchRecord).progressText,
      'hasRecord': !empty,
      'bvid': empty ? '' : (record as ContinueWatchRecord).bvid,
      'aid': empty ? 0 : (record as ContinueWatchRecord).aid,
      'cachedAt': Date.now(),
    };
    return formBindingData.createFormBindingData(params);
  }
}
