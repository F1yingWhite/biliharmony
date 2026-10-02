import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/** Saves downloaded image data through the user-confirmed media-library flow. */
export class PhotoLibrarySaver {
  private static nextTemporaryId: number = 0;

  static async saveImage(context: common.UIAbilityContext, data: ArrayBuffer, extension: string,
    title: string, isCurrent: () => boolean = (): boolean => true): Promise<boolean> {
    if (!isCurrent()) return false;
    // A cancelled owner can start another export while the system still holds the old preview.
    const temporaryId: number = ++PhotoLibrarySaver.nextTemporaryId;
    const tempPath: string = context.cacheDir + '/photo-export-' + Date.now() + '-' + temporaryId + '.' + extension;
    try {
      await PhotoLibrarySaver.writeFile(tempPath, data);
      if (!isCurrent()) return false;
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const destinationUri: string = await helper.showSingleAssetCreationDialogEx(
        fileUri.getUriFromPath(tempPath),
        {
          title,
          fileNameExtension: extension,
          photoType: photoAccessHelper.PhotoType.IMAGE,
        },
        true,
      );
      if (!isCurrent() || destinationUri.length === 0) {
        return false;
      }
      await PhotoLibrarySaver.writeFile(destinationUri, data);
      return true;
    } finally {
      try {
        await fs.unlink(tempPath);
      } catch (e) {
        // The cache file may already have been consumed or removed by the system dialog.
      }
    }
  }

  private static async writeFile(path: string, data: ArrayBuffer): Promise<void> {
    const file: fs.File = await fs.open(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
  }
}
