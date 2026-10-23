/* Links the production helper, not a second implementation of its arithmetic. */
#include "vkd3d_descriptor_stats.h"
#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

struct clock_script { const uint64_t *ticks; size_t count, cursor; };
static bool scripted(void *context, uint64_t *ticks)
{
    struct clock_script *script = context;
    assert(script->cursor < script->count);
    *ticks = script->ticks[script->cursor++];
    return *ticks != UINT64_MAX;
}
static _Atomic uint64_t clock_calls;
static bool incrementing(void *context, uint64_t *ticks)
{
    (void)context;
    *ticks = atomic_fetch_add(&clock_calls, 1);
    return true;
}
struct output { unsigned int enabled, calibration, snapshots; bool fail; char row[4096]; };
static bool output(void *context, const char *line)
{
    struct output *o = context;
    assert(strlen(line) < sizeof(o->row));
    assert(strstr(line, "[vkd3d-descriptor] v=1 component=vkd3d kind="));
    if (strstr(line, "kind=enabled"))
    {
        ++o->enabled;
        assert(strstr(line, "copy_simple_path=test"));
        assert(strstr(line, "cpu_clock=unsupported"));
        assert(strstr(line, "denominator=client_execute_requests_not_frames_or_gpu_completions"));
    }
    if (strstr(line, "kind=calibration"))
    {
        ++o->calibration;
        assert(strstr(line, "clock_reads=6"));
        if (!o->fail)
        {
            assert(strstr(line, "adjacent_ok=1"));
            assert(strstr(line, "scope_ok=1"));
            assert(strstr(line, "empty_ok=1"));
        }
    }
    if (strstr(line, "kind=snapshot"))
    {
        ++o->snapshots;
        if (strstr(line, "op=prep_graphics category=prep"))
            strcpy(o->row, line);
    }
    return !o->fail;
}
static void init_script(struct vkd3d_descriptor_stats *s, struct clock_script *script,
        const uint64_t *ticks, size_t n)
{
    *script = (struct clock_script){ticks, n, 0};
    struct vkd3d_descriptor_clock clock = {scripted, script, 1000, "script"};
    vkd3d_descriptor_stats_init(s, NULL, NULL, "test", &clock, false);
}
#define SCRIPT(s, c, ...) const uint64_t values[] = {__VA_ARGS__}; \
    init_script(&(s), &(c), values, sizeof(values) / sizeof(*values))
