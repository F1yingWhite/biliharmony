/* Included by mpv-hdr-fixture.c to share the captured NativeWindow boundary.
 * context_ohos.c itself is a separate, complete, actually compiled module.
 */
#include <EGL/egl.h>
#include "egl_helpers.h"
#include "input/input.h"

struct fake_egl_context { int bits, live; };
struct fake_egl_surface {
    int live, bits;
    OH_NativeBuffer_ColorSpace requested_color;
    OH_NativeBuffer_MetadataType requested_type;
    float requested_peak;
};
static struct fake_egl_context contexts[2];
static struct fake_egl_surface surfaces[64];
static struct {
    int fail_mode, fail_hdr_surface, fail_all_surfaces, fail_swap;
    int ten_attempts, eight_attempts, create_count, destroy_count, context_destroy_count;
    int swaps, resizes, gl_inits, gl_uninits, gl_without_context, bad_arguments, stops;
    int framebuffer_depth;
    EGLContext current_context;
    EGLSurface current_surface, last_created;
    struct ra_ctx_params callbacks;
} egl_capture;
static struct ra_ctx context;
static struct ra_swapchain swapchain;
void mp_mutex_lock(int *lock) { if (*lock) egl_capture.bad_arguments++; (*lock)++; }
void mp_mutex_unlock(int *lock) { if (*lock != 1) egl_capture.bad_arguments++; (*lock)--; }

EGLDisplay EGLAPIENTRY eglGetDisplay(EGLNativeDisplayType display)
{ (void)display; return (EGLDisplay)&egl_capture; }
EGLBoolean EGLAPIENTRY eglInitialize(EGLDisplay display, EGLint *major, EGLint *minor)
{ (void)display; (void)major; (void)minor; return EGL_TRUE; }
EGLContext EGLAPIENTRY eglGetCurrentContext(void) { return egl_capture.current_context; }
EGLBoolean EGLAPIENTRY eglGetConfigAttrib(EGLDisplay display, EGLConfig config, EGLint attr, EGLint *value)
{
    (void)display;
    struct fake_egl_context *cfg = (struct fake_egl_context *)config;
    int ten = cfg->bits == 10;
    if (attr == EGL_RED_SIZE || attr == EGL_GREEN_SIZE || attr == EGL_BLUE_SIZE)
        *value = ten && egl_capture.fail_mode == 2 ? 9 : cfg->bits;
    else if (attr == EGL_ALPHA_SIZE) *value = ten ? 2 : 8;
    else if (attr == EGL_NATIVE_VISUAL_ID)
        *value = ten && egl_capture.fail_mode != 3 ? NATIVEBUFFER_PIXEL_FMT_RGBA_1010102 : NATIVEBUFFER_PIXEL_FMT_RGBA_8888;
    else { egl_capture.bad_arguments++; return EGL_FALSE; }
    return EGL_TRUE;
}
EGLSurface EGLAPIENTRY eglCreateWindowSurface(EGLDisplay display, EGLConfig config,
                                             EGLNativeWindowType window, const EGLint *attrs)
{
    (void)display; (void)attrs;
    struct fake_egl_context *cfg = (struct fake_egl_context *)config;
    egl_capture.create_count++;
    if (window != (EGLNativeWindowType)&window_object || !window_object.live) {
        egl_capture.bad_arguments++; return EGL_NO_SURFACE;
    }
    if (egl_capture.fail_all_surfaces || (egl_capture.fail_hdr_surface && hdr_window()) ||
        (egl_capture.fail_mode == 6 && cfg->bits == 10)) return EGL_NO_SURFACE;
    if (egl_capture.create_count >= 64) { egl_capture.bad_arguments++; return EGL_NO_SURFACE; }
    struct fake_egl_surface *surface = &surfaces[egl_capture.create_count];
    surface->live = 1; surface->bits = cfg->bits;
    // Emulate the public RequestBuffer contract: snapshot producer user-data.
    surface->requested_color = capture.color;
    surface->requested_type = capture.type;
    surface->requested_peak = capture.metadata.smpte2086.maxLuminance;
    egl_capture.last_created = (EGLSurface)surface;
    return (EGLSurface)surface;
}
EGLBoolean EGLAPIENTRY eglMakeCurrent(EGLDisplay display, EGLSurface draw, EGLSurface read, EGLContext ctx)
{
    (void)display;
    if (ctx == EGL_NO_CONTEXT) {
        egl_capture.current_context = EGL_NO_CONTEXT; egl_capture.current_surface = EGL_NO_SURFACE;
        return EGL_TRUE;
    }
    struct fake_egl_context *native = (struct fake_egl_context *)ctx;
    if (!native->live || draw != read) { egl_capture.bad_arguments++; return EGL_FALSE; }
    if (egl_capture.fail_mode == 7 && native->bits == 10 && draw) return EGL_FALSE;
    if (draw && !((struct fake_egl_surface *)draw)->live) { egl_capture.bad_arguments++; return EGL_FALSE; }
    egl_capture.current_context = ctx; egl_capture.current_surface = draw;
    return EGL_TRUE;
}
EGLBoolean EGLAPIENTRY eglDestroySurface(EGLDisplay display, EGLSurface surface)
{
    (void)display;
    struct fake_egl_surface *native = (struct fake_egl_surface *)surface;
    if (!native || !native->live) { egl_capture.bad_arguments++; return EGL_FALSE; }
    if (surface == egl_capture.current_surface) egl_capture.bad_arguments++;
    native->live = 0; egl_capture.destroy_count++;
    return EGL_TRUE;
}
EGLBoolean EGLAPIENTRY eglDestroyContext(EGLDisplay display, EGLContext ctx)
{
    (void)display;
    struct fake_egl_context *native = (struct fake_egl_context *)ctx;
    if (!native || !native->live) { egl_capture.bad_arguments++; return EGL_FALSE; }
    // EGL permits destroying a current context; destruction is deferred until
    // a later unbind. The cleanup-only surfaceless path legitimately does this.
    native->live = 0; egl_capture.context_destroy_count++;
    return EGL_TRUE;
}
EGLBoolean EGLAPIENTRY eglSwapBuffers(EGLDisplay display, EGLSurface surface)
{
    (void)display;
    if (!surface || surface != egl_capture.current_surface || !egl_capture.current_context) {
        egl_capture.bad_arguments++; return EGL_FALSE;
    }
    egl_capture.swaps++;
    return egl_capture.fail_swap ? EGL_FALSE : EGL_TRUE;
}
EGLint EGLAPIENTRY eglGetError(void) { return EGL_BAD_SURFACE; }

