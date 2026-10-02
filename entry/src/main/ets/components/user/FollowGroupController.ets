import { UserApi } from '../../api/UserApi';
import { ActionResult } from '../../api/BiliApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { FollowTagItem } from '../../model/user/UserModels';
import { AuthSession } from '../../services/auth/AuthSession';

export class FollowGroupState {
  open: boolean = false;
  loading: boolean = false;
  busy: boolean = false;
  error: string = '';
  tags: Array<FollowTagItem> = [];
  checked: Array<number> = [];
  newName: string = '';
  renameId: number = 0;
  renameDraft: string = '';
}

/** 一次分组编辑会话；选择、草稿和提交锁只有一个所有者。 */
export class FollowGroupController {
  private state: FollowGroupState = new FollowGroupState();
  private requests: RequestEpoch = new RequestEpoch();
  private account: number = -1;
  private mid: number = 0;
  private session: number = 0;
  private readonly publishState: (state: FollowGroupState) => void;
  private readonly toast: (message: string) => void;

  constructor(publish: (state: FollowGroupState) => void, toast: (message: string) => void) {
    this.publishState = publish;
    this.toast = toast;
  }

  async open(mid: number): Promise<void> {
    if (mid <= 0) return;
    this.session++;
    const request: number = this.requests.next();
    this.account = AuthSession.version;
    this.mid = mid;
    this.state = new FollowGroupState();
    this.state.open = true;
    this.state.loading = true;
    this.publish();
    try {
      const tags: Array<FollowTagItem> = await UserApi.getFollowTags();
      if (this.isCurrent(request)) this.state.tags = tags;
    } catch (e) {
      if (this.isCurrent(request)) this.state.error = (e as Error).message || '分组列表加载失败，请稍后重试';
    } finally {
      if (this.isCurrent(request)) {
        this.state.loading = false;
        this.publish();
      }
    }
  }

  close(): void {
    this.dispose();
    this.publish();
  }

  async retryLoad(): Promise<void> {
    if (!this.state.open || this.state.loading || this.state.busy || this.account !== AuthSession.version) return;
    await this.open(this.mid);
  }

  dispose(): void {
    this.session++;
    this.requests.invalidate();
    this.state = new FollowGroupState();
  }

  get sessionVersion(): number {
    return this.session;
  }

  isSessionCurrent(session: number): boolean {
    return this.state.open && this.account === AuthSession.version && this.session === session;
  }

  setNewName(value: string): void {
    if (!this.canEdit()) return;
    this.state.newName = value;
    this.publish();
  }

  setRenameDraft(value: string): void {
    if (!this.canEdit()) return;
    this.state.renameDraft = value;
    this.publish();
  }

  beginRename(tag: FollowTagItem): void {
    if (!this.canEdit()) return;
    const current: FollowTagItem | undefined = this.state.tags.find((item: FollowTagItem) => item.tagid === tag.tagid);
    if (current === undefined) return;
    this.state.renameId = current.tagid;
    this.state.renameDraft = current.name;
    this.publish();
  }

  cancelRename(): void {
    if (!this.canEdit()) return;
    this.state.renameId = 0;
    this.state.renameDraft = '';
    this.publish();
  }

  toggle(tagId: number): void {
    if (!this.canEdit() || !this.state.tags.some((tag: FollowTagItem) => tag.tagid === tagId)) return;
    this.state.checked = this.state.checked.indexOf(tagId) >= 0 ?
      this.state.checked.filter((id: number) => id !== tagId) : this.state.checked.concat([tagId]);
    this.publish();
  }

  async create(): Promise<void> {
    if (!this.canEdit()) return;
    const name: string = this.state.newName.trim();
    if (!this.validName(name)) return;
    const request: number = this.begin();
    try {
      const tagId: number = await UserApi.createFollowTag(name);
      if (!this.isCurrent(request)) return;
      if (tagId <= 0) {
        this.toast('创建分组失败，请检查登录状态后重试');
        return;
      }
      const tag: FollowTagItem = new FollowTagItem();
      tag.tagid = tagId;
      tag.name = name;
      this.state.tags = this.state.tags.concat([tag]);
      this.state.checked = this.state.checked.concat([tagId]);
      this.state.newName = '';
    } catch (e) {
      if (this.isCurrent(request)) this.toast('创建分组失败，请检查网络');
    } finally {
      this.finish(request);
    }
  }

