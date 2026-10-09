#pragma once
#include "vo.h"
typedef struct pl_color_space pl_color_space_t;
struct GL { int unused; };
struct ra_ctx;
struct ra_ctx_params {
    bool (*check_visible)(struct ra_ctx *);
    pl_color_space_t (*preferred_csp)(struct ra_ctx *);
    void (*set_color)(struct ra_ctx *, struct mp_image_params *);
    void (*swap_buffers)(struct ra_ctx *);
};
struct ra_swapchain { struct ra_ctx *ctx; };
struct ra_ctx {
    struct vo *vo;
    struct mp_log *log;
    struct ra_swapchain *swapchain;
    void *priv;
};
struct ra_ctx_fns {
    const char *type, *name, *description;
    bool (*reconfig)(struct ra_ctx *);
    bool (*pass_colorspace)(struct ra_ctx *);
    int (*control)(struct ra_ctx *, int *, int, void *);
    bool (*init)(struct ra_ctx *);
    void (*uninit)(struct ra_ctx *);
};
#define VO_NOTIMPL -1
bool ra_gl_ctx_init(struct ra_ctx *, struct GL *, struct ra_ctx_params);
void ra_gl_ctx_uninit(struct ra_ctx *);
void ra_gl_ctx_resize(struct ra_swapchain *, int, int, int);
int ra_gl_ctx_color_depth(struct ra_swapchain *);
extern const struct ra_ctx_fns ra_ctx_ohos;