bool mpegl_create_context_cb(struct ra_ctx *ctx, EGLDisplay display, struct mpegl_cb cb,
                            EGLContext *out_context, EGLConfig *out_config)
{
    (void)ctx; (void)display;
    *out_context = EGL_NO_CONTEXT; *out_config = NULL;
    bool ten = cb.auto_r == 10;
    if (ten) egl_capture.ten_attempts++;
    else egl_capture.eight_attempts++;
    if (cb.auto_r != cb.auto_g || cb.auto_r != cb.auto_b || cb.auto_a != (ten ? 2 : 8)) {
        egl_capture.bad_arguments++; return false;
    }
    if (ten && egl_capture.fail_mode == 1) return false;
    struct fake_egl_context *native = &contexts[ten ? 0 : 1];
    native->bits = ten ? 10 : 8; native->live = 1;
    *out_context = (EGLContext)native; *out_config = (EGLConfig)native;
    return true;
}
void mpegl_load_functions(struct GL *gl, struct mp_log *log) { (void)gl; (void)log; }
bool ra_gl_ctx_init(struct ra_ctx *ctx, struct GL *gl, struct ra_ctx_params params)
{
    (void)gl;
    egl_capture.gl_inits++;
    if (!egl_capture.current_context) egl_capture.gl_without_context++;
    egl_capture.callbacks = params;
    swapchain.ctx = ctx; ctx->swapchain = &swapchain;
    return true;
}
void ra_gl_ctx_uninit(struct ra_ctx *ctx)
{
    if (ctx->swapchain) {
        egl_capture.gl_uninits++;
        if (!egl_capture.current_context) egl_capture.gl_without_context++;
    }
    ctx->swapchain = NULL;
}
void ra_gl_ctx_resize(struct ra_swapchain *sw, int width, int height, int fbo)
{
    (void)fbo;
    egl_capture.resizes++;
    if (!sw || width <= 0 || height <= 0) egl_capture.bad_arguments++;
    if (!egl_capture.current_context) egl_capture.gl_without_context++;
}
int ra_gl_ctx_color_depth(struct ra_swapchain *sw)
{
    (void)sw;
    if (egl_capture.framebuffer_depth) return egl_capture.framebuffer_depth;
    return ((struct fake_egl_context *)egl_capture.current_context)->bits;
}
void mp_input_run_cmd(struct input_ctx *input, const char **command)
{
    (void)input;
    if (command && command[0] && command[0][0] == 's' && command[0][1] == 't' &&
        command[0][2] == 'o' && command[0][3] == 'p' && !command[0][4] && !command[1])
        egl_capture.stops++;
    else egl_capture.bad_arguments++;
}
static void reset_context(int mode)
{
    reset_capture(4, PL_COLOR_TRC_PQ);
    memset(&egl_capture, 0, sizeof(egl_capture));
    memset(&contexts, 0, sizeof(contexts));
    memset(&surfaces, 0, sizeof(surfaces));
    memset(&context, 0, sizeof(context));
    egl_capture.fail_mode = mode;
    capture.fail_format_ten = mode == 4;
    capture.wrong_get_format_ten = mode == 5;
    context.vo = &vo; context.log = &log_object;
}

