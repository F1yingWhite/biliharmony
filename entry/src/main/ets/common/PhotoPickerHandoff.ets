/** Exit the system picker result callback before a controller opens selected read-only URIs. */
export class PhotoPickerHandoff {
  static defer(uris: Array<string>): Promise<Array<string>> {
    const selected: Array<string> = uris.slice();
    return new Promise<Array<string>>((resolve) => {
      setTimeout(() => resolve(selected), 0);
    });
  }
}
