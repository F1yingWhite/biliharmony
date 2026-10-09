// Execute the production PCM timeline, with no mock implementation or CRT.
#include "pcm_timeline.h"
#if defined(_WIN32)
// MSVC ABI marker for floating point use; no runtime support is needed.
int _fltused = 0;
#endif
#define CHECK(v) do { if (!(v)) return __LINE__; } while (0)
static struct mp_pcm_timeline timeline;
static double absolute(double v) { return v < 0 ? -v : v; }
static int near(double a, double b) { return absolute(a - b) < 1e-7; }

int case_speed_segments(void)
{
    struct mp_pcm_timeline *t = &timeline;
    mp_pcm_timeline_reset(t);
    mp_pcm_timeline_begin(t, 1000, 300, 1300000000, 1000000000);
    mp_pcm_timeline_add(t, 0, 100, 10, 1000);       // 1x PCM
    mp_pcm_timeline_add(t, 100, 100, 10.1, 500);   // 2x PCM
    mp_pcm_timeline_add(t, 200, 100, 10.3, 1000);  // 1x PCM
    double pts, previous = 10, delay;
    for (int ms = 0; ms <= 300; ms++) {
        int64_t now = 1000000000 + (int64_t)ms * 1000000;
        CHECK(mp_pcm_timeline_pts(t, now, &pts));
        CHECK(pts >= previous - 1e-8 && pts - previous <= .00200001);
        double expected = ms <= 100 ? 10 + ms / 1000.0 :
            ms <= 200 ? 10.1 + (ms - 100) / 500.0 : 10.3 + (ms - 200) / 1000.0;
        CHECK(near(pts, expected));
        CHECK(mp_pcm_timeline_deadline(t, pts + 1.0 / 60, now, &delay));
        CHECK(delay >= .008333 - 1e-7 && delay <= .016667 + 1e-7);
        previous = pts;
    }
    // At 1->2->1 user commands the legacy formula jumps by the full delay;
    // the actual PCM clock above stays continuous regardless of new commands.
    CHECK(near((10.4 - 1 * .3) - (10.4 - 2 * .3), .3));
    double last_deadline = 0;
    for (int frame = 1; frame <= 24; frame++) {
        CHECK(mp_pcm_timeline_deadline(t, 10 + frame / 60.0, 1000000000, &delay));
        CHECK(delay > last_deadline && delay - last_deadline <= .016667 + 1e-7);
        last_deadline = delay;
    }
    CHECK(near(last_deadline, .3));
    return 0;
}

int case_silent_tail(void)
{
    struct mp_pcm_timeline *t = &timeline; double pts, delay;
    mp_pcm_timeline_reset(t);
    mp_pcm_timeline_begin(t, 1000, 100, 1100000000, 1000000000);
    mp_pcm_timeline_add(t, 0, 60, 20, 1000);
    CHECK(mp_pcm_timeline_pts(t, 1080000000, &pts) && near(pts, 20.06));
    mp_pcm_timeline_begin(t, 1000, 100, 1200000000, 1050000000);
    mp_pcm_timeline_add(t, 30, 70, 20.06, 500);
    CHECK(mp_pcm_timeline_pts(t, 1120000000, &pts) && near(pts, 20.06));
    CHECK(mp_pcm_timeline_pts(t, 1140000000, &pts) && near(pts, 20.08));
    CHECK(mp_pcm_timeline_deadline(t, 20.07, 1120000000, &delay) && near(delay, .015));
    CHECK(mp_pcm_timeline_pts(t, 1400000000, &pts) && near(pts, 20.2));
    return 0;
}

int case_pause_and_epoch(void)
{
    struct mp_pcm_timeline *t = &timeline; double pts, delay;
    mp_pcm_timeline_reset(t);
    mp_pcm_timeline_begin(t, 1000, 100, 1100000000, 1000000000);
    mp_pcm_timeline_add(t, 0, 100, 30, 1000);
    mp_pcm_timeline_pause(t, true, 1030000000);
    CHECK(mp_pcm_timeline_pts(t, 2000000000, &pts) && near(pts, 30.03));
    mp_pcm_timeline_pause(t, false, 2030000000);
    CHECK(mp_pcm_timeline_pts(t, 2040000000, &pts) && near(pts, 30.04));
    CHECK(mp_pcm_timeline_deadline(t, 30.05, 2040000000, &delay) && near(delay, .01));
    // Seek/reset/route changes invalidate the old hardware epoch, never reuse it.
    mp_pcm_timeline_reset(t);
    CHECK(!mp_pcm_timeline_pts(t, 2040000000, &pts));
    CHECK(!mp_pcm_timeline_deadline(t, 30.05, 2040000000, &delay));
    mp_pcm_timeline_begin(t, 1000, 100, 3100000000, 3000000000);
    mp_pcm_timeline_add(t, 0, 100, 50, 1000);
    CHECK(mp_pcm_timeline_pts(t, 3010000000, &pts) && near(pts, 50.01));
    return 0;
}

