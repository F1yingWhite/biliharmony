import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/** Saves downloaded image data through the user-confirmed media-library flow. */
export class PhotoLibrarySaver {
  static async saveImage(context: common.UIAbilityContext, data: ArrayBuffer, extension: string,
    title: string): Promise<boolean> {
    const tempPath: string = context.cacheDir + '/' + title + '.' + extension;
    await PhotoLibrarySaver.writeFile(tempPath, data);
    try {
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
      if (destinationUri.length === 0) {
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