  async rename(): Promise<void> {
    if (!this.canEdit() || this.state.renameId <= 0) return;
    const name: string = this.state.renameDraft.trim();
    if (!this.validName(name)) return;
    const tagId: number = this.state.renameId;
    const request: number = this.begin();
    try {
      const result: ActionResult = await UserApi.renameFollowTag(tagId, name);
      if (!this.isCurrent(request)) return;
      this.toast(result.message);
      if (!result.ok) return;
      this.state.tags = this.state.tags.map((tag: FollowTagItem): FollowTagItem => {
        const updated: FollowTagItem = this.copyTag(tag);
        if (updated.tagid === tagId) updated.name = name;
        return updated;
      });
      this.state.renameId = 0;
      this.state.renameDraft = '';
    } catch (e) {
      if (this.isCurrent(request)) this.toast('重命名失败，请检查网络');
    } finally {
      this.finish(request);
    }
  }

  async remove(tagId: number): Promise<void> {
    if (!this.canEdit() || !this.state.tags.some((tag: FollowTagItem) => tag.tagid === tagId)) return;
    const request: number = this.begin();
    try {
      const result: ActionResult = await UserApi.deleteFollowTag(tagId);
      if (!this.isCurrent(request)) return;
      this.toast(result.message);
      if (!result.ok) return;
      this.state.tags = this.state.tags.filter((tag: FollowTagItem) => tag.tagid !== tagId);
      this.state.checked = this.state.checked.filter((id: number) => id !== tagId);
      if (this.state.renameId === tagId) {
        this.state.renameId = 0;
        this.state.renameDraft = '';
      }
    } catch (e) {
      if (this.isCurrent(request)) this.toast('删除分组失败，请检查网络');
    } finally {
      this.finish(request);
    }
  }

  async save(): Promise<void> {
    if (!this.canEdit()) return;
    const checked: Array<number> = this.state.checked.slice();
    const mid: number = this.mid;
    const request: number = this.begin();
    try {
      const result: ActionResult = await UserApi.addToFollowTags(mid, checked);
      if (!this.isCurrent(request)) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.toast('分组已保存');
      this.close();
    } catch (e) {
      if (this.isCurrent(request)) this.toast('保存分组失败，请检查网络');
    } finally {
      this.finish(request);
    }
  }

  private canEdit(): boolean {
    return this.state.open && !this.state.loading && !this.state.busy && this.state.error.length === 0 &&
      this.account === AuthSession.version;
  }

  private validName(name: string): boolean {
    if (name.length === 0) this.toast('请输入分组名称');
    else if (name.length > 15) this.toast('分组名称最多 15 个字');
    return name.length > 0 && name.length <= 15;
  }

  private begin(): number {
    const request: number = this.requests.next();
    this.state.busy = true;
    this.publish();
    return request;
  }

  private isCurrent(request: number): boolean {
    return this.state.open && this.account === AuthSession.version && this.requests.isCurrent(request);
  }

  private finish(request: number): void {
    if (!this.isCurrent(request)) return;
    this.state.busy = false;
    this.publish();
  }

  private copyTag(tag: FollowTagItem): FollowTagItem {
    const copy: FollowTagItem = new FollowTagItem();
    copy.tagid = tag.tagid;
    copy.name = tag.name;
    copy.count = tag.count;
    return copy;
  }

  private publish(): void {
    const state: FollowGroupState = new FollowGroupState();
    state.open = this.state.open;
    state.loading = this.state.loading;
    state.busy = this.state.busy;
    state.error = this.state.error;
    state.tags = this.state.tags.map((tag: FollowTagItem) => this.copyTag(tag));
    state.checked = this.state.checked.slice();
    state.newName = this.state.newName;
    state.renameId = this.state.renameId;
    state.renameDraft = this.state.renameDraft;
    this.publishState(state);
  }
}
