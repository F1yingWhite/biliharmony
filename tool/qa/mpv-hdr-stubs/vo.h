#pragma once
#include "common/common.h"
#include "common/msg.h"
#include "video/mp_image.h"
struct mp_vo_opts {
    int64_t WinID;
    struct { int w, h; } ohos_surface_size;
};
struct vo {
    struct vo_ohos_state *ohos;
    struct mp_log *log;
    struct mp_vo_opts *opts;
    struct input_ctx *input_ctx;
    int params_mutex;
    struct mp_image_params *target_params;
    int dwidth, dheight;
    struct mp_image_params fixture_params;
};
struct mp_image_params vo_get_current_params(struct vo *);
void mp_mutex_lock(int *);
void mp_mutex_unlock(int *);
