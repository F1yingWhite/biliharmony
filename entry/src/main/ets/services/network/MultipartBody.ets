/**
 * multipart/form-data 请求体组装：动态图片上传（upload_bfs）等二进制上传接口使用。
 * 纯函数实现，零 kit 依赖：ArkTS 与 Node QA 沙箱中行为逐字节一致，可直接行为测试。
 */

/** 普通表单字段（文本）。 */
export class MultipartField {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

/** 文件表单字段（二进制）。 */
export class MultipartFile {
  name: string;
  filename: string;
  contentType: string;
  data: ArrayBuffer;

  constructor(name: string, filename: string, contentType: string, data: ArrayBuffer) {
    this.name = name;
    this.filename = filename;
    this.contentType = contentType;
    this.data = data;
  }
}

/** 组装结果：Content-Type 头（含 boundary）+ 完整请求体。 */
export class MultipartRequest {
  contentType: string = '';
  body: ArrayBuffer = new ArrayBuffer(0);
}

/** UTF-8 编码。ArkTS 没有 JS 的全局 TextEncoder，也不引 kit（保住零依赖可测性），手写实现。 */
export function utf8Bytes(text: string): Uint8Array {
  const out: Array<number> = [];
  for (let i: number = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    // 代理对合并成真实码点，避免中文表情区（U+10000+）被拆成两个非法三字节序列。
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xC0 | (code >> 6), 0x80 | (code & 63));
    } else if (code < 0x10000) {
      out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    } else {
      out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63),
        0x80 | (code & 63));
    }
  }
  return new Uint8Array(out);
}

/**
 * 组装 multipart/form-data 请求体。
 * 结构遵循 RFC 7578：`--boundary\r\n` + 头 + `\r\n\r\n` + 数据 + `\r\n`，结尾 `--boundary--\r\n`。
 * 网络栈对 ArrayBuffer 请求体按原始字节发送，因此字符串段必须在此显式 UTF-8 编码。
 */
export function buildMultipart(fields: Array<MultipartField>, files: Array<MultipartFile>,
  boundary: string): MultipartRequest {
  const parts: Array<Uint8Array> = [];
  let total: number = 0;
  const push = (chunk: Uint8Array): void => {
    parts.push(chunk);
    total += chunk.byteLength;
  };
  const pushText = (text: string): void => {
    push(utf8Bytes(text));
  };

  for (let i: number = 0; i < fields.length; i++) {
    pushText('--' + boundary + '\r\nContent-Disposition: form-data; name="' + fields[i].name +
      '"\r\n\r\n' + fields[i].value + '\r\n');
  }
  for (let i: number = 0; i < files.length; i++) {
    const file: MultipartFile = files[i];
    pushText('--' + boundary + '\r\nContent-Disposition: form-data; name="' + file.name +
      '"; filename="' + file.filename + '"\r\nContent-Type: ' + file.contentType + '\r\n\r\n');
    push(new Uint8Array(file.data));
    pushText('\r\n');
  }
  pushText('--' + boundary + '--\r\n');

  const body: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (let i: number = 0; i < parts.length; i++) {
    body.set(parts[i], offset);
    offset += parts[i].byteLength;
  }
  const result: MultipartRequest = new MultipartRequest();
  result.contentType = 'multipart/form-data; boundary=' + boundary;
  // body 是按完整长度新建的缓冲（offset 0），其 .buffer 即完整请求体。
  result.body = body.buffer as ArrayBuffer;
  return result;
}
