# Pinned OHOS libmpv binary

The application links `entry/libs/arm64-v8a/libmpv.so` dynamically through the
small `libbilimpv.so` N-API adapter. The prebuilt is checked into the repository
so an application build does not download or rebuild the playback core.

| Item | Pinned value |
| --- | --- |
| Build project | https://github.com/mpv-ohos/libmpv-ohos-build |
| Release | `20260715` |
| Release recipe commit | `1bab837e662ffa47ce51efd0720d3ed7c4988944` |
| Download | https://github.com/mpv-ohos/libmpv-ohos-build/releases/download/20260715/libmpv_aarch64.zip |
| ZIP SHA-256 | `ac8b176dc4c86f4772d62ff530762ec187c3c46383bf2d476870d17dad806e5b` |
| ELF SHA-256 | `672e98d497199a89e20893979ecec686dee1113bbe1b609c9a9266aa1679bd32` |
| Architecture | ELF64 AArch64 / `arm64-v8a` |
| Minimum platform | OHOS API 15 (the app targets and requires API 26) |
| mpv source and client header | https://github.com/ErBWs/mpv/tree/6edeee00a07b9b76f197aa71eee3d029fb090de4 |
| mpv version recorded by ELF | `mpv-v0.41-dev-g6edeee00a` |
| FFmpeg source | FFmpeg `n8.0`, commit `140fd653aed8cad774f991ba083e2d01e86420c7` |

The current build-project main branch is newer than this release. For rebuilding
this exact release, use the pinned recipe commit above, not the current scripts.
The release recipe and the embedded ELF configuration have been inspected.

The ELF contains FFmpeg and supporting libraries internally; it does not require
a separate application `libavcodec.so` or `libavformat.so`. Its dynamic platform
dependencies are `libc++_shared.so`, `libz.so`, `libc.so`, the public native media
decoder/codecbase/core libraries, `libohaudio.so`, `libnative_window.so`,
`libnative_buffer.so`, `libnative_image.so`, `libEGL.so`, and `libvulkan.so`.
The OHOS NDK build packages `libc++_shared.so` along with the native adapter.

The binary was verified to import `OH_VideoDecoder_*` and OHAudio renderer APIs
and to include `h264_ohcodec` and `hevc_ohcodec`. This establishes compiled
hardware decoder support; it does not establish successful hardware playback on
a particular phone. The application requests `hwdec=auto-safe`; the OHOS fork
includes `ohcodec` in that whitelist and libmpv retains software fallback.

The OHOS fork accepts an XComponent surface ID through the int64 `wid` option,
creates its own OHNativeWindow and EGL rendering context, and handles changes to
`ohos-surface-size` through `VOCTRL_EXTERNAL_RESIZE`. The adapter preserves the
64-bit surface ID by accepting a decimal string from ArkTS.

Audio and video URLs and HTTP header fields use typed native arrays. Both tracks
are loaded by one libmpv instance, with `video-sync=audio`. Media decoding, seek,
buffering, presentation, and audio/video synchronization remain in libmpv; the
adapter provides resource ownership and observed event delivery only. Playback
URLs and raw native diagnostic messages are never printed by the adapter.

## Licensing

The mpv part is built with `-Dgpl=false`. `LICENSE.LGPL` and `Copyright` in this
directory are the unchanged files from the pinned mpv source snapshot. The
embedded FFmpeg components identify themselves as **LGPL version 3 or later**,
because the release uses `--enable-version3`. Therefore the combined prebuilt
must not be described solely as LGPL 2.1. Application-distributed notices and
source/rebuild references are included under
`entry/src/main/resources/rawfile/mpv/` and in `docs/player-core-reuse.md`.

## TLS root certificates

The application packages Mozilla's public root certificate extract and supplies
its app-private file path to libmpv. `tls-verify=yes` is always enabled; the native
API refuses an empty certificate path. No user/device certificates or signing
material are included.

| Item | Pinned value |
| --- | --- |
| Bundle path | `entry/src/main/resources/rawfile/mpv/cacert.pem` |
| Source | https://curl.se/ca/cacert.pem |
| Source description and license | https://curl.se/docs/caextract.html |
| Certificate data timestamp | `2026-09-25 03:12:01 GMT` |
| SHA-256 of full packaged file | `a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505` |
| License | MPL 2.0, inherited from Mozilla certdata |

This is a fixed, reviewable CA bundle. It is updated explicitly as a dependency;
the application does not download a new trust store during playback.
