# OHAudio PCM timeline patch

本仓库核心重建脚本依次应用 0001 PCM 时间线、0002 解码初始化保护、0003 HDR 输出与
0004 尺寸变化保留颜色标签。0004 只移除纯 resize 的颜色缓存失效，真实颜色/元数据变化仍会重建输出 surface。
脚本同时识别 macOS/Linux 与 Windows SDK 工具文件名；固定输入和真实产物记录在
`rebuild-report-arm64.json`，应用打包时用包检查器核对剥离后的实际库。

Apply `patches/0001-ohaudio-pcm-timeline.patch` to
[`ErBWs/mpv`](https://github.com/ErBWs/mpv) commit
`6edeee00a07b9b76f197aa71eee3d029fb090de4`:

```sh
git checkout --detach 6edeee00a07b9b76f197aa71eee3d029fb090de4
git apply --check /path/to/biliharmony/tool/mpv/patches/0001-ohaudio-pcm-timeline.patch
git apply /path/to/biliharmony/tool/mpv/patches/0001-ohaudio-pcm-timeline.patch
```

The application binary's original build recipe is
[`mpv-ohos/libmpv-ohos-build`](https://github.com/mpv-ohos/libmpv-ohos-build),
commit `1bab837e662ffa47ce51efd0720d3ed7c4988944`. The patch requires rebuilding
the playback core; an ArkTS or N-API adapter rebuild alone cannot apply it.
Keep the pinned FFmpeg and supporting library versions from that recipe.
The patch adds `audio/out/pcm_timeline.c` to Meson's source list and changes no
dependency versions or public libmpv client ABI.

## Timing model

The old audio clock subtracts `audio_speed * ao_get_delay()` from the last media
PTS written into the AO queue. A speed command changes that multiplier even
though already queued PCM still has its previous media duration. The video
scheduler also divides the whole media delay by the newly requested speed.

This patch records each copied aframe's PTS and effective sample rate before
OHAudio receives bare PCM. Its ordered segments map cumulative hardware sample
frames to media PTS. The OHAudio callback's existing hardware timestamp estimate
anchors those samples to monotonic time. Both the observed audio PTS and the next
video frame's deadline use this same mapping. User speed commands, audio samples,
pitch correction, AO buffer size, volume, pause/seek commands and `ao_get_delay()`
are unchanged. This mapping is enabled only for the OHAudio pull driver.

The timing table is protected by the existing AO buffer mutex. Audio-service
timestamp queries and `Pause`/`Start` calls remain outside that mutex. A hardware
position regression invalidates the sample epoch before the next PCM submission;
it does not flush audio. Reset/seek clears the table, pause freezes it, and resume
shifts its wall-clock anchor. Silent padding holds the last actual media PTS.
PCM without a usable PTS, an unavailable epoch or a table overflow returns to the
existing clock path. Segments are recorded during hardware startup, but their
clock queries remain disabled until OHAudio has a valid hardware timestamp.

OHAudio reports absolute `CLOCK_MONOTONIC` timestamps, while mpv uses a relative
clock and can select `CLOCK_MONOTONIC_RAW`. At each existing timestamp query,
the callback samples `CLOCK_MONOTONIC` between two mpv clock readings and uses
their midpoint to convert the hardware timestamp. It refreshes the callback's
current time after the query. The mapping waits for a positive hardware sample
position, and a position regression clears the previous epoch before accepting
a new one. These clock domains are documented in the
[OHAudio API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-audio-kit/capi-native-audiorenderer-h.md)
and the pinned mpv
[relative clock](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/osdep/timer.c)
and [clock selection](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/osdep/timer-linux.c).

Unknown PCM is represented explicitly so it cannot be
mistaken for silent padding. Consumed segments are pruned and adjacent segments
with the same rate are merged.

The hardware timestamp still has the driver's existing 250 ms query cadence.
The patch corrects the media-duration interpretation of that estimate; it does
not establish exact speaker latency or prove that a device route change preserves
queued PCM. Route changes, pause/resume, underrun and playback need runtime
verification on the supported HarmonyOS emulator before adopting the binary.

## Runnable tests

```sh
node --test tool/qa/mpv-pcm-timeline.test.cjs
```

The runner extracts the **actual module from the delivered patch**, compiles it
and the C fixture, then calls every fixture function through Python `ctypes`.
On Windows it uses the OHOS SDK's LLVM compiler and `lld-link` to create a native
x64 DLL without Visual Studio, Windows SDK or CRT dependencies. Set
`MPV_TEST_LLVM_BIN` and `MPV_TEST_PYTHON` if the SDK or Python paths differ. The
default Python path is the Codex bundled runtime. On Unix it uses `CC` (default
`cc`) and `python3`.

The fixture checks a 1x → 2x → 1x mixed queue at every millisecond, 60 fps video
deadlines across its boundaries, silent tails, pause/resume, epoch reset, unknown
PTS, segment merging, pruning and bounded-capacity fallback. It also tests clock
conversion with a large system uptime and a small mpv epoch, invalid references,
stale timestamps and a valid mixed-speed anchor. These fixtures run the real C
module; they do not replace a full core build or emulator playback.

## Windows ARM64 core rebuild

[`rebuild-ohos-core.py`](rebuild-ohos-core.py) rebuilds the patched ARM64 core
with the existing original dependency carrier. Use Python 3.12, Meson 1.12.1,
Git, and the DevEco OHOS native SDK containing LLVM and Ninja. The script uses
these existing tools and does not install them. `--meson-path` names a directory
containing the `mesonbuild` package; omit it when the selected Python can already
import Meson.

Run from the repository root in PowerShell. These paths match the current
Windows development environment; substitute the Python, Meson and SDK paths
when using another installation.

```powershell
$taskPython = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
& $taskPython tool/mpv/rebuild-ohos-core.py `
  --sdk 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native' `
  --meson-path '.qa/mpv-speed-core/tools' `
  --work-dir '.qa/mpv-rebuild-arm64'
```

[`rebuild-inputs.json`](rebuild-inputs.json) pins the mpv and build recipe SHAs,
six source archives, four original recipe patches, and the original release ZIP
and extracted core hashes. Every downloaded input is checked before use. The
script applies the FFmpeg and libplacebo recipe patches followed by the local
core patches listed below, then generates headers matching the original carrier.
Use `--original-core /path/to/original/libmpv.so` to reuse an existing unmodified
release core; its hash and size are still checked. `--prepare-only` prepares and
records the inputs without compiling. Reusing a dedicated work directory
refreshes the archive sources and removes only patch-added files before applying
each patch again; cached downloads must still match their checksums.

The carrier is a copy of the pinned original binary. The script locates its
actual ELF `DT_SONAME` string and changes the equal-length name from `libmpv.so`
to `libdep.so`, preserving its dependency implementations and exports. The new
core links to that carrier with strict undefined-symbol checks. Validation checks
the ARM64 architecture, both SONAMEs, symbolic binding, public mpv API exports,
and symbol providers for the core and carrier. The generated Meson source also
normalizes Windows backslashes in `CONFIGURATION` before embedding them in a C
string, so automatic reconfiguration remains compilable.

This core keeps the OHOS OpenGL path and disables its `shaderc` and `vulkan`
features. Those components remain present in the original carrier. This build
therefore has a different optional-feature boundary from a full recipe rebuild;
use the full original recipe when those rendering paths are required.

Outputs are under the chosen work directory: `artifacts/libmpv.so`,
`artifacts/libdep.so`, `artifacts/notice.txt`, `artifacts/licenses.txt`,
`rebuild-report.json`, and configuration/compilation logs. Keep both libraries
together when reviewing a package. The report records input and output hashes,
build options and ELF checks. A successful build confirms these static checks;
the report starts with `runtime_validated: false`. Playback, speed transitions,
pause/resume and device-route behavior still require runtime verification on a
matching ARM64 environment. The script does not replace production libraries or
package, install or deploy the application.

Retain the complete original carrier notices and licenses, including its
FFmpeg LGPL-3.0-or-later terms and the other bundled components. The new core's
`gpl=false` setting does not remove the carrier's license obligations. Deliver
the corresponding fixed sources, original recipe patches, PCM patch, manifest
and rebuild script alongside the binaries through the permitted source-delivery
mechanism described in [`notice.txt`](../../entry/src/main/resources/rawfile/mpv/notice.txt)
and [`player-core-reuse.md`](../../docs/player-core-reuse.md).

### Local core patch order

After the fixed dependency recipe patches, the rebuild script applies these
local core patches in order and records both hashes and patched source hashes:

1. [`0001-ohaudio-pcm-timeline.patch`](patches/0001-ohaudio-pcm-timeline.patch)
   adds the PCM media-time mapping for audio and video scheduling.
2. [`0002-ohcodec-init-failure.patch`](patches/0002-ohcodec-init-failure.patch)
   protects OHCodec cleanup when GL/Vulkan interop initialization failed and
   left `p->interop` unset. Successful initialization keeps the existing cleanup
   path.
3. [`0003-ohos-hdr-output.patch`](patches/0003-ohos-hdr-output.patch)
   negotiates HDR10/PQ and HLG in the existing OHOS OpenGL renderer, and falls
   back to SDR when the display, buffer format or platform settings do not
   support the requested output. It leaves the PCM timing patch intact.

Git is invoked with per-command LF settings, and patch application must report
actual checked files rather than skipped patches. These settings keep generated
source bytes stable for work directories both inside and outside the repository
without changing the user's Git configuration.

The second patch is a separate initialization-failure fix. Both sides of a VM
speed comparison use it, while the baseline excludes the first patch. The VM's
additional GLES texture-size probe guard stays in the QA build copies and is
not included in this ARM64 rebuild sequence. These compatibility changes and
successful ELF checks still do not establish successful playback or corrected
speed-transition behavior.

## OHOS HDR output

Use `vo=gpu`, `gpu-context=ohos`, and `egl-output-format=auto`. The core reads
the primary display's HDR format capabilities through the API 14
[NativeDisplayManager](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-arkui/capi-oh-display-manager-h.md).
Unknown capabilities enable SDR. HDR10/PQ and HLG are checked separately;
HDR Vivid support alone does not establish either format.

Before creating renderer resources, an HDR-capable display gets an exact
EGL 10/10/10/2 attempt. Its native visual must be RGBA1010102, NativeWindow
`SET_FORMAT`/`GET_FORMAT` must agree, and the actual default framebuffer must
report at least 10 bits per color component. Failed negotiation restores the
explicit RGBA8 path. The selected format remains fixed for that VO lifetime.

Each frame supplies its own source color metadata. Only the accepted platform
color space enters `ra_fbo.color_space`; the existing shader encodes that PQ,
HLG or SDR destination. Explicit target options participate in negotiation,
but an unsupported HDR request still produces SDR pixels and tags. ICC LUTs
do not declare a compatible HDR destination, so this automatic path uses SDR
and bypasses the LUT instead of attaching an incorrect HDR tag. Other GPU
backends keep their existing color handling.

NativeWindow color, metadata type, static metadata and brightness settings
must all succeed. Same-format content with changed mastering or light-level
metadata updates its payload. SDR restores sRGB, metadata type NONE, zero
static metadata and zero HDR brightness. The path writes no dynamic metadata:
NONE makes inherited HDR metadata inactive; the API rejects empty/NULL erase
requests, so it does not claim that a dynamic metadata blob was deleted.
See the platform's [actual setter implementation](https://github.com/openharmony/graphic_graphic_surface/blob/master/surface/src/native_window.cpp).

The producer copies those settings when
[requesting a buffer](https://github.com/openharmony/graphic_graphic_surface/blob/master/surface/src/producer_surface.cpp).
A color/static-metadata transition therefore recreates the EGL window surface
with the same context and config before rendering, then verifies that the
driver did not replace the requested color space. Cached rendered frames are
invalidated when the accepted destination changes. Ordinary frames and speed
changes do not recreate the surface. Failed transitions or swaps latch HDR
off and attempt SDR; three unrecoverable failures stop playback instead of
submitting incorrectly labelled frames.

Native policy and EGL failure fixtures exercise the delivered C source with
explicit dependency/platform stubs. These checks establish the negotiation
and rollback logic, not physical HDR display performance. The current
HarmonyOS x86_64 emulator reports no HDR support, and even a QA-only forced
capability build cannot create its 10-bit EGL context. Its runtime checks
therefore verify SDR fallback; a real 10-bit HDR presentation still requires a
capable environment. QA capability overrides and `BiliHdrOutput` logging stay
out of production artifacts.

Run the HDR source fixtures with `node --test tool/qa/mpv-hdr.test.cjs`.
They compile the actual policy and EGL context files reconstructed from the
fixed source plus 0003. SDK types and libplacebo declarations are real;
display/window/EGL/GL calls are controlled test doubles. The fixtures cover
independent PQ/HLG gates, unknown capabilities, true framebuffer depth,
format and metadata failures, same-PQ metadata updates, SDR reset, stable
frames without surface recreation, transition recovery and bounded stop.
