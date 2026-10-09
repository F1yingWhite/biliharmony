#pragma once
struct mp_log { int unused; };
struct mp_log *mp_log_new(void *, struct mp_log *, const char *);
#define MP_VERBOSE(ctx, ...) ((void)(ctx))
#define MP_WARN(ctx, ...) ((void)(ctx))
#define MP_FATAL(ctx, ...) ((void)(ctx))
#define MP_ERR(ctx, ...) ((void)(ctx))
#define MP_INFO(ctx, ...) ((void)(ctx))
#define MP_DBG(ctx, ...) ((void)(ctx))
