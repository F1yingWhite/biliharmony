/* Execute the actual patched OHOS color module with captured dependency calls.
 * SDK and libplacebo data declarations come from the real installed headers.
 * These cases test output policy and platform-call payloads, not shader math.
 */
#include <stdarg.h>
#include "ohos_common.h"
#include "vo.h"
#include <window_manager/oh_display_manager.h>

int _fltused = 0;
#define CHECK(value) do { if (!(value)) return __LINE__; } while (0)

void *memcpy(void *out, const void *in, size_t size)
{
    unsigned char *a = out;
    const unsigned char *b = in;
    for (size_t i = 0; i < size; i++) a[i] = b[i];
    return out;
}
void *memset(void *out, int value, size_t size)
{
    unsigned char *a = out;
    for (size_t i = 0; i < size; i++) a[i] = value;
    return out;
}
int memcmp(const void *a, const void *b, size_t size)
{
    const unsigned char *x = a, *y = b;
    for (size_t i = 0; i < size; i++) if (x[i] != y[i]) return x[i] - y[i];
    return 0;
}

static union { uint64_t align; unsigned char bytes[8192]; } heap;
static size_t heap_used;
void *fixture_talloc_zero(size_t size)
{
    size_t aligned = (size + 15) & ~(size_t)15;
    if (heap_used + aligned > sizeof(heap.bytes)) return NULL;
    void *result = heap.bytes + heap_used;
    heap_used += aligned;
    memset(result, 0, aligned);
    return result;
}
void talloc_free(void *ptr) { (void)ptr; }
static struct mp_log log_object;
struct mp_log *mp_log_new(void *parent, struct mp_log *log, const char *name)
{ (void)parent; (void)log; (void)name; return &log_object; }
struct mp_image_params vo_get_current_params(struct vo *vo) { return vo->fixture_params; }

/* Libplacebo is a dependency seam: complete source parameters are supplied by
 * the cases. Real rendering/libplacebo inference is exercised by the VM clips.
 */
static const struct pl_raw_primaries bt2020 = {
    .red = {.708f, .292f}, .green = {.170f, .797f},
    .blue = {.131f, .046f}, .white = {.3127f, .3290f},
};
const struct pl_color_space pl_color_space_srgb = {
    .primaries = PL_COLOR_PRIM_BT_709, .transfer = PL_COLOR_TRC_SRGB,
};
const struct pl_color_space pl_color_space_hdr10 = {
    .primaries = PL_COLOR_PRIM_BT_2020, .transfer = PL_COLOR_TRC_PQ,
    .hdr = {.min_luma = .005f, .max_luma = 1000.f},
};
const struct pl_color_space pl_color_space_bt2020_hlg = {
    .primaries = PL_COLOR_PRIM_BT_2020, .transfer = PL_COLOR_TRC_HLG,
    .hdr = {.min_luma = .005f, .max_luma = 1000.f},
};
void pl_color_space_infer(struct pl_color_space *color)
{
    if (!color->primaries) color->primaries = PL_COLOR_PRIM_BT_709;
    if (!color->transfer) color->transfer = PL_COLOR_TRC_SRGB;
    if (color->transfer == PL_COLOR_TRC_PQ || color->transfer == PL_COLOR_TRC_HLG) {
        if (!color->hdr.max_luma) color->hdr.max_luma = 1000.f;
        if (!color->hdr.min_luma) color->hdr.min_luma = .005f;
    }
}
bool pl_primaries_valid(const struct pl_raw_primaries *prim)
{ return prim->red.x > 0 && prim->green.y > 0 && prim->blue.x > 0 && prim->white.x > 0; }
const struct pl_raw_primaries *pl_raw_primaries_get(enum pl_color_primaries prim)
{ (void)prim; return &bt2020; }
bool pl_color_space_equal(const struct pl_color_space *a, const struct pl_color_space *b)
{ return memcmp(a, b, sizeof(*a)) == 0; }

