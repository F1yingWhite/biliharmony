import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

class DocumentExportError extends Error {
  code: number;

  constructor(message: string, code: number) {
    super(message);
    this.code = code;
  }
}

/** 文件授权与写入边界。取消返回 false；写入失败抛错，成功提示由业务确认结果后决定。 */
export class DocumentExportService {
  static isCancelled(error: Object): boolean {
    return error !== null && error !== undefined && (error as BusinessError).code === 13900042;
  }

  static async chooseTarget(context: common.UIAbilityContext, fileName: string, suffix: string,
    isCurrent: () => boolean = (): boolean => true): Promise<string> {
    if (!isCurrent()) return '';
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = [suffix];
    try {
      const targets: Array<string> = await documentPicker.save(options);
      return isCurrent() && targets.length > 0 ? targets[0] : '';
    } catch (error) {
      if (DocumentExportService.isCancelled(error as Object)) return '';
      if (error instanceof Error) throw error;
      const detail: BusinessError = error as BusinessError;
      throw new DocumentExportError(detail !== null && detail !== undefined && typeof detail.message === 'string' ?
        detail.message : '文件选择器不可用', detail !== null && detail !== undefined && typeof detail.code === 'number' ? detail.code : 0);
    }
  }

  static async saveText(context: common.UIAbilityContext, fileName: string, suffix: string, content: string,
    isCurrent: () => boolean = (): boolean => true): Promise<boolean> {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(content);
    const bytes: ArrayBuffer = encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength) as ArrayBuffer;
    return DocumentExportService.saveBinary(context, fileName, suffix, bytes, isCurrent);
  }

  static async saveBinary(context: common.UIAbilityContext, fileName: string, suffix: string, bytes: ArrayBuffer,
    isCurrent: () => boolean = (): boolean => true): Promise<boolean> {
    const target: string = await DocumentExportService.chooseTarget(context, fileName, suffix, isCurrent);
    if (target.length === 0 || !isCurrent()) return false;
    const file: fs.File = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      let offset: number = 0;
      while (offset < bytes.byteLength) {
        const written: number = fs.writeSync(file.fd, bytes.slice(offset));
        if (!Number.isFinite(written) || written <= 0 || written > bytes.byteLength - offset) {
          throw new Error('文件写入未完成');
        }
        offset += written;
      }
      return true;
    } finally {
      fs.closeSync(file);
    }
  }
}
