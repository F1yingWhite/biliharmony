import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { SponsorBlockSegment, SponsorBlockStore } from '../common/SponsorBlock';
import { asArray, asNumber, asObject, str } from '../common/Utils';

const SERVER: string = 'https://www.bsbsb.top';

export class SponsorBlockResult {
  ok: boolean = false;
  status: number = -1;
  message: string = '';
  uuids: Array<string> = [];
}

export class SponsorBlockUserInfo {
  userName: string = '';
  publicUserID: string = '';
  minutesSaved: number = 0;
  segmentCount: number = 0;
  viewCount: number = 0;
  reputation: number = 0;
  vip: boolean = false;
  warnings: number = 0;
  warningReason: string = '';
}

function toHex(data: Uint8Array): string {
  const chars: string = '0123456789abcdef';
  let out: string = '';
  for (let i: number = 0; i < data.length; i++) {
    out += chars.charAt((data[i] >> 4) & 0x0f) + chars.charAt(data[i] & 0x0f);
  }
  return out;
}

async function sha256Hex(input: string): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const encoder: util.TextEncoder = new util.TextEncoder();
  await md.update({ data: encoder.encodeInto(input) });
  return toHex((await md.digest()).data);
}

function headers(skipCache: boolean = false): Record<string, string> {
  const result: Record<string, string> = {
    'Origin': 'harmony://com.piliplus.harmony',
    'x-ext-version': 'BiliHarmony/1.0',
    'Accept': 'application/json',
  };
  if (skipCache) result['X-SKIP-CACHE'] = '1';
  return result;
}

function parseSegment(source: Object): SponsorBlockSegment | null {
  const item: Record<string, Object> = asObject(source);
  const times: Array<Object> = asArray(item['segment']);
  if (times.length === 0) return null;
  const start: number = asNumber(times[0], -1);
  const end: number = times.length > 1 ? asNumber(times[1], start) : start;
  if (start < 0 || end < start) return null;
  const parsed: SponsorBlockSegment = new SponsorBlockSegment();
  parsed.start = start;
  parsed.end = end;
  parsed.cid = str(item, 'cid', '');
  parsed.category = str(item, 'category', '');
  parsed.actionType = str(item, 'actionType', 'skip');
  parsed.uuid = str(item, 'UUID', '');
  parsed.locked = asNumber(item['locked'], 0) === 1;
  parsed.votes = asNumber(item['votes'], 0);
  parsed.description = str(item, 'description', '');
  parsed.videoDuration = asNumber(item['videoDuration'], 0);
  return parsed.category.length > 0 ? parsed : null;
}

export class SponsorBlockApi {
  private static segmentCache: Map<string, Array<SponsorBlockSegment>> = new Map<string, Array<SponsorBlockSegment>>();
  private static segmentCacheAt: Map<string, number> = new Map<string, number>();

  static async getSegments(bvid: string, cid: number,
    ignoreCache: boolean = false): Promise<Array<SponsorBlockSegment>> {
    if (bvid.length === 0) return [];
    const cacheKey: string = bvid + ':' + String(cid);
    const cached: Array<SponsorBlockSegment> | undefined = SponsorBlockApi.segmentCache.get(cacheKey);
    const cachedAt: number = SponsorBlockApi.segmentCacheAt.get(cacheKey) ?? 0;
    if (!ignoreCache && cached !== undefined && Date.now() - cachedAt < 10 * 60 * 1000) return cached;
    const digest: string = await sha256Hex(bvid);
    const response: HttpResponse = await HttpClient.get(SERVER + '/api/skipSegments/' + digest.substring(0, 4),
      headers(ignoreCache));
    if (response.ok) {
      const blocks: Array<Object> = response.jsonArray();
      for (let i: number = 0; i < blocks.length; i++) {
        const block: Record<string, Object> = asObject(blocks[i]);
        if (str(block, 'videoID', '') !== bvid) continue;
        const raw: Array<Object> = asArray(block['segments']);
        const result: Array<SponsorBlockSegment> = [];
        for (let j: number = 0; j < raw.length; j++) {
          const segment: SponsorBlockSegment | null = parseSegment(raw[j]);
          if (segment === null) continue;
          if (segment.cid.length > 0 && cid > 0 && segment.cid !== String(cid)) continue;
          result.push(segment);
        }
        result.sort((a: SponsorBlockSegment, b: SponsorBlockSegment) => a.start - b.start);
        SponsorBlockApi.segmentCache.set(cacheKey, result);
        SponsorBlockApi.segmentCacheAt.set(cacheKey, Date.now());
        return result;
      }
      return [];
    }

    // 兼容旧服务端和自建实例的直查协议。
    const fallback: HttpResponse = await HttpClient.get(SERVER + '/api/skipSegments?' +
      HttpClient.buildQuery({ 'videoID': bvid, 'cid': String(cid) }), headers(ignoreCache));
    if (!fallback.ok) return [];
    const raw: Array<Object> = fallback.jsonArray();
    const result: Array<SponsorBlockSegment> = [];
    for (let i: number = 0; i < raw.length; i++) {
      const segment: SponsorBlockSegment | null = parseSegment(raw[i]);
      if (segment !== null) result.push(segment);
    }
    result.sort((a: SponsorBlockSegment, b: SponsorBlockSegment) => a.start - b.start);
    SponsorBlockApi.segmentCache.set(cacheKey, result);
    SponsorBlockApi.segmentCacheAt.set(cacheKey, Date.now());
    return result;
  }

