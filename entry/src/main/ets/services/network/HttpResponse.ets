/** HTTP 响应与单次 JSON 解析缓存；请求执行由 HttpClient 负责。 */
import { asObject } from '../../common/Utils';

export class HttpResponse {
  status: number;
  body: string;
  headers: Record<string, string>;
  /** 平台网络错误码；HTTP/业务失败与账号切换不使用此字段。 */
  transportCode: number;

  constructor(status: number, body: string, headers: Record<string, string>, transportCode: number = 0) {
    this.status = status;
    this.body = body;
    this.headers = headers;
    this.transportCode = transportCode;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  get transportMessage(): string {
    switch (this.transportCode) {
      case 2300005:
      case 2300006:
        return '无法解析服务器地址，请检查网络后重试';
      case 2300007:
        return '无法连接服务器，请稍后重试';
      case 2300028:
        return '请求超时，请稍后重试';
      case 2300058:
      case 2300060:
      case 2300077:
        return '安全连接验证失败，请检查系统时间与网络';
      case 2300063:
        return '返回内容过大，暂时无法加载';
      default:
        return '网络请求失败，请稍后重试';
    }
  }

  /** 解析后缓存：大响应（首页 feed/搜索/评论）常被 json()/getData()/failureText() 多次读取，
   *  每次都全量 JSON.parse 会成倍放大主线程开销（ArkTS 的 JSON.parse 相对较慢）。
   *  大 body 在返回调用方前经 taskpool 预热（adoptParsed 注入），首次读取即命中缓存。 */
  private parsedOnce: boolean = false;
  private parsedObject: Record<string, Object> = {} as Record<string, Object>;
  private parsedArrayBody: Array<Object> = [] as Array<Object>;

  /** 单次解析同时填充对象/数组两个视图，json() 与 jsonArray() 混用不再重复 parse。 */
  private ensureParsed(): void {
    if (this.parsedOnce) return;
    this.parsedOnce = true;
    try {
      const parsed: Object = JSON.parse(this.body) as Object;
      this.parsedObject = asObject(parsed);
      this.parsedArrayBody = Array.isArray(parsed) ? parsed as Array<Object> : [] as Array<Object>;
    } catch (e) {
      this.parsedObject = {} as Record<string, Object>;
      this.parsedArrayBody = [] as Array<Object>;
    }
  }

  /** taskpool 预热结果注入：后台线程解析好的对象树直接进缓存，主线程零解析。 */
  adoptParsed(parsed: Object): void {
    this.parsedOnce = true;
    this.parsedObject = asObject(parsed);
    this.parsedArrayBody = Array.isArray(parsed) ? parsed as Array<Object> : [] as Array<Object>;
  }

  /** 解析 JSON body，失败返回空对象 */
  json(): Record<string, Object> {
    this.ensureParsed();
    return this.parsedObject;
  }

  /** 解析 JSON 数组 body；body 非数组（如 JSON 对象）时返回空数组 */
  jsonArray(): Array<Object> {
    this.ensureParsed();
    return this.parsedArrayBody;
  }
}