static uint64_t *row(struct vkd3d_descriptor_snapshot *v, enum vkd3d_descriptor_op op, unsigned int category)
{
    return v->rows[category * VKD3D_DS_OP_COUNT + op];
}
static void check_bad(struct vkd3d_descriptor_snapshot *v, enum vkd3d_descriptor_op op, unsigned int category)
{
    uint64_t *r = row(v, op, category);
    assert(r[VKD3D_DS_CALLS] == r[VKD3D_DS_COMPLETED]);
    assert(!r[VKD3D_DS_TIMED] && !r[VKD3D_DS_ELAPSED] && !r[VKD3D_DS_EXCLUSIVE]);
    assert(r[VKD3D_DS_CLOCK_ERRORS] && r[VKD3D_DS_NEST_ERRORS]);
}
static void nested(void)
{
    struct vkd3d_descriptor_stats s;
    struct clock_script c;
    struct vkd3d_descriptor_snapshot v;
    SCRIPT(s, c, 1, 10, 20, 30, 40, 50, 60, 100, 110, 120, 130, 200, 200);
    struct vkd3d_descriptor_scope p = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
    vkd3d_descriptor_add(&p, VKD3D_DS_DIRTY_ROOTS, 3);
    struct vkd3d_descriptor_scope child = vkd3d_descriptor_begin(&s, VKD3D_DS_VK_BIND);
    vkd3d_descriptor_add(&child, VKD3D_DS_SETS, 2);
    vkd3d_descriptor_end(&child); /* 20..30 */
    struct vkd3d_descriptor_scope excluded = vkd3d_descriptor_begin(&s, VKD3D_DS_SPEC_DATA);
    child = vkd3d_descriptor_begin(&s, VKD3D_DS_VK_OTHER);
    vkd3d_descriptor_end(&child); /* 50..60, excluded subtree */
    vkd3d_descriptor_end(&excluded); /* 40..100 */
    vkd3d_descriptor_end(&p); /* 10..110: children 70, exclusive 30 */
    p = vkd3d_descriptor_begin(&s, VKD3D_DS_COPY_RESOURCE);
    vkd3d_descriptor_add(&p, VKD3D_DS_REQUESTED_ELEMENTS, 7);
    vkd3d_descriptor_current_add(&s, VKD3D_DS_METADATA_BYTES, 280);
    vkd3d_descriptor_end(&p); /* 120..130 standalone */
    vkd3d_descriptor_end(&p); /* end-once is idempotent */
    vkd3d_descriptor_capture(&s, &v);
    assert(v.quiescent && v.clock_ok && !v.overflow && c.cursor == c.count);
    assert(row(&v, VKD3D_DS_PREP_GRAPHICS, 0)[VKD3D_DS_EXCLUSIVE] == 30);
    assert(row(&v, VKD3D_DS_PREP_GRAPHICS, 0)[VKD3D_DS_OUTER] == 100);
    assert(row(&v, VKD3D_DS_VK_BIND, 0)[VKD3D_DS_SETS] == 2);
    assert(row(&v, VKD3D_DS_VK_OTHER, 2)[VKD3D_DS_ELAPSED] == 10);
    assert(row(&v, VKD3D_DS_SPEC_DATA, 2)[VKD3D_DS_EXCLUSIVE] == 50);
    assert(row(&v, VKD3D_DS_COPY_RESOURCE, 1)[VKD3D_DS_METADATA_BYTES] == 280);
    assert(row(&v, VKD3D_DS_COPY_RESOURCE, 1)[VKD3D_DS_OUTER] == 10);
}
static void bad_siblings(uint64_t a, uint64_t b, uint64_t d, uint64_t e, bool deeper)
{
    struct vkd3d_descriptor_stats s;
    struct clock_script c;
    struct vkd3d_descriptor_snapshot v;
    uint64_t values[] = {1, 5, 10, a, b, d, e, 100, 110, 1000, 1000};
    /* Optional outer root brackets the original regression without changing its times. */
    if (!deeper)
    {
        uint64_t flat[] = {1, 10, a, b, d, e, 100, 1000, 1000};
        memcpy(values, flat, sizeof(flat));
    }
    init_script(&s, &c, values, deeper ? 11 : 9);
    struct vkd3d_descriptor_scope root = {0};
    if (deeper) root = vkd3d_descriptor_begin(&s, VKD3D_DS_COPY_RESOURCE);
    struct vkd3d_descriptor_scope p = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
    struct vkd3d_descriptor_scope child = vkd3d_descriptor_begin(&s, VKD3D_DS_VK_BIND);
    vkd3d_descriptor_end(&child);
    child = vkd3d_descriptor_begin(&s, VKD3D_DS_VK_UPDATE);
    vkd3d_descriptor_end(&child);
    vkd3d_descriptor_end(&p);
    if (deeper) vkd3d_descriptor_end(&root);
    vkd3d_descriptor_capture(&s, &v);
    check_bad(&v, VKD3D_DS_PREP_GRAPHICS, 0);
    check_bad(&v, VKD3D_DS_VK_UPDATE, 0);
    if (deeper) check_bad(&v, VKD3D_DS_COPY_RESOURCE, 1);
    assert(v.quiescent && v.clock_ok); /* Operation errors override otherwise clean capture. */
    printf("rejected siblings %"PRIu64"..%"PRIu64";%"PRIu64"..%"PRIu64" deeper=%u\n", a,b,d,e,deeper);
}
static void equal_and_ordered(void)
{
    for (unsigned int i = 0; i < 3; ++i)
    {
        struct vkd3d_descriptor_stats s;
        struct clock_script c;
        struct vkd3d_descriptor_snapshot v;
        const uint64_t traces[][9] = {{1,10,20,30,30,40,100,200,200},
            {1,10,20,30,40,50,100,200,200}, {1,10,10,10,10,10,10,10,10}};
        init_script(&s, &c, traces[i], 9);
        struct vkd3d_descriptor_scope p = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
        struct vkd3d_descriptor_scope a = vkd3d_descriptor_begin(&s, VKD3D_DS_VK_BIND);
        vkd3d_descriptor_end(&a);
        a = vkd3d_descriptor_begin(&s, VKD3D_DS_VK_BIND);
        vkd3d_descriptor_end(&a);
        vkd3d_descriptor_end(&p);
        vkd3d_descriptor_capture(&s, &v);
        uint64_t *r = row(&v, VKD3D_DS_PREP_GRAPHICS, 0);
        assert(r[VKD3D_DS_TIMED] == 1 && !r[VKD3D_DS_CLOCK_ERRORS] && !r[VKD3D_DS_NEST_ERRORS]);
        assert(r[VKD3D_DS_EXCLUSIVE] == (i == 2 ? 0 : 70));
    }
}
static void early_return(struct vkd3d_descriptor_stats *s, bool fail)
{
    struct vkd3d_descriptor_scope scope = vkd3d_descriptor_begin(s, VKD3D_DS_COPY_RESOURCE);
    if (fail)
    {
        vkd3d_descriptor_add(&scope, VKD3D_DS_FAILURES, 1);
        vkd3d_descriptor_end(&scope);
        return;
    }
    vkd3d_descriptor_end(&scope);
}
static void depth_mixed_and_recovery(void)
{
    struct vkd3d_descriptor_stats s, t;
    struct vkd3d_descriptor_snapshot v;
    struct vkd3d_descriptor_clock clock = {incrementing, NULL, 1000, "incrementing"};
    vkd3d_descriptor_stats_init(&s, NULL, NULL, "test", &clock, false);
    vkd3d_descriptor_stats_init(&t, NULL, NULL, "test", &clock, false);
    assert(s.device != t.device);
    struct vkd3d_descriptor_scope scopes[36];
    for (unsigned int i = 0; i < 36; ++i) scopes[i] = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
    for (unsigned int i = 36; i--;) vkd3d_descriptor_end(&scopes[i]);
    vkd3d_descriptor_capture(&s, &v);
    check_bad(&v, VKD3D_DS_PREP_GRAPHICS, 0);
    assert(row(&v, VKD3D_DS_PREP_GRAPHICS, 0)[VKD3D_DS_CALLS] == 36);
    scopes[0] = vkd3d_descriptor_begin(&s, VKD3D_DS_COPY_RESOURCE);
    scopes[1] = vkd3d_descriptor_begin(&t, VKD3D_DS_VK_BIND);
    vkd3d_descriptor_end(&scopes[1]); vkd3d_descriptor_end(&scopes[0]);
    vkd3d_descriptor_capture(&s, &v); check_bad(&v, VKD3D_DS_COPY_RESOURCE, 1);
    vkd3d_descriptor_capture(&t, &v); check_bad(&v, VKD3D_DS_VK_BIND, 1);
    early_return(&s, true); early_return(&s, false);
    vkd3d_descriptor_capture(&s, &v);
    assert(row(&v, VKD3D_DS_COPY_RESOURCE, 1)[VKD3D_DS_TIMED] == 2);
    assert(row(&v, VKD3D_DS_COPY_RESOURCE, 1)[VKD3D_DS_FAILURES] == 1);
    assert(v.quiescent);
}
static void *thread_scopes(void *context)
{
    struct vkd3d_descriptor_stats *s = context;
    for (unsigned int i = 0; i < 1000; ++i)
    {
        struct vkd3d_descriptor_scope a = vkd3d_descriptor_begin(s, VKD3D_DS_SIMPLE_SAMPLER);
        vkd3d_descriptor_add(&a, VKD3D_DS_REQUESTED_ELEMENTS, 3);
        struct vkd3d_descriptor_scope b = vkd3d_descriptor_begin(s, VKD3D_DS_VK_UPDATE);
        vkd3d_descriptor_end(&b); vkd3d_descriptor_end(&a);
    }
    return NULL;
}
static void threads_and_active(void)
{
    struct vkd3d_descriptor_stats s;
    struct vkd3d_descriptor_snapshot v;
    struct vkd3d_descriptor_clock clock = {incrementing, NULL, 1000, "incrementing"};
    pthread_t a,b;
    vkd3d_descriptor_stats_init(&s, NULL, NULL, "test", &clock, false);
    assert(!pthread_create(&a, NULL, thread_scopes, &s));
    assert(!pthread_create(&b, NULL, thread_scopes, &s));
    assert(!pthread_join(a, NULL) && !pthread_join(b, NULL));
    vkd3d_descriptor_capture(&s, &v);
    uint64_t *r = row(&v, VKD3D_DS_SIMPLE_SAMPLER, 1);
    assert(r[VKD3D_DS_CALLS] == 2000 && r[VKD3D_DS_COMPLETED] == 2000 && r[VKD3D_DS_TIMED] == 2000);
    assert(r[VKD3D_DS_REQUESTED_ELEMENTS] == 6000 && r[VKD3D_DS_CHILDREN] > 0);
    assert(r[VKD3D_DS_EXCLUSIVE] + r[VKD3D_DS_CHILDREN] == r[VKD3D_DS_ELAPSED]);
    assert(v.quiescent && !v.overflow);
    struct vkd3d_descriptor_scope scope = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
    vkd3d_descriptor_capture(&s, &v); assert(!v.quiescent && v.entered_after > v.completed_after);
    vkd3d_descriptor_end(&scope);
}
static void disabled_saturation_calibration(void)
{
    uint64_t before = atomic_load(&clock_calls);
    struct vkd3d_descriptor_scope disabled = vkd3d_descriptor_begin(NULL, VKD3D_DS_PREP_GRAPHICS);
    vkd3d_descriptor_add(&disabled, VKD3D_DS_CALLS, 1);
    vkd3d_descriptor_current_add(NULL, VKD3D_DS_METADATA_BYTES, 100);
    vkd3d_descriptor_end(&disabled); vkd3d_descriptor_report(NULL, true); vkd3d_descriptor_execute(NULL);
    assert(before == atomic_load(&clock_calls));
    struct vkd3d_descriptor_stats s;
    struct vkd3d_descriptor_snapshot v;
    struct output o = {0};
    struct vkd3d_descriptor_clock clock = {incrementing, NULL, 1000, "incrementing"};
    vkd3d_descriptor_stats_init(&s, output, &o, "test", &clock, true);
    assert(o.enabled == 1 && o.calibration == 16);
    assert(atomic_load(&s.entered) == 0 && atomic_load(&s.completed) == 0); /* Calibration scratch isolated. */
    struct vkd3d_descriptor_scope scope = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
    vkd3d_descriptor_add(&scope, VKD3D_DS_METADATA_BYTES, UINT64_MAX - 1);
    vkd3d_descriptor_add(&scope, VKD3D_DS_METADATA_BYTES, 8);
    vkd3d_descriptor_end(&scope);
    vkd3d_descriptor_capture(&s, &v);
    assert(v.overflow && row(&v, VKD3D_DS_PREP_GRAPHICS, 0)[VKD3D_DS_METADATA_BYTES] == UINT64_MAX);
    vkd3d_descriptor_execute(&s);
    assert(o.snapshots == VKD3D_DS_ROW_COUNT);
    vkd3d_descriptor_report(&s, false); assert(o.snapshots == VKD3D_DS_ROW_COUNT);
    vkd3d_descriptor_report(&s, true); assert(o.snapshots == 2 * VKD3D_DS_ROW_COUNT);
    puts(o.row);
    o.fail = true;
    vkd3d_descriptor_report(&s, true);
    assert(atomic_load(&s.report_errors) == VKD3D_DS_ROW_COUNT);
    before = atomic_load(&clock_calls);
    clock.hz = 0;
    o = (struct output){.fail = true};
    vkd3d_descriptor_stats_init(&s, output, &o, "test", &clock, true);
    scope = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS); vkd3d_descriptor_end(&scope);
    vkd3d_descriptor_capture(&s, &v);
    assert(!s.init_ok && !v.clock_ok && before == atomic_load(&clock_calls));
    check_bad(&v, VKD3D_DS_PREP_GRAPHICS, 0);
}
static void root_clock_and_recursive_wrappers(void)
{
    for (unsigned int i = 0; i < 4; ++i)
    {
        struct vkd3d_descriptor_stats s;
        struct clock_script c;
        struct vkd3d_descriptor_snapshot v;
        const uint64_t traces[][5] = {{1,UINT64_MAX,20,100,100}, {1,10,UINT64_MAX,100,100},
            {1,20,10,100,100}, {UINT64_MAX,10,20,100,100}};
        init_script(&s, &c, traces[i], 5);
        struct vkd3d_descriptor_scope scope = vkd3d_descriptor_begin(&s, VKD3D_DS_COPY_RTV);
        vkd3d_descriptor_end(&scope);
        vkd3d_descriptor_capture(&s, &v);
        if (i < 3) check_bad(&v, VKD3D_DS_COPY_RTV, 2);
        else assert(!s.init_ok && row(&v, VKD3D_DS_COPY_RTV, 2)[VKD3D_DS_TIMED] == 1);
    }
    struct vkd3d_descriptor_stats s;
    struct clock_script c;
    struct vkd3d_descriptor_snapshot v;
    SCRIPT(s, c, 1,10,20,30,100,200,199);
    struct vkd3d_descriptor_scope a = vkd3d_descriptor_begin(&s, VKD3D_DS_COPY_RESOURCE);
    struct vkd3d_descriptor_scope b = vkd3d_descriptor_begin(&s, VKD3D_DS_COPY_RESOURCE);
    vkd3d_descriptor_current_add(&s, VKD3D_DS_PROCESSED_ELEMENTS, 3);
    vkd3d_descriptor_end(&b); vkd3d_descriptor_end(&a);
    vkd3d_descriptor_capture(&s, &v);
    uint64_t *r = row(&v, VKD3D_DS_COPY_RESOURCE, 1);
    assert(r[VKD3D_DS_TIMED] == 2 && r[VKD3D_DS_OUTER] == 90);
    assert(r[VKD3D_DS_ELAPSED] == 100 && r[VKD3D_DS_EXCLUSIVE] == 90 && r[VKD3D_DS_PROCESSED_ELEMENTS] == 3);
    assert(!v.clock_ok && v.quiescent);
}