  static clearSegmentCache(bvid: string, cid: number): void {
    const key: string = bvid + ':' + String(cid);
    SponsorBlockApi.segmentCache.delete(key);
    SponsorBlockApi.segmentCacheAt.delete(key);
  }

  static async vote(uuid: string, type: number): Promise<SponsorBlockResult> {
    const result: SponsorBlockResult = new SponsorBlockResult();
    if (uuid.length === 0) {
      result.message = '本地片段尚不能投票';
      return result;
    }
    const query: string = HttpClient.buildQuery({
      'UUID': uuid,
      'userID': SponsorBlockStore.userID(),
      'type': String(type),
    });
    const response: HttpResponse = await HttpClient.post(SERVER + '/api/voteOnSponsorTime?' + query, '', headers());
    result.status = response.status;
    result.ok = response.ok;
    result.message = response.ok ? '投票成功' : (response.status === 405 ? '你已经投过票了' :
      (response.body.length > 0 ? response.body : '投票失败'));
    return result;
  }

  static async reportViewed(uuid: string): Promise<void> {
    if (uuid.length === 0) return;
    await HttpClient.post(SERVER + '/api/viewedVideoSponsorTime?' + HttpClient.buildQuery({ 'UUID': uuid }), '', headers());
  }

  static async submit(bvid: string, cid: number, duration: number,
    segments: Array<SponsorBlockSegment>): Promise<SponsorBlockResult> {
    const result: SponsorBlockResult = new SponsorBlockResult();
    if (bvid.length === 0 || cid <= 0 || segments.length === 0) {
      result.message = '片段信息不完整';
      return result;
    }
    const body: Record<string, Object> = {};
    body['videoID'] = bvid;
    body['cid'] = String(cid);
    body['userID'] = SponsorBlockStore.userID();
    body['videoDuration'] = duration;
    body['userAgent'] = 'BiliHarmony/1.0';
    const payloadSegments: Array<Object> = [];
    for (let i: number = 0; i < segments.length; i++) {
      const segment: SponsorBlockSegment = segments[i];
      const payload: Record<string, Object> = {};
      payload['segment'] = [segment.start, segment.end];
      payload['category'] = segment.category;
      payload['actionType'] = segment.actionType;
      payload['cid'] = String(cid);
      payloadSegments.push(payload);
    }
    body['segments'] = payloadSegments;
    const submitHeaders: Record<string, string> = headers();
    submitHeaders['Content-Type'] = 'application/json; charset=utf-8';
    const response: HttpResponse = await HttpClient.post(SERVER + '/api/skipSegments', JSON.stringify(body),
      submitHeaders);
    result.status = response.status;
    result.ok = response.ok;
    result.message = response.ok ? '片段已提交，感谢标注' :
      (response.body.length > 0 ? response.body : '提交失败');
    if (response.ok) {
      SponsorBlockApi.clearSegmentCache(bvid, cid);
      const returned: Array<Object> = response.jsonArray();
      for (let i: number = 0; i < returned.length; i++) {
        const item: Record<string, Object> = asObject(returned[i]);
        result.uuids.push(str(item, 'UUID', ''));
      }
    }
    return result;
  }

  static async getUserInfo(ignoreCache: boolean = false): Promise<SponsorBlockUserInfo | null> {
    const response: HttpResponse = await HttpClient.get(SERVER + '/api/userInfo?' + HttpClient.buildQuery({
      'userID': SponsorBlockStore.userID(),
    }), headers(ignoreCache));
    if (!response.ok) return null;
    const json: Record<string, Object> = response.json();
    const info: SponsorBlockUserInfo = new SponsorBlockUserInfo();
    info.userName = str(json, 'userName', '');
    info.publicUserID = str(json, 'userID', '');
    info.minutesSaved = asNumber(json['minutesSaved'], 0);
    info.segmentCount = asNumber(json['segmentCount'], 0);
    info.viewCount = asNumber(json['viewCount'], 0);
    info.reputation = asNumber(json['reputation'], 0);
    info.vip = asNumber(json['vip'], 0) > 0;
    info.warnings = asNumber(json['warnings'], 0);
    info.warningReason = str(json, 'warningReason', '');
    return info;
  }

  static async setUsername(username: string): Promise<SponsorBlockResult> {
    const result: SponsorBlockResult = new SponsorBlockResult();
    const response: HttpResponse = await HttpClient.post(SERVER + '/api/setUsername?' + HttpClient.buildQuery({
      'userID': SponsorBlockStore.userID(),
      'username': username,
    }), '', headers(true));
    result.status = response.status;
    result.ok = response.ok;
    result.message = response.ok ? '空降昵称已更新' : (response.body.length > 0 ? response.body : '昵称更新失败');
    return result;
  }

  static async acknowledgeWarning(): Promise<SponsorBlockResult> {
    const result: SponsorBlockResult = new SponsorBlockResult();
    const body: Record<string, Object> = {};
    body['userID'] = SponsorBlockStore.userID();
    body['enabled'] = false;
    const requestHeaders: Record<string, string> = headers(true);
    requestHeaders['Content-Type'] = 'application/json; charset=utf-8';
    const response: HttpResponse = await HttpClient.post(SERVER + '/api/warnUser', JSON.stringify(body), requestHeaders);
    result.status = response.status;
    result.ok = response.ok;
    result.message = response.ok ? '已确认社区提醒' : (response.body.length > 0 ? response.body : '操作失败');
    return result;
  }
}
