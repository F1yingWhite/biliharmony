export enum ApiErrorKind {
  None = 'none',
  Network = 'network',
  Auth = 'auth',
  Business = 'business',
  Parse = 'parse',
}

/** 空数据也是成功结果；失败不携带可被误提交的默认模型。 */
export class ApiResult<T> {
  ok: boolean;
  data: T | null;
  message: string;
  kind: ApiErrorKind;
  code: number;

  constructor(data: T | null, message: string = '', kind: ApiErrorKind = ApiErrorKind.None, code: number = 0) {
    this.data = data;
    this.message = message;
    this.kind = kind;
    this.code = code;
    this.ok = kind === ApiErrorKind.None;
  }
}
