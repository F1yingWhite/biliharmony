#pragma once
#include <EGL/egl.h>
#include "context.h"
struct mpegl_cb {
    int auto_r, auto_g, auto_b, auto_a;
    int (*refine_config)(void *, EGLConfig *, int);
    void *user_data;
};
bool mpegl_create_context_cb(struct ra_ctx *, EGLDisplay, struct mpegl_cb, EGLContext *, EGLConfig *);
void mpegl_load_functions(struct GL *, struct mp_log *);