int case_unknown_pts(void)
{
    struct mp_pcm_timeline *t = &timeline; double pts, delay;
    mp_pcm_timeline_reset(t);
    mp_pcm_timeline_begin(t, 1000, 100, 1100000000, 1000000000);
    mp_pcm_timeline_add(t, 0, 20, 60, 1000);
    // Real MP_NOPTS_VALUE from this fixed mpv SHA's common/common.h.
    const double native_nopts = -0x1p+63;
    CHECK(native_nopts == MP_PCM_TIMELINE_NOPTS);
    mp_pcm_timeline_add(t, 20, 40, native_nopts, 1000);
    mp_pcm_timeline_add(t, 60, 40, 60.06, 1000);
    CHECK(mp_pcm_timeline_pts(t, 1010000000, &pts) && near(pts, 60.01));
    // A failed lookup must clear both its previous output and preceding valid
    // segment, so a bridge can never accidentally publish a stale media PTS.
    CHECK(!mp_pcm_timeline_pts(t, 1040000000, &pts) && pts == native_nopts);
    CHECK(!mp_pcm_timeline_deadline(t, native_nopts, 1040000000, &delay));
    CHECK(!mp_pcm_timeline_deadline(t, 60.04, 1040000000, &delay));
    CHECK(mp_pcm_timeline_pts(t, 1080000000, &pts) && near(pts, 60.08));
    mp_pcm_timeline_reset(t);
    CHECK(!mp_pcm_timeline_pts(t, 1080000000, &pts) && pts == native_nopts);
    mp_pcm_timeline_begin(t, 1000, 100, 1100000000, 1000000000);
    mp_pcm_timeline_add(t, 0, 20, 60, 1000);
    mp_pcm_timeline_add(t, 20, 80, 60.02, 0); // Unusable duration is unknown PCM.
    CHECK(!mp_pcm_timeline_pts(t, 1040000000, &pts) && pts == native_nopts);
    return 0;
}

int case_boundaries_and_capacity(void)
{
    struct mp_pcm_timeline *t = &timeline; double pts;
    mp_pcm_timeline_reset(t);
    mp_pcm_timeline_begin(t, 1000, 100, 1100000000, 1000000000);
    mp_pcm_timeline_add(t, 0, 50, 70, 1000);
    mp_pcm_timeline_add(t, 50, 50, 70.05, 1000);
    CHECK(t->count == 1); // Adjacent identical-rate chunks remain bounded.
    mp_pcm_timeline_begin(t, 1000, 100, 1200000000, 1050000000);
    mp_pcm_timeline_add(t, 0, 100, 70.1, 500);
    CHECK(t->count == 2);
    CHECK(mp_pcm_timeline_pts(t, 1150000000, &pts) && near(pts, 70.2));
    mp_pcm_timeline_begin(t, 1000, 100, 1300000000, 1210000000);
    CHECK(t->count == 1); // Consumed rate segments are pruned after the boundary.
    mp_pcm_timeline_reset(t);
    mp_pcm_timeline_begin(t, 1000, MP_PCM_TIMELINE_CAPACITY + 1, 2000000000, 1000000000);
    for (int n = 0; n <= MP_PCM_TIMELINE_CAPACITY; n++)
        mp_pcm_timeline_add(t, n, 1, 80 + n, 1000);
    CHECK(t->disabled && !mp_pcm_timeline_pts(t, 1100000000, &pts));
    mp_pcm_timeline_begin(t, 1000, 100, 2100000000, 1100000000);
    CHECK(!mp_pcm_timeline_pts(t, 1100000000, &pts));
    return 0;
}