struct NativeWindow { int live; };
static struct NativeWindow window_object;
static struct {
    int caps_mode, create_count, destroy_count, display_destroy_count;
    int color_count, metadata_count[3], brightness_count, bad_arguments;
    int fail_color_hdr, fail_color_all, fail_metadata_key, fail_brightness_hdr, bad_get_color;
    int fail_format_ten, wrong_get_format_ten, fail_geometry;
    OH_NativeBuffer_ColorSpace color;
    OH_NativeBuffer_MetadataType type;
    OH_NativeBuffer_StaticMetadata metadata;
    float brightness;
    int format;
} capture;
static NativeDisplayManager_DisplayInfo display_object;
static NativeDisplayManager_DisplayHdrFormat display_hdr;
static uint32_t formats[2];
NativeDisplayManager_ErrorCode OH_NativeDisplayManager_CreatePrimaryDisplay(NativeDisplayManager_DisplayInfo **out)
{
    *out = NULL;
    if (capture.caps_mode == 0) return DISPLAY_MANAGER_ERROR_SYSTEM_ABNORMAL;
    memset(&display_object, 0, sizeof(display_object));
    memset(&display_hdr, 0, sizeof(display_hdr));
    display_object.isAlive = true;
    display_object.hdrFormat = &display_hdr;
    display_hdr.hdrFormats = formats;
    display_hdr.hdrFormatLength = 1;
    formats[0] = capture.caps_mode == 1 ? 0 : capture.caps_mode == 2 ? 2 : capture.caps_mode == 3 ? 1 : 3;
    if (capture.caps_mode == 4) {
        formats[0] = 1; formats[1] = 2; display_hdr.hdrFormatLength = 2;
    } else if (capture.caps_mode == 6) {
        display_hdr.hdrFormats = NULL; display_hdr.hdrFormatLength = 1;
    } else if (capture.caps_mode == 7) {
        display_object.hdrFormat = NULL;
    }
    *out = &display_object;
    return DISPLAY_MANAGER_OK;
}
void OH_NativeDisplayManager_DestroyDisplay(NativeDisplayManager_DisplayInfo *display)
{ if (display == &display_object) capture.display_destroy_count++; }
int32_t OH_NativeWindow_CreateNativeWindowFromSurfaceId(uint64_t surface, OHNativeWindow **out)
{
    if (surface != 1) return 40001000;
    window_object.live = 1; *out = &window_object; capture.create_count++;
    return 0;
}
void OH_NativeWindow_DestroyNativeWindow(OHNativeWindow *window)
{ if (window == &window_object && window->live) { window->live = 0; capture.destroy_count++; } }
static bool hdr_window(void)
{ return capture.color == OH_COLORSPACE_DISPLAY_BT2020_PQ || capture.color == OH_COLORSPACE_DISPLAY_BT2020_HLG; }
int32_t OH_NativeWindow_SetColorSpace(OHNativeWindow *window, OH_NativeBuffer_ColorSpace color)
{
    if (!window || !window->live) return 40001000;
    capture.color_count++;
    bool hdr = color == OH_COLORSPACE_DISPLAY_BT2020_PQ || color == OH_COLORSPACE_DISPLAY_BT2020_HLG;
    if (capture.fail_color_all || (capture.fail_color_hdr && hdr)) return 50102000;
    capture.color = color;
    return 0;
}
int32_t OH_NativeWindow_GetColorSpace(OHNativeWindow *window, OH_NativeBuffer_ColorSpace *color)
{
    if (!window || !color || !window->live) return 40001000;
    *color = capture.bad_get_color ? OH_COLORSPACE_DISPLAY_SRGB : capture.color;
    return 0;
}
int32_t OH_NativeWindow_SetMetadataValue(OHNativeWindow *window, OH_NativeBuffer_MetadataKey key,
                                       int32_t size, uint8_t *bytes)
{
    // Real public implementation rejects null data and size <= 0.
    if (!window || !window->live || !bytes || size <= 0) {
        capture.bad_arguments++; return 40001000;
    }
    if (key < OH_HDR_METADATA_TYPE || key > OH_HDR_DYNAMIC_METADATA) return 50102000;
    capture.metadata_count[key - OH_HDR_METADATA_TYPE]++;
    if (capture.fail_metadata_key == key + 1 && hdr_window()) return 50102000;
    if (key == OH_HDR_METADATA_TYPE) {
        if (size != sizeof(capture.type)) { capture.bad_arguments++; return 40001000; }
        memcpy(&capture.type, bytes, sizeof(capture.type));
    } else if (key == OH_HDR_STATIC_METADATA) {
        if (size != sizeof(capture.metadata)) { capture.bad_arguments++; return 40001000; }
        memcpy(&capture.metadata, bytes, sizeof(capture.metadata));
    } else {
        // This implementation handles PQ/HLG; it must not invent dynamic data.
        capture.bad_arguments++; return 50102000;
    }
    return 0;
}
int32_t OH_NativeWindow_NativeWindowHandleOpt(OHNativeWindow *window, int op, ...)
{
    if (!window || !window->live) return 40001000;
    va_list args;
    va_start(args, op);
    int result = 0;
    if (op == SET_HDR_WHITE_POINT_BRIGHTNESS) {
        double brightness = va_arg(args, double);
        capture.brightness_count++;
        if (capture.fail_brightness_hdr && brightness > 0) result = 50102000;
        else capture.brightness = brightness;
    } else if (op == GET_BUFFER_GEOMETRY) {
        *va_arg(args, int *) = capture.fail_geometry ? 0 : 180;
        *va_arg(args, int *) = capture.fail_geometry ? 0 : 320;
    } else if (op == SET_FORMAT) {
        int format = va_arg(args, int);
        if (capture.fail_format_ten && format == NATIVEBUFFER_PIXEL_FMT_RGBA_1010102) result = 50102000;
        else capture.format = format;
    } else if (op == GET_FORMAT) {
        *va_arg(args, int *) = capture.wrong_get_format_ten && capture.format == NATIVEBUFFER_PIXEL_FMT_RGBA_1010102
            ? NATIVEBUFFER_PIXEL_FMT_RGBA_8888 : capture.format;
    } else result = 50102000;
    va_end(args);
    return result;
}

