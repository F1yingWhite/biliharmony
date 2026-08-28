/**
 * RSA 加密工具：B 站登录密码加密（RSA/ECB/PKCS1Padding，公钥为 X509 PEM）
 * 对应 PiliPlus lib/http/login.dart 中 encrypt 包的 RSA 用法
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export class RsaUtil {
  /**
   * 用 PEM 公钥加密明文，返回 base64 密文
   * @param pemKey 带 -----BEGIN PUBLIC KEY----- 头尾的 PEM 公钥
   * @param plaintext 明文（B 站密码登录为 salt + 明文密码）
   */
  static async encryptWithPublicKey(pemKey: string, plaintext: string): Promise<string> {
    const base64: util.Base64Helper = new util.Base64Helper();
    // 去掉 PEM 头尾与空白，得到 base64 编码的 X509 DER
    const body: string = pemKey
      .replace('-----BEGIN PUBLIC KEY-----', '')
      .replace('-----END PUBLIC KEY-----', '')
      .replace(/[\r\n\s]/g, '');
    const der: Uint8Array = base64.decodeSync(body);
    // 依据 DER 长度判断密钥规格：1024 位约 162 字节，2048 位约 294 字节（B 站 web 公钥为 1024 位）
    const alg: string = der.length > 200 ? 'RSA2048' : 'RSA1024';
    const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator(alg + '|PRIMES_2');
    // convertKey 支持 DER 字节；个别系统版本只认 base64 字符串，失败时回退
    let keyPair: cryptoFramework.KeyPair;
    try {
      keyPair = await generator.convertKey({ data: der }, null);
    } catch (e) {
      const keyEncoder: util.TextEncoder = new util.TextEncoder();
      keyPair = await generator.convertKey({ data: keyEncoder.encodeInto(body) }, null);
    }
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(alg + '|PKCS1');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
    const textEncoder: util.TextEncoder = new util.TextEncoder();
    const input: cryptoFramework.DataBlob = { data: textEncoder.encodeInto(plaintext) };
    const output: cryptoFramework.DataBlob = await cipher.doFinal(input);
    return base64.encodeToStringSync(output.data);
  }
}