static void host_platform_schema(void)
{
    struct vkd3d_descriptor_stats s;
    struct output o = {0};
    vkd3d_descriptor_stats_init(&s, output, &o, "test", NULL, true);
    assert(o.enabled == 1 && o.calibration == 16 && s.init_ok);
    struct vkd3d_descriptor_scope scope = vkd3d_descriptor_begin(&s, VKD3D_DS_PREP_GRAPHICS);
    vkd3d_descriptor_add(&scope, VKD3D_DS_DIRTY_ROOTS, 3);
    vkd3d_descriptor_end(&scope);
    vkd3d_descriptor_execute(&s);
    assert(o.snapshots == VKD3D_DS_ROW_COUNT);
    assert(strstr(o.row, "overflow=0") && strstr(o.row, "quiescent=1") && strstr(o.row, "clock_ok=1"));
    puts(o.row);
}

int main(void)
{
    nested(); root_clock_and_recursive_wrappers(); host_platform_schema();
    bad_siblings(150,200,30,40,false); bad_siblings(20,50,40,60,false);
    bad_siblings(150,200,30,40,true); bad_siblings(20,50,40,60,true);
    bad_siblings(20,30,UINT64_MAX,40,true); bad_siblings(20,30,40,UINT64_MAX,true);
    bad_siblings(20,30,50,40,true);
    equal_and_ordered(); depth_mixed_and_recovery(); threads_and_active(); disabled_saturation_calibration();
    puts("vkd3d descriptor real-helper tests passed");
}