static struct mp_vo_opts options;
static struct vo vo;
static void reset_capture(int caps, enum pl_color_transfer transfer)
{
    memset(&capture, 0, sizeof(capture));
    memset(&vo, 0, sizeof(vo));
    memset(&options, 0, sizeof(options));
    heap_used = 0;
    capture.caps_mode = caps;
    options.WinID = 1;
    options.ohos_surface_size.w = 320; options.ohos_surface_size.h = 180;
    vo.opts = &options; vo.log = &log_object;
    vo.fixture_params.color = transfer == PL_COLOR_TRC_HLG ? pl_color_space_bt2020_hlg : pl_color_space_hdr10;
    vo.fixture_params.color.transfer = transfer;
    vo.fixture_params.color.hdr.prim = bt2020;
    vo.fixture_params.color.hdr.max_cll = 1000;
    vo.fixture_params.color.hdr.max_fall = 400;
}
static bool prepare(int caps, enum pl_color_transfer transfer, int bits, int format)
{
    reset_capture(caps, transfer);
    if (!vo_ohos_init(&vo)) return false;
    vo_ohos_set_output_depth(&vo, bits, bits, bits, bits == 10 ? 2 : 8, format, bits);
    return true;
}
static struct mp_image_params wanted(void) { return vo.fixture_params; }
static bool sdr(enum pl_color_transfer transfer)
{ return transfer != PL_COLOR_TRC_PQ && transfer != PL_COLOR_TRC_HLG && transfer != PL_COLOR_TRC_UNKNOWN; }

