/**
 * MD5 工具：基于系统 cryptoFramework 实现
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

function toHex(data: Uint8Array): string {
  const hexChars: string = '0123456789abcdef';
  let result: string = '';
  for (let i: number = 0; i < data.length; i++) {
    const b: number = data[i];
    result += hexChars.charAt((b >> 4) & 0x0f) + hexChars.charAt(b & 0x0f);
  }
  return result;
}

/** 计算字符串的 MD5（小写 hex） */
export async function md5Hex(input: string): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
  const encoder: util.TextEncoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(input);
  const dataBlob: cryptoFramework.DataBlob = { data: bytes };
  await md.update(dataBlob);
  const output: cryptoFramework.DataBlob = await md.digest();
  return toHex(output.data);
}