int case_hdr_context_eight_bit_fallback(void)
{
    for (int caps = 0; caps <= 1; caps++) {
        reset_context(0);
        capture.caps_mode = caps;
        CHECK(ra_ctx_ohos.init(&context));
        CHECK(egl_capture.ten_attempts == 0 && egl_capture.eight_attempts == 1);
        CHECK(capture.format == NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
        CHECK(sdr(egl_capture.callbacks.preferred_csp(&context).transfer));
        ra_ctx_ohos.uninit(&context);
        CHECK(egl_capture.bad_arguments == 0 && egl_capture.gl_without_context == 0);
    }
    for (int mode = 1; mode <= 8; mode++) {
        reset_context(mode);
        if (mode == 8) egl_capture.framebuffer_depth = 8;
        CHECK(ra_ctx_ohos.init(&context));
        CHECK(egl_capture.ten_attempts == 1 && egl_capture.eight_attempts == 1);
        CHECK(capture.format == NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
        CHECK(sdr(egl_capture.callbacks.preferred_csp(&context).transfer));
        CHECK(egl_capture.callbacks.check_visible(&context));
        CHECK(capture.type == OH_VIDEO_NONE && capture.brightness == 0);
        CHECK(egl_capture.stops == 0);
        ra_ctx_ohos.uninit(&context);
        CHECK(egl_capture.gl_inits == (mode == 8 ? 2 : 1) && egl_capture.gl_uninits == egl_capture.gl_inits);
        CHECK(egl_capture.bad_arguments == 0 && egl_capture.gl_without_context == 0 && capture.bad_arguments == 0);
    }
    return 0;
}
int case_hdr_context_tags_before_buffer(void)
{
    reset_context(0);
    CHECK(ra_ctx_ohos.init(&context));
    CHECK(egl_capture.ten_attempts == 1 && egl_capture.eight_attempts == 0);
    struct fake_egl_surface *initial = (struct fake_egl_surface *)egl_capture.last_created;
    CHECK(initial->requested_color == OH_COLORSPACE_DISPLAY_SRGB && initial->requested_type == OH_VIDEO_NONE);
    struct mp_image_params params = wanted();
    egl_capture.callbacks.set_color(&context, &params);
    CHECK(params.color.transfer == PL_COLOR_TRC_PQ);
    CHECK(egl_capture.callbacks.check_visible(&context));
    struct fake_egl_surface *pq_surface = (struct fake_egl_surface *)egl_capture.last_created;
    CHECK(pq_surface != initial && !initial->live);
    CHECK(pq_surface->requested_color == OH_COLORSPACE_DISPLAY_BT2020_PQ);
    CHECK(pq_surface->requested_type == OH_VIDEO_HDR_HDR10 && pq_surface->requested_peak == 1000.f);
    int creations = egl_capture.create_count, destroys = egl_capture.destroy_count;
    // Normal redraws and speed-only changes preserve the same color parameters.
    for (int i = 0; i < 90; i++) {
        params = wanted(); egl_capture.callbacks.set_color(&context, &params);
        CHECK(egl_capture.callbacks.check_visible(&context));
        egl_capture.callbacks.swap_buffers(&context);
    }
    CHECK(egl_capture.create_count == creations && egl_capture.destroy_count == destroys && egl_capture.swaps == 90);
    vo.fixture_params.color.hdr.max_luma = 2000;
    params = wanted(); egl_capture.callbacks.set_color(&context, &params);
    struct fake_egl_surface *new_metadata = (struct fake_egl_surface *)egl_capture.last_created;
    CHECK(new_metadata != pq_surface && new_metadata->requested_peak == 2000.f && !pq_surface->live);
    vo.fixture_params.color = pl_color_space_bt2020_hlg;
    params = wanted(); egl_capture.callbacks.set_color(&context, &params);
    struct fake_egl_surface *hlg_surface = (struct fake_egl_surface *)egl_capture.last_created;
    CHECK(hlg_surface != new_metadata && !new_metadata->live);
    CHECK(hlg_surface->requested_color == OH_COLORSPACE_DISPLAY_BT2020_HLG);
    CHECK(hlg_surface->requested_type == OH_VIDEO_HDR_HLG && params.color.transfer == PL_COLOR_TRC_HLG);
    vo.fixture_params.color = pl_color_space_srgb;
    params = wanted(); egl_capture.callbacks.set_color(&context, &params);
    struct fake_egl_surface *sdr_surface = (struct fake_egl_surface *)egl_capture.last_created;
    CHECK(sdr_surface->requested_color == OH_COLORSPACE_DISPLAY_SRGB && sdr_surface->requested_type == OH_VIDEO_NONE);
    CHECK(sdr_surface->requested_peak == 0 && params.color.transfer == PL_COLOR_TRC_SRGB);
    CHECK(egl_capture.gl_inits == 1 && egl_capture.context_destroy_count == 0 && egl_capture.stops == 0);
    ra_ctx_ohos.uninit(&context);
    CHECK(egl_capture.gl_without_context == 0 && egl_capture.bad_arguments == 0 && capture.bad_arguments == 0);
    return 0;
}
int case_hdr_context_transition_recovers_sdr(void)
{
    reset_context(0);
    CHECK(ra_ctx_ohos.init(&context));
    egl_capture.fail_hdr_surface = 1;
    struct mp_image_params params = wanted();
    egl_capture.callbacks.set_color(&context, &params);
    CHECK(sdr(params.color.transfer) && egl_capture.callbacks.check_visible(&context));
    CHECK(sdr(egl_capture.callbacks.preferred_csp(&context).transfer));
    struct fake_egl_surface *surface = (struct fake_egl_surface *)egl_capture.last_created;
    CHECK(surface->requested_type == OH_VIDEO_NONE && surface->requested_color == OH_COLORSPACE_DISPLAY_SRGB);
    CHECK(egl_capture.context_destroy_count == 0 && egl_capture.gl_inits == 1 && egl_capture.stops == 0);
    egl_capture.callbacks.swap_buffers(&context);
    CHECK(egl_capture.swaps == 1);
    ra_ctx_ohos.uninit(&context);
    CHECK(egl_capture.gl_without_context == 0 && egl_capture.bad_arguments == 0 && capture.bad_arguments == 0);
    return 0;
}
int case_hdr_context_terminal_failure_stop_once(void)
{
    for (int mode = 0; mode < 3; mode++) {
        reset_context(0);
        CHECK(ra_ctx_ohos.init(&context));
        if (mode == 0) egl_capture.fail_all_surfaces = 1;
        if (mode == 1) capture.fail_color_all = 1;
        if (mode == 2) {
            options.ohos_surface_size.w = options.ohos_surface_size.h = 0;
            capture.fail_geometry = 1;
        }
        for (int attempt = 1; attempt <= 6; attempt++) {
            struct mp_image_params params = wanted();
            egl_capture.callbacks.set_color(&context, &params);
            CHECK(!egl_capture.callbacks.check_visible(&context));
            egl_capture.callbacks.swap_buffers(&context);
            CHECK(egl_capture.swaps == 0);
            CHECK(egl_capture.stops == (attempt >= 3 ? 1 : 0));
        }
        ra_ctx_ohos.uninit(&context);
        CHECK(egl_capture.gl_uninits == 1 && egl_capture.gl_without_context == 0);
        CHECK(egl_capture.bad_arguments == 0 && capture.bad_arguments == 0);
    }
    return 0;
}
int case_hdr_context_driver_override_recovers_sdr(void)
{
    reset_context(0);
    CHECK(ra_ctx_ohos.init(&context));
    capture.bad_get_color = 1;
    struct mp_image_params params = wanted();
    egl_capture.callbacks.set_color(&context, &params);
    CHECK(sdr(params.color.transfer) && egl_capture.callbacks.check_visible(&context));
    CHECK(((struct fake_egl_surface *)egl_capture.last_created)->requested_type == OH_VIDEO_NONE);
    CHECK(egl_capture.stops == 0);
    ra_ctx_ohos.uninit(&context);
    CHECK(egl_capture.bad_arguments == 0 && egl_capture.gl_without_context == 0);
    return 0;
}
int case_hdr_context_swap_failure(void)
{
    reset_context(0);
    CHECK(ra_ctx_ohos.init(&context));
    egl_capture.fail_swap = 1;
    for (int attempt = 1; attempt <= 5; attempt++) {
        struct mp_image_params params = wanted();
        egl_capture.callbacks.set_color(&context, &params);
        CHECK(egl_capture.callbacks.check_visible(&context));
        vo.target_params = &params;
        egl_capture.callbacks.swap_buffers(&context);
        CHECK(!egl_capture.callbacks.check_visible(&context) && vo.target_params == NULL);
        CHECK(egl_capture.stops == (attempt >= 3 ? 1 : 0));
        egl_capture.callbacks.swap_buffers(&context);
        CHECK(egl_capture.swaps == attempt);
        CHECK(vo.params_mutex == 0);
    }
    ra_ctx_ohos.uninit(&context);
    CHECK(egl_capture.bad_arguments == 0 && egl_capture.gl_without_context == 0);
    return 0;
}