int case_hdr_capability_and_depth(void)
{
    int modes[] = {0, 1, 5, 6, 7};
    for (int i = 0; i < 5; i++) {
        CHECK(prepare(modes[i], PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
        CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
        struct mp_image_params params = wanted();
        vo_ohos_set_color(&vo, &params);
        CHECK(sdr(params.color.transfer));
        CHECK(capture.type == OH_VIDEO_NONE && !hdr_window());
        CHECK(capture.bad_arguments == 0);
        vo_ohos_uninit(&vo);
    }
    CHECK(prepare(4, PL_COLOR_TRC_PQ, 8, NATIVEBUFFER_PIXEL_FMT_RGBA_8888));
    CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
    vo_ohos_set_output_depth(&vo, 10, 9, 10, 2, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102, 10);
    CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
    vo_ohos_set_output_depth(&vo, 10, 10, 10, 2, NATIVEBUFFER_PIXEL_FMT_RGBA_8888, 10);
    CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
    vo_ohos_set_output_depth(&vo, 10, 10, 10, 2, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102, 8);
    CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
    vo_ohos_uninit(&vo);
    return 0;
}
int case_hdr_pq_hlg_selection(void)
{
    CHECK(prepare(2, PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
    CHECK(vo_ohos_preferred_csp(&vo).transfer == PL_COLOR_TRC_PQ);
    struct mp_image_params params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    CHECK(params.color.primaries == PL_COLOR_PRIM_BT_2020 && params.color.transfer == PL_COLOR_TRC_PQ);
    CHECK(capture.color == OH_COLORSPACE_DISPLAY_BT2020_PQ && capture.type == OH_VIDEO_HDR_HDR10);
    CHECK(capture.metadata.smpte2086.maxLuminance == 1000.f);
    CHECK(capture.metadata.cta861.maxContentLightLevel == 1000.f);
    CHECK(capture.brightness > 0 && vo_ohos_output_ready(&vo));
    vo.fixture_params.color.transfer = PL_COLOR_TRC_HLG;
    CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
    vo_ohos_uninit(&vo);
    CHECK(prepare(3, PL_COLOR_TRC_HLG, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
    CHECK(vo_ohos_preferred_csp(&vo).transfer == PL_COLOR_TRC_HLG);
    params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    CHECK(capture.color == OH_COLORSPACE_DISPLAY_BT2020_HLG && capture.type == OH_VIDEO_HDR_HLG);
    vo.fixture_params.color.transfer = PL_COLOR_TRC_PQ;
    CHECK(sdr(vo_ohos_preferred_csp(&vo).transfer));
    CHECK(capture.bad_arguments == 0);
    vo_ohos_uninit(&vo);
    return 0;
}
int case_hdr_static_metadata_and_generation(void)
{
    CHECK(prepare(4, PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
    struct mp_image_params params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    uint64_t generation = vo_ohos_color_generation(&vo);
    int static_count = capture.metadata_count[OH_HDR_STATIC_METADATA - OH_HDR_METADATA_TYPE];
    for (int i = 0; i < 30; i++) {
        params = wanted();
        CHECK(vo_ohos_set_color(&vo, &params));
        CHECK(vo_ohos_color_generation(&vo) == generation);
    }
    CHECK(capture.metadata_count[OH_HDR_STATIC_METADATA - OH_HDR_METADATA_TYPE] == static_count);
    vo.fixture_params.color.hdr.max_luma = 2000;
    vo.fixture_params.color.hdr.max_cll = 1800;
    vo.fixture_params.color.hdr.max_fall = 500;
    params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    CHECK(capture.metadata.smpte2086.maxLuminance == 2000.f);
    CHECK(capture.metadata.cta861.maxContentLightLevel == 1800.f);
    CHECK(capture.metadata.cta861.maxFrameAverageLightLevel == 500.f);
    CHECK(vo_ohos_color_generation(&vo) > generation);
    CHECK(capture.bad_arguments == 0);
    vo_ohos_uninit(&vo);
    return 0;
}
int case_hdr_to_sdr_and_uninit(void)
{
    CHECK(prepare(4, PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
    struct mp_image_params params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    vo.fixture_params.color = pl_color_space_srgb;
    params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    CHECK(sdr(params.color.transfer) && capture.type == OH_VIDEO_NONE && !hdr_window());
    CHECK(capture.brightness == 0);
    OH_NativeBuffer_StaticMetadata empty = {0};
    CHECK(memcmp(&capture.metadata, &empty, sizeof(empty)) == 0);
    CHECK(capture.metadata_count[OH_HDR_DYNAMIC_METADATA - OH_HDR_METADATA_TYPE] == 0);
    vo.fixture_params.color = pl_color_space_hdr10;
    params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    vo_ohos_uninit(&vo);
    CHECK(vo.ohos == NULL && capture.destroy_count == 1);
    CHECK(capture.type == OH_VIDEO_NONE && capture.brightness == 0 && !hdr_window());
    CHECK(memcmp(&capture.metadata, &empty, sizeof(empty)) == 0);
    CHECK(capture.bad_arguments == 0);
    vo_ohos_uninit(&vo);
    CHECK(capture.destroy_count == 1);
    return 0;
}
int case_hdr_failure_rollback(void)
{
    for (int kind = 0; kind < 4; kind++) {
        CHECK(prepare(4, PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
        if (kind == 0) capture.fail_color_hdr = 1;
        if (kind == 1) capture.fail_metadata_key = OH_HDR_METADATA_TYPE + 1;
        if (kind == 2) capture.fail_metadata_key = OH_HDR_STATIC_METADATA + 1;
        if (kind == 3) capture.fail_brightness_hdr = 1;
        struct mp_image_params params = wanted();
        vo_ohos_set_color(&vo, &params);
        CHECK(sdr(params.color.transfer) && vo_ohos_output_ready(&vo));
        CHECK(capture.type == OH_VIDEO_NONE && !hdr_window() && capture.brightness == 0);
        uint64_t generation = vo_ohos_color_generation(&vo);
        for (int i = 0; i < 12; i++) {
            params = wanted(); vo_ohos_set_color(&vo, &params);
            CHECK(sdr(params.color.transfer));
            CHECK(vo_ohos_color_generation(&vo) == generation);
        }
        CHECK(capture.bad_arguments == 0);
        vo_ohos_uninit(&vo);
    }
    return 0;
}
int case_hdr_unrecoverable_output(void)
{
    CHECK(prepare(4, PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
    capture.fail_color_all = 1;
    struct mp_image_params params = wanted();
    CHECK(!vo_ohos_set_color(&vo, &params));
    CHECK(!vo_ohos_output_ready(&vo));
    capture.fail_color_all = 0;
    vo.fixture_params.color = pl_color_space_srgb;
    params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    CHECK(vo_ohos_output_ready(&vo) && !hdr_window());
    vo_ohos_uninit(&vo);
    return 0;
}
int case_hdr_verify_driver_override(void)
{
    CHECK(prepare(4, PL_COLOR_TRC_PQ, 10, NATIVEBUFFER_PIXEL_FMT_RGBA_1010102));
    struct mp_image_params params = wanted();
    CHECK(vo_ohos_set_color(&vo, &params));
    CHECK(vo_ohos_verify_color(&vo));
    capture.bad_get_color = 1;
    CHECK(!vo_ohos_verify_color(&vo));
    vo_ohos_uninit(&vo);
    return 0;
}

#include "mpv-hdr-context-fixture.h"
