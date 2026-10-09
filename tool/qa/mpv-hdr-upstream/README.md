These three unmodified mpv files are the patch bases for the HDR native fixture.
They come from ErBWs/mpv commit
`6edeee00a07b9b76f197aa71eee3d029fb090de4` and retain their original LGPL notices.

The fixture applies the delivered HDR patch to this base, compiles the complete
resulting `ohos_common.c` and `context_ohos.c`, then invokes their real functions.
Only the mpv object plumbing, libplacebo dependency calls, GL helper seams and
OHOS/EGL platform calls are stubbed. SDK types and operation enums remain real.
Actual GPU rendering and buffer composition are checked separately in the VM.

Run `node --test tool/qa/mpv-hdr.test.cjs` from the repository root. The runner
requires the DevEco native SDK (real platform/EGL declarations and LLVM), Python
and the libplacebo headers installed by the reproducible VM dependency build.
`MPV_HDR_TEST_SDK`, `MPV_TEST_LLVM_BIN`, `MPV_TEST_PYTHON` and
`MPV_HDR_TEST_PLACEBO_INCLUDE` override those locations. The default libplacebo
include directory is `.qa/mpv-speed-core/vm-deps/install/include`.

A clean checkout without these external headers or Git/compiler/Python reports
all 13 cases as **skipped**, with the missing prerequisites named; it does not
create a build directory or run the compilation hook. Set
`MPV_HDR_TEST_REQUIRED=1` in an environment that must execute the fixtures:
missing prerequisites then fail the tests. A missing dependency selected by a
non-empty explicit path override also fails instead of skipping. On Unix, `CC`
selects the host C compiler; the real OHOS SDK and libplacebo headers are still
required.

On Windows it builds a freestanding DLL and runs every exported C case through
Python ctypes; it needs no MSVC/CRT installation. With prerequisites available,
all 13 cases execute the native code.
OHOS and EGL stubs capture user-data at simulated buffer request time, inject
platform failures and check the actual context callbacks. This proves policy,
fallback and call ordering, not physical panel HDR luminance.
