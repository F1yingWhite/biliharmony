/**
 * 私信与消息通知 API。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asNumber, asBool, str, toHttps, randomString } from '../common/Utils';
import { MessageSessionItem, MessageSessionPageData, PrivateMessageItem, PrivateMessagePageData,
  MsgFeedUnread, MsgNotifyItem, MsgNotifyPageData } from '../model/Models';
import { ActionResult, actionWithCsrf, getData } from './internal/ApiCommon';

export class MessageApi {
  static async getMessageSessions(beginTs: number = 0): Promise<MessageSessionPageData> {
    const params: Record<string, string> = {
      // 1 才是私聊主页；4 是“未关注用户”折叠会话，会导致普通私信列表为空。
      'session_type': '1', 'group_fold': '1', 'unfollow_fold': '0', 'sort_rule': '2',
      'size': '30', 'build': '0', 'mobi_app': 'web',
    };
    if (beginTs > 0) params['begin_ts'] = String(beginTs);
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await HttpClient.get(Api.sessionList + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    const result: MessageSessionPageData = new MessageSessionPageData();
    if (data === null) {
      // 失败原因透出到 UI（区分网络错误与业务错误），同时留 hilog 便于定位风控/签名问题。
      const json: Record<string, Object> = resp.json();
      result.error = resp.ok ? str(json, 'message', '接口异常') : '网络请求失败 (' + String(resp.status) + ')';
      hilog.warn(0x0000, 'BiliApi', 'getMessageSessions failed: status=%{public}d code=%{public}d body=%{public}s',
        resp.status, asNumber(json['code'], -999), resp.body.substring(0, 200));
      return result;
    }
    hilog.info(0x0000, 'BiliApi', 'getMessageSessions ok: sessions=%{public}d', asArray(data['session_list']).length);
    const list: Array<Object> = asArray(data['session_list']);
    const accountIds: Array<string> = [];
    for (let i: number = 0; i < list.length; i++) {
      const session: MessageSessionItem = MessageSessionItem.from(list[i]);
      result.sessions.push(session);
      if (session.name.length === 0 && session.talkerId > 0) accountIds.push(String(session.talkerId));
    }
    if (accountIds.length > 0) await MessageApi.fillSessionAccounts(result.sessions, accountIds);
    result.hasMore = asNumber(data['has_more'], 0) === 1 || asBool(data['has_more']);
    return result;
  }

  private static async fillSessionAccounts(sessions: Array<MessageSessionItem>, ids: Array<string>): Promise<void> {
    const params: Record<string, string> = { 'uids': ids.join(','), 'build': '0', 'mobi_app': 'web' };
    const resp: HttpResponse = await HttpClient.get(Api.sessionAccountList + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    if (!resp.ok) return;
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) return;
    const raw: Object | undefined = json['data'];
    const cards: Array<Object> = Array.isArray(raw) ? asArray(raw) : asArray(asObject(raw)['cards']);
    for (let i: number = 0; i < cards.length; i++) {
      const card: Record<string, Object> = asObject(cards[i]);
      const mid: number = asNumber(card['mid'], asNumber(card['uid'], 0));
      for (let j: number = 0; j < sessions.length; j++) {
        if (sessions[j].talkerId === mid) {
          sessions[j].name = str(card, 'name', str(card, 'uname', '用户' + String(mid)));
          sessions[j].avatar = toHttps(str(card, 'face', str(card, 'pic', '')));
        }
      }
    }
  }

  /** 私信（api.vc.bilibili.com/x/bplus/im/report/add；biz_code=4 私信场景）。 */
  static async reportImMessage(accusedUid: number, reasonType: number, reasonDesc: string): Promise<ActionResult> {
    if (accusedUid <= 0) return new ActionResult(false, '用户信息无效');
    return actionWithCsrf('登录状态缺少 CSRF', '已提交举报，感谢反馈', '举报失败',
      async (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'biz_code': '4',
          'accused_uid': String(accusedUid),
          'object_id': String(accusedUid),
          'reason_type': String(reasonType),
          'reason_desc': reasonDesc,
          'module': '604',
          'comment': '{}',
          'extra': '{}',
          'csrf': csrf,
        };
        return HttpClient.post(Api.sessionReportIm + '?' + HttpClient.buildQuery(params),
          HttpClient.buildQuery({}),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  /** 删除私信会话（api.vc.bilibili.com 域，需 WBI 签名 + csrf）。 */
  static async removeSession(talkerId: number): Promise<ActionResult> {
    if (talkerId <= 0) return new ActionResult(false, '会话参数无效');
    if (HttpClient.getCookie('SESSDATA').length === 0) {
      return new ActionResult(false, '登录状态已失效，请重新登录', -101);
    }
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new ActionResult(false, '登录状态缺少 CSRF，请重新登录', -111);
    const params: Record<string, string> = {
      'talker_id': String(talkerId),
      'session_type': '1',
      'build': '0',
      'mobi_app': 'web',
      'csrf_token': csrf,
      'csrf': csrf,
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await HttpClient.post(Api.sessionRemove + '?' + HttpClient.buildQuery(params),
      HttpClient.buildQuery({}),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
    const json: Record<string, Object> = resp.json();
    const code: number = Number(json['code'] ?? -1);
    const ok: boolean = code === 0;
    return new ActionResult(ok, ok ? '会话已删除' : (String(json['message'] ?? '删除失败') + ' (' + String(code) + ')'), code);
  }

  static async getPrivateMessages(talkerId: number, beginSeqno: number = 0): Promise<PrivateMessagePageData> {
    const params: Record<string, string> = {
      'talker_id': String(talkerId), 'session_type': '1', 'size': '30', 'sender_device_id': '1',
      'build': '0', 'mobi_app': 'web', 'web_location': '333.1296',
    };
    if (beginSeqno > 0) params['begin_seqno'] = String(beginSeqno);
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await HttpClient.get(Api.sessionMessages + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    const result: PrivateMessagePageData = new PrivateMessagePageData();
    if (data === null) {
      const json: Record<string, Object> = resp.json();
      const code: number = asNumber(json['code'], -999);
      const serverMessage: string = str(json, 'message', str(json, 'msg', ''));
      result.error = resp.ok ?
        (serverMessage.length > 0 && serverMessage !== '0' ? serverMessage : '私信接口异常 (' + String(code) + ')') :
        '网络请求失败 (' + String(resp.status) + ')';
      hilog.warn(0x0000, 'BiliApi', 'getPrivateMessages failed: talker=%{public}d status=%{public}d code=%{public}d body=%{public}s',
        talkerId, resp.status, code, resp.body.substring(0, 200));
      return result;
    }
    const list: Array<Object> = asArray(data['messages']);
    for (let i: number = 0; i < list.length; i++) result.messages.push(PrivateMessageItem.from(list[i]));
    result.messages.sort((a: PrivateMessageItem, b: PrivateMessageItem) => a.seqno - b.seqno);
    if (result.messages.length > 0) result.minSeqno = result.messages[0].seqno;
    result.hasMore = asNumber(data['has_more'], 0) === 1 || list.length >= 30;
    return result;
  }

  /** 将指定会话确认到最后一条已展示消息，对齐 PiliPlus 的 update_ack 行为。 */
  static async markPrivateMessagesRead(talkerId: number, ackSeqno: number): Promise<ActionResult> {
    if (talkerId <= 0 || ackSeqno <= 0) return new ActionResult(false, '无可确认的私信');
    return actionWithCsrf('登录状态缺少 CSRF', '已读', '标记已读失败',
      async (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'talker_id': String(talkerId), 'session_type': '1', 'ack_seqno': String(ackSeqno),
          'build': '0', 'mobi_app': 'web', 'csrf_token': csrf, 'csrf': csrf,
        };
        await WbiSign.encWbi(params);
        return HttpClient.get(Api.ackSessionMessage + '?' + HttpClient.buildQuery(params),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  static async sendPrivateMessage(senderId: number, receiverId: number, content: string): Promise<ActionResult> {
    const devId: string = randomString(8) + '-' + randomString(4) + '-4' + randomString(3) + '-a' + randomString(3) + '-' + randomString(12);
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '发送成功', '发送失败',
      async (csrf: string): Promise<HttpResponse> => {
        const query: Record<string, string> = {
          'w_sender_uid': String(senderId), 'w_receiver_id': String(receiverId), 'w_dev_id': devId,
        };
        await WbiSign.encWbi(query);
        const body: Record<string, string> = {
          'msg[sender_uid]': String(senderId), 'msg[receiver_id]': String(receiverId), 'msg[receiver_type]': '1',
          'msg[msg_type]': '1', 'msg[msg_status]': '0', 'msg[dev_id]': devId,
          'msg[timestamp]': String(Math.floor(Date.now() / 1000)), 'msg[new_face_version]': '1',
          'msg[content]': JSON.stringify({ 'content': content }), 'csrf_token': csrf, 'csrf': csrf,
          'build': '0', 'mobi_app': 'web',
        };
        return HttpClient.post(Api.sendMessage + '?' + HttpClient.buildQuery(query),
          HttpClient.buildQuery(body), HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  // ===== 消息通知（回复我的 / @我 / 收到的赞 / 系统通知） =====
  /** 消息中心各分类未读数，供首页消息入口角标使用。 */
  static async getMsgFeedUnread(): Promise<MsgFeedUnread> {
    const result: MsgFeedUnread = new MsgFeedUnread();
    const resp: HttpResponse = await HttpClient.get(Api.msgFeedUnread + '?platform=web&build=0&mobi_app=web',
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return result;
    result.reply = asNumber(data['reply'], 0);
    result.at = asNumber(data['at'], 0);
    result.like = asNumber(data['like'], 0);
    result.sysMsg = asNumber(data['sys_msg'], 0);
    return result;
  }

  /** 通知流通用入口：kind = reply | at | like，cursor 分页（id + 时间戳）。 */
  static async getMsgFeedNotify(kind: string, cursorId: string = '', cursorTime: string = ''): Promise<MsgNotifyPageData> {
    const url: string = kind === 'at' ? Api.msgFeedAt : (kind === 'like' ? Api.msgFeedLike : Api.msgFeedReply);
    const timeKey: string = kind === 'at' ? 'at_time' : (kind === 'like' ? 'like_time' : 'reply_time');
    const params: Record<string, string> = {
      'platform': 'web', 'mobi_app': 'web', 'build': '0', 'web_location': '333.40164',
    };
    if (cursorId.length > 0) params['id'] = cursorId;
    if (cursorTime.length > 0) params[timeKey] = cursorTime;
    const resp: HttpResponse = await HttpClient.get(url + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const result: MsgNotifyPageData = new MsgNotifyPageData();
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      const json: Record<string, Object> = resp.json();
      result.error = resp.ok ? str(json, 'message', '接口异常') : '网络请求失败 (' + String(resp.status) + ')';
      hilog.warn(0x0000, 'BiliApi', 'getMsgFeedNotify failed: kind=%{public}s status=%{public}d code=%{public}d',
        kind, resp.status, asNumber(json['code'], -999));
      return result;
    }
    // 「收到的赞」首屏同时返回 latest（最新）与 total（累计），合并后按 id 去重展示。
    let rawItems: Array<Object>;
    let cursorObj: Record<string, Object>;
    if (kind === 'like') {
      const total: Record<string, Object> = asObject(data['total']);
      cursorObj = asObject(total['cursor']);
      rawItems = asArray(asObject(data['latest'])['items']).concat(asArray(total['items']));
    } else {
      cursorObj = asObject(data['cursor']);
      rawItems = asArray(data['items']);
    }
    const seen: Set<number> = new Set<number>();
    for (let i: number = 0; i < rawItems.length; i++) {
      const item: MsgNotifyItem = kind === 'at' ? MsgNotifyItem.fromAt(rawItems[i]) :
        (kind === 'like' ? MsgNotifyItem.fromLike(rawItems[i]) : MsgNotifyItem.fromReply(rawItems[i]));
      if (item.id > 0 && seen.has(item.id)) continue;
      seen.add(item.id);
      result.items.push(item);
    }
    result.hasMore = !asBool(cursorObj['is_end'], true) && rawItems.length > 0;
    MessageApi.fillMsgFeedCursor(resp.body, result);
    return result;
  }

  /** cursor.id/time 为 int64，从原始报文按字符串截取，避免 JSON.parse 丢失精度。 */
  private static fillMsgFeedCursor(body: string, result: MsgNotifyPageData): void {
    const idx: number = body.indexOf('"cursor"');
    if (idx < 0) return;
    const block: string = body.substring(idx, idx + 160);
    const idMatch: RegExpMatchArray | null = block.match(/"id":(\d+)/);
    const timeMatch: RegExpMatchArray | null = block.match(/"time":(\d+)/);
    result.cursorId = idMatch !== null ? idMatch[1] : '';
    result.cursorTime = timeMatch !== null ? timeMatch[1] : '';
  }

  /** 系统通知：data 为数组，cursor 为纳秒级 int64（超出 number 精度，按字符串截取）。 */
  static async getSysNotifications(cursor: string = ''): Promise<MsgNotifyPageData> {
    const params: Record<string, string> = {
      'page_size': '20', 'mobi_app': 'web', 'build': '0', 'web_location': '333.40164',
    };
    if (cursor.length > 0) params['cursor'] = cursor;
    const resp: HttpResponse = await HttpClient.get(Api.msgSysNotify + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const result: MsgNotifyPageData = new MsgNotifyPageData();
    const json: Record<string, Object> = resp.json();
    if (!resp.ok || asNumber(json['code'], -1) !== 0) {
      result.error = resp.ok ? str(json, 'message', '接口异常') : '网络请求失败 (' + String(resp.status) + ')';
      hilog.warn(0x0000, 'BiliApi', 'getSysNotifications failed: status=%{public}d code=%{public}d',
        resp.status, asNumber(json['code'], -999));
      return result;
    }
    const list: Array<Object> = asArray(json['data']);
    // 每条 item 的 cursor 按报文出现顺序一一对应（JSON.parse 会把纳秒游标截成浮点）。
    const cursors: Array<string> = [];
    const re: RegExp = new RegExp('"cursor":(\\d+)', 'g');
    let match: RegExpExecArray | null = re.exec(resp.body);
    while (match !== null) {
      cursors.push(match[1]);
      match = re.exec(resp.body);
    }
    for (let i: number = 0; i < list.length; i++) {
      result.items.push(MsgNotifyItem.fromSys(list[i], i < cursors.length ? cursors[i] : ''));
    }
    if (result.items.length > 0) {
      result.sysCursor = result.items[result.items.length - 1].sysCursor;
    }
    result.hasMore = list.length >= 20;
    return result;
  }

  /** 系统通知已读游标上报，对齐 PiliPlus msgSysUpdateCursor。 */
  static async updateSysMsgCursor(cursor: string): Promise<ActionResult> {
    if (cursor.length === 0) return new ActionResult(false, '游标为空');
    return actionWithCsrf('登录状态缺少 CSRF', '已读', '标记已读失败',
      async (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'csrf': csrf, 'cursor': cursor, 'has_up': '0', 'build': '0', 'mobi_app': 'web',
        };
        return HttpClient.get(Api.msgSysUpdateCursor + '?' + HttpClient.buildQuery(params),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  /** 删除单条通知（回复/@/赞）：tp 0=赞 1=回复 2=@，id 为通知 id。删除成功需调用方本地移除该行。 */
  static async delNotify(kind: string, id: number): Promise<ActionResult> {
    if (id <= 0) return new ActionResult(false, '通知参数无效');
    const tp: number = kind === 'at' ? 2 : (kind === 'reply' ? 1 : 0);
    return actionWithCsrf('登录状态缺少 CSRF', '已删除', '删除失败',
      async (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'tp': String(tp), 'id': String(id), 'build': '0', 'mobi_app': 'web', 'csrf': csrf,
        };
        return HttpClient.post(Api.xMsgNotifyDel + '?' + HttpClient.buildQuery(params),
          HttpClient.buildQuery({}),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  /** 删除系统通知：ids 为通知 id 数组（type=4，对齐 PiliPlus delSysMsg）。 */
  static async delSysNotify(ids: Array<number>): Promise<ActionResult> {
    if (ids.length === 0) return new ActionResult(false, '通知参数无效');
    return actionWithCsrf('登录状态缺少 CSRF', '已删除', '删除失败',
      async (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'ids': ids.map((id: number) => String(id)).join(','),
          'station_ids': '', 'type': '4', 'mobi_app': 'web', 'csrf': csrf,
        };
        return HttpClient.post(Api.xSysNotifyDel + '?' + HttpClient.buildQuery(params),
          HttpClient.buildQuery({}),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }
}