int case_monotonic_clock_conversion(void)
{
    // Hardware uses boot-relative CLOCK_MONOTONIC; mpv can use a different
    // raw clock and subtracts its own process-start offset. Neither number
    // can be compared or subtracted directly before the paired conversion.
    const int64_t mono = INT64_C(7200000000000);
    const int64_t before = INT64_C(10000000000);
    const int64_t after = before + 20000;
    const int64_t midpoint = before + 10000;
    int64_t converted = -1;
    CHECK(mp_pcm_timestamp_from_monotonic(mono - 12000000, mono,
                                         before, after, &converted));
    CHECK(converted == midpoint - 12000000);
    // A query can have blocked before this local pair. Only the paired
    // references, not the callback's pre-query time, anchor the result.
    CHECK(mp_pcm_timestamp_from_monotonic(mono - 12000000, mono,
                                         before + 90000000, after + 90000000,
                                         &converted));
    CHECK(converted == midpoint + 90000000 - 12000000);
    // A different machine uptime / MONOTONIC-vs-RAW offset gives the same
    // mpv timestamp when the actual hardware age is unchanged.
    CHECK(mp_pcm_timestamp_from_monotonic(mono + 3000000000000 - 12000000,
                                         mono + 3000000000000, before, after,
                                         &converted));
    CHECK(converted == midpoint - 12000000);
    CHECK(mp_pcm_timestamp_from_monotonic(mono, mono, before, after, &converted));
    CHECK(converted == midpoint);
    CHECK(mp_pcm_timestamp_from_monotonic(mono - 1999999999, mono,
                                         before, after, &converted));
    CHECK(converted == midpoint - 1999999999);
    CHECK(!mp_pcm_timestamp_from_monotonic(mono - 2000000000, mono,
                                          before, after, &converted));
    CHECK(converted == 0);
    CHECK(!mp_pcm_timestamp_from_monotonic(mono + 1, mono,
                                          before, after, &converted));
    CHECK(converted == 0);
    CHECK(!mp_pcm_timestamp_from_monotonic(0, mono, before, after, &converted));
    CHECK(converted == 0);
    CHECK(!mp_pcm_timestamp_from_monotonic(mono, 0, before, after, &converted));
    CHECK(converted == 0);
    CHECK(!mp_pcm_timestamp_from_monotonic(mono, mono, 0, after, &converted));
    CHECK(converted == 0);
    CHECK(!mp_pcm_timestamp_from_monotonic(mono, mono, before, before - 1,
                                          &converted));
    CHECK(converted == 0);
    CHECK(!mp_pcm_timestamp_from_monotonic(mono - 20000000, mono,
                                          1000000, 1000020, &converted));
    CHECK(converted == 0); // Hardware point predates mpv's usable epoch.
    CHECK(mp_pcm_timestamp_from_monotonic(mono - 10, mono,
                                         INT64_MAX - 100, INT64_MAX - 2,
                                         &converted));
    CHECK(converted == INT64_MAX - 61); // Midpoint cannot overflow.

    // Exercise the real timeline with an output time obtained from the
    // converted hardware anchor, rather than an ideal same-domain clock.
    CHECK(mp_pcm_timestamp_from_monotonic(mono - 10000000, mono,
                                         before, after, &converted));
    struct mp_pcm_timeline *t = &timeline;
    mp_pcm_timeline_reset(t);
    int64_t played = 50 + (midpoint - converted) * 1000 / INT64_C(1000000000);
    CHECK(played == 60);
    mp_pcm_timeline_begin(t, 1000, 100,
                         midpoint + (100 - played) * INT64_C(1000000), midpoint);
    mp_pcm_timeline_add(t, 0, 100, 90, 1000);
    mp_pcm_timeline_begin(t, 1000, 100,
                         midpoint + (200 - played) * INT64_C(1000000), midpoint);
    mp_pcm_timeline_add(t, 0, 100, 90.1, 500);
    double pts, delay;
    CHECK(mp_pcm_timeline_pts(t, midpoint, &pts) && near(pts, 90.06));
    CHECK(mp_pcm_timeline_pts(t, midpoint + 50000000, &pts) && near(pts, 90.12));
    CHECK(mp_pcm_timeline_deadline(t, 90.12, midpoint, &delay) && near(delay, .05));
    return 0;
}
