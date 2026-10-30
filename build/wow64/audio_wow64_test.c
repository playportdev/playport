/* SPDX-License-Identifier: GPL-3.0-or-later */
/* madeira-unix 0074's WoW64 audio table and window scratch, with the driver's
 * own stream operations from the patched audio_null_ios.c (test.py extracts
 * them). Only VM, RemoteIO, timers and clock are mocked. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <stdatomic.h>
#include <pthread.h>
#include "native_types.h"

#define FALSE 0
#define IOS_AUDIO_SAMPLE_RATE 48000u
#define IOS_AUDIO_CHANNELS 2u
#define IOS_AUDIO_BITS 32u
#define IOS_AUDIO_FRAME_BYTES 8u
#define IOS_AUDIO_BUFFER_FRAMES 1024u
#define IOS_MAX_STREAMS 16
#define NULL_AUDIO_FN_COUNT 37
#define LOG_FN_CALL(index, name) ((void)0)
static struct ios_stream *g_streams[IOS_MAX_STREAMS];
static _Atomic(struct ios_stream *) g_mix[IOS_MAX_STREAMS];
static pthread_mutex_t g_streams_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned g_stream_gen;

/* A real backing array stands in for a small mapped portion of a 4 GiB
 * window. The implied base is above 4 GiB, but not itself dereferenced. */
static _Alignas(65536) BYTE backing[4 * 1024 * 1024];
static uintptr_t window;
static void *owner = (void *)0x1234;
static void *allocation_owner;
static uintptr_t allocation_window;
static size_t next_guest = 0x20000;
static unsigned allocations, frees, attaches, detaches;
static int fail_alloc;
static void *bad_render_pointer;
uintptr_t ios_wow64_current_base(void) { return window; }
void *ios_jit_current_peb(void) { return owner; }
NTSTATUS ios_wow64_audio_alloc(void *o, uintptr_t b, size_t size, void **host)
{
    if (fail_alloc || o != owner || b != window) return -1;
    assert(next_guest + size < sizeof(backing));
    allocation_owner = o; allocation_window = b;
    *host = (void *)(b + next_guest);
    memset(*host, 0, size);
    next_guest += (size + 65535) & ~(size_t)65535;
    allocations++;
    return 0;
}
NTSTATUS ios_wow64_audio_free(void *o, uintptr_t b, void *host)
{
    assert(o == allocation_owner && b == allocation_window);
    assert((uintptr_t)host >= b + 0x20000 && (uintptr_t)host < b + sizeof(backing));
    frees++;
    return 0;
}
#include "audio_wow64_buffer.h"
static int ios_dev_attach(struct ios_stream *s, const struct WAVEFORMATEX_stub *fmt)
{ (void)s; (void)fmt; attaches++; return 0; }
static void ios_dev_detach(struct ios_stream *s) { (void)s; detaches++; }
static void ios_dev_stop_if_idle(void) {}
static int ios_stream_is_live(const struct ios_stream *s) { (void)s; return 1; }
static NTSTATUS NtWaitForSingleObject(HANDLE h, BOOL a, const void *t) { (void)h; (void)a; (void)t; return 0; }
static NTSTATUS NtClose(HANDLE h) { (void)h; return 0; }
/* The clock, the thread ids and madeira-unix 0241's diagnostics switch (on,
 * so its getbuf-thread and ml1065 counters run here too) */
static uint64_t mach_absolute_time(void) { return 0; }
static uint64_t mach_to_ns(uint64_t t) { return t; }
static unsigned long long current_tid = 1;
static unsigned long long ios_current_tid(void) { return current_tid; }
/* decision 0172's Mach side: what the gate asked of it */
typedef uint32_t UInt32;
struct ios_rt_thread;
static unsigned rt_calls, rt_promotions, rt_drops;
static unsigned long long rt_promoted_tid;
static void ios_audio_rt_producer(struct ios_stream *s, int new_producer)
{ (void)s; rt_calls++; if (new_producer) { rt_promotions++; rt_promoted_tid = current_tid; } }
static void ios_audio_rt_drop(struct ios_stream *s, const char *why) { (void)s; (void)why; rt_drops++; }
static unsigned rt_other_calls, rt_cycle_starts, rt_cycle_finishes;
static void ios_audio_rt_caller(void) { rt_other_calls++; }
static void ios_audio_rt_cycle_start(void) { rt_cycle_starts++; }
static void ios_audio_rt_cycle_finish(void) { rt_cycle_finishes++; }
static int ios_audio_diagnostics(void) { return 1; }
static void ios_current_win_thread(unsigned int *pid, unsigned int *tid, int *priority, int *base_priority)
{ *pid = 0x20; *tid = 0x24; *priority = 8; *base_priority = 0; }
#define pthread_mach_thread_np(thread) ((void)(thread), 0u)
#define qos_class_self() 0u
#include "native_functions.h"

/* Deliberately let the native getter return a foreign pointer to test the
 * checked inverse, without changing the conversion code being tested. */
static NTSTATUS mock_get_render_buffer(void *args)
{
    NTSTATUS status = ios_get_render_buffer(args);
    if (bad_render_pointer) ((struct get_render_buffer_params *)args)->data[0] = bad_render_pointer;
    return status;
}
#define ios_get_render_buffer mock_get_render_buffer
#include "native_other_functions.h"
#include "audio_wow64_ios.h"
#undef ios_get_render_buffer

static void *host(uint32_t guest) { return (void *)(window + guest); }
static struct ios_audio_create_stream32 new_request(void)
{
    struct WAVEFORMATEX_stub fmt = { .wFormatTag = 1, .nChannels = 2,
        .nSamplesPerSec = 48000, .nBlockAlign = 4, .wBitsPerSample = 16 };
    memcpy(host(0x11000), &fmt, sizeof(fmt));
    return (struct ios_audio_create_stream32){ .fmt = 0x11000, .channel_count = 0x12000,
        .stream = 0x12008, .flow = eRender, .duration = 1000000, .period = 100000 };
}
static stream_handle make_stream(void)
{
    struct ios_audio_create_stream32 p = new_request();
    assert(ios_wow64_create_stream(&p) == STATUS_SUCCESS && p.result == S_OK);
    stream_handle handle;
    memcpy(&handle, host(p.stream), sizeof(handle));
    assert(handle > UINT32_MAX); /* never truncate the host token */
    assert(*(UINT32 *)host(p.channel_count) == 2);
    return handle;
}
static void test_round_trip(void)
{
    stream_handle handle = make_stream();
    struct ios_stream *s = stream_from_handle(handle);
    struct ios_audio_get_render_buffer32 get = { .stream = handle, .frames = 8, .data = 0x13000 };
    assert(s->wow64_owner == owner && s->wow64_window == window);
    assert(ios_wow64_get_render_buffer(&get) == 0 && get.result == S_OK);
    uint32_t guest = *(uint32_t *)host(get.data);
    assert(guest >= 0x20000 && host(guest) == s->render_scratch);
    for (unsigned i = 0; i < 32; i++) ((BYTE *)host(guest))[i] = (BYTE)(i + 1);
    struct release_render_buffer_params release = { .stream = handle, .written_frames = 8 };
    assert(ios_wow64_release_render_buffer(&release) == 0 && release.result == S_OK);
    assert(atomic_load(&s->write_pos) == 8 && !s->pending_frames);
    assert(!memcmp(s->ring, host(guest), 32));
    release.written_frames = 2; release.flags = 2;
    get.frames = 2;
    assert(ios_wow64_get_render_buffer(&get) == 0 && get.result == S_OK);
    assert(ios_wow64_release_render_buffer(&release) == 0 && release.result == S_OK);
    assert(!memcmp(s->ring + 32, (BYTE[8]){0}, 8));
    /* The ABI stores an event HANDLE value, never B+event. */
    struct ios_audio_set_event_handle32 event = { .stream = handle, .event = 0x1357 };
    assert(ios_wow64_set_event_handle(&event) == 0 && event.result == S_OK);
    assert(s->event == (void *)0x1357);
    event.event = 0x87654321u;
    assert(ios_wow64_set_event_handle(&event) == 0 && s->event == (void *)(uintptr_t)event.event);
    struct release_stream_params close = { .stream = handle };
    assert(ios_wow64_release_stream(&close) == 0 && close.result == S_OK);
    assert(!stream_from_handle(handle) && allocations == frees);
    assert(ios_wow64_release_stream(&close) == 0 && close.result == (HRESULT)AUDCLNT_E_NOT_INITIALIZED);
}
static void test_rejection(void)
{
    struct ios_audio_create_stream32 create = new_request();
    create.stream = 0xfffffffc; /* eight-byte output straddles window end */
    unsigned before = allocations;
    assert(ios_wow64_create_stream(&create) == 0 && create.result == IOS_AUDIO_E_INVALIDARG);
    assert(allocations == before);
    create = new_request(); create.fmt = 1;
    assert(ios_wow64_create_stream(&create) == 0 && create.result == IOS_AUDIO_E_INVALIDARG);
    stream_handle handle = make_stream();
    struct ios_stream *s = stream_from_handle(handle);
    struct ios_audio_get_render_buffer32 get = { .stream = handle, .frames = 8, .data = 0xfffffffe };
    assert(ios_wow64_get_render_buffer(&get) == 0 && get.result == IOS_AUDIO_E_INVALIDARG);
    assert(!s->pending_frames);
    get.data = 0x13000;
    uintptr_t b = window;
    window += UINT64_C(0x100000000);
    struct release_stream_params close = { .stream = handle };
    assert(ios_wow64_release_stream(&close) == 0 && close.result == (HRESULT)AUDCLNT_E_NOT_INITIALIZED);
    window = b;
    owner = (void *)0x2345;
    assert(ios_wow64_release_stream(&close) == 0 && close.result == (HRESULT)AUDCLNT_E_NOT_INITIALIZED);
    owner = (void *)0x1234;
    bad_render_pointer = (void *)(window - 0x10000);
    assert(ios_wow64_get_render_buffer(&get) == 0 && get.result == (HRESULT)E_FAIL);
    assert(*(uint32_t *)host(get.data) == 0 && !s->pending_frames);
    bad_render_pointer = NULL;
    uint32_t out = 0xfeedbeef;
    assert(!ios_audio_to_guest(window, (void *)window, 4, &out) && out == 0xfeedbeef);
    assert(!ios_audio_to_guest(window, (void *)(window + UINT64_C(0x100000000)), 4, &out));
    assert(!ios_audio_to_guest(window, (void *)(window - 1), 4, &out));
    assert(!ios_audio_guest_range(0, 0x10000, 4));
    assert(ios_wow64_release_stream(&close) == 0 && close.result == S_OK);
}
static void test_buffers_and_detach(void)
{
    stream_handle handle = make_stream();
    struct ios_stream *s = stream_from_handle(handle);
    BYTE *old = s->render_scratch;
    old[0] = 0x7b;
    assert(ios_audio_scratch_resize(s, s->scratch_frames * 2));
    assert(s->render_scratch != old && s->render_scratch[0] == 0x7b);
    old = s->render_scratch;
    fail_alloc = 1;
    assert(!ios_audio_scratch_resize(s, s->scratch_frames * 2));
    assert(s->render_scratch == old);
    fail_alloc = 0;
    struct ios_audio_get_capture_buffer32 capture = { .stream = handle, .data = 0x14000,
        .frames = 0x14004, .flags = 0x14008, .devpos = 0x14010, .qpcpos = 0x14018 };
    memset(host(0x14000), 0xff, 32);
    assert(ios_wow64_get_capture_buffer(&capture) == 0 && capture.result == S_OK);
    assert(!memcmp(host(0x14000), (BYTE[12]){0}, 12));
    assert(*(UINT64 *)host(0x14010) == 0 && *(UINT64 *)host(0x14018) == 0);
    unsigned freed = frees;
    assert(ios_wow64_process_detach(NULL) == 0);
    assert(!stream_from_handle(handle) && !s->render_scratch && !s->valid);
    assert(frees == freed + 1 && allocations == frees);
    /* Production deliberately retains timer-reachable host state at detach. */
    free(s->ring); free(s);
    handle = make_stream(); s = stream_from_handle(handle);
    freed = frees;
    audio_null_ios_wow64_retire(window);
    assert(!stream_from_handle(handle) && !s->render_scratch && !s->valid);
    assert(frees == freed); /* delete_views, not a VM reentry under its lock */
    free(s->ring); free(s);
    /* Model the enclosing delete_views: the window is the final owner. */
    frees++;
    fail_alloc = 1;
    struct ios_audio_create_stream32 create = new_request();
    assert(ios_wow64_create_stream(&create) == 0 && create.result == E_OUTOFMEMORY);
    assert(*(stream_handle *)host(create.stream) == 0);
    fail_alloc = 0;
    assert(allocations == frees);
}
static void test_endpoints_midi_and_native(void)
{
    struct ios_audio_get_endpoint_ids32 endpoints = { .flow = eRender };
    assert(ios_wow64_get_endpoint_ids(&endpoints) == 0 && endpoints.num == 1);
    endpoints.endpoints = 0x15000; endpoints.size = 512;
    assert(ios_wow64_get_endpoint_ids(&endpoints) == 0 && endpoints.result == S_OK);
    struct endpoint *ep = host(endpoints.endpoints);
    assert(ep->name == 8 && ep->device > ep->name); /* byte offsets, not B+g */
    assert(!strcmp((char *)ep + ep->device, "ios-null"));
    endpoints.endpoints = 0;
    assert(ios_wow64_get_endpoint_ids(&endpoints) == 0 && endpoints.result == IOS_AUDIO_E_INVALIDARG);
    struct ios_audio_midi_init32 midi = { .err = 0x16000 };
    assert(ios_wow64_midi_init(&midi) == 0 && *(UINT *)host(midi.err) == DRV_FAILURE);
    struct ios_audio_midi_message32 msg = { .msg = MODM_GETNUMDEVS, .err = 0x16000, .notify = 0x16010 };
    memset(host(msg.notify), 0xff, 32);
    assert(ios_wow64_midi_out_message(&msg) == 0 && !*(UINT *)host(msg.err));
    assert(!((struct ios_audio_notify32 *)host(msg.notify))->send_notify);
    msg.notify = 0xfffffff0;
    assert(ios_wow64_midi_out_message(&msg) == IOS_AUDIO_STATUS_INVALID_PARAMETER);
    stream_handle handle = 0;
    UINT32 channels = 0;
    struct create_stream_params create = { .fmt = host(0x11000), .flow = eRender,
        .duration = 1000000, .channel_count = &channels, .stream = &handle };
    unsigned before = allocations;
    assert(ios_create_stream(&create) == 0 && create.result == S_OK);
    struct ios_stream *s = stream_from_handle(handle);
    assert(!s->wow64_window && !s->wow64_owner);
    BYTE *data;
    struct get_render_buffer_params get = { .stream = handle, .frames = 8, .data = &data };
    assert(ios_get_render_buffer(&get) == 0 && get.result == S_OK && data == s->render_scratch);
    struct release_stream_params close = { .stream = handle };
    assert(ios_wow64_release_stream(&close) == 0 && close.result == (HRESULT)AUDCLNT_E_NOT_INITIALIZED);
    assert(ios_release_stream(&close) == 0 && close.result == S_OK);
    assert(allocations == before); /* native clients keep their heap path */
}
/* decision 0172: the producer is the steady GetBuffer caller of a started stream */
static void get_buffers(stream_handle handle, unsigned long long tid, unsigned n, UINT32 frames)
{
    BYTE *data;
    struct get_render_buffer_params get = { .stream = handle, .frames = frames, .data = &data };
    struct release_render_buffer_params release = { .stream = handle, .written_frames = 0 };
    current_tid = tid;
    while (n--) {
        assert(ios_get_render_buffer(&get) == 0 && get.result == S_OK);
        assert(ios_release_render_buffer(&release) == 0);
    }
}
static void test_producer_gate(void)
{
    stream_handle handle = 0;
    struct create_stream_params create = { .fmt = host(0x11000), .flow = eRender,
        .duration = 1000000, .stream = &handle };
    assert(ios_create_stream(&create) == 0 && create.result == S_OK);
    struct ios_stream *s = stream_from_handle(handle);
    rt_calls = rt_promotions = rt_drops = 0;
    rt_other_calls = rt_cycle_starts = rt_cycle_finishes = 0;
    get_buffers(handle, 0x68, 40, 0);            /* a prefill before Start never counts */
    assert(!rt_calls && !rt_promotions && !s->producer_tid && rt_other_calls == 40);
    assert(!rt_cycle_starts && rt_cycle_finishes == 40); /* every ReleaseBuffer may close a cycle */
    s->started = 1;                              /* ios_start's reset, as in the driver */
    s->caller_run = 0; s->producer_tid = 0;
    get_buffers(handle, 0xf8, IOS_PRODUCER_STEADY_CALLS - 1, 0);
    assert(!rt_promotions && !rt_calls);
    get_buffers(handle, 0xf8, 1, 0);
    assert(rt_promotions == 1 && rt_promoted_tid == 0xf8 && s->producer_tid == 0xf8);
    get_buffers(handle, 0xf8, 10, 0);
    assert(rt_promotions == 1 && rt_calls == 11); /* the producer is checked on every call */
    assert(rt_cycle_starts == 11);               /* and each of its GetBuffers starts a work cycle */
    {   /* a GetBuffer that fails starts none */
        BYTE *data;
        struct get_render_buffer_params big = { .stream = handle, .frames = s->buffer_frames + 1, .data = &data };
        assert(ios_get_render_buffer(&big) == 0 && big.result != S_OK && rt_cycle_starts == 11);
    }
    uint64_t switches = atomic_load(&s->caller_switches);
    for (unsigned i = 0; i < 2 * IOS_PRODUCER_STEADY_CALLS; i++)
        get_buffers(handle, i & 1 ? 0xf8 : 0x360, 1, 0); /* alternating callers: nobody new */
    assert(rt_promotions == 1 && s->producer_tid == 0xf8);
    assert(atomic_load(&s->caller_switches) - switches == 2 * IOS_PRODUCER_STEADY_CALLS);
    get_buffers(handle, 0x360, IOS_PRODUCER_STEADY_CALLS, 0);
    assert(rt_promotions == 2 && rt_promoted_tid == 0x360 && s->producer_tid == 0x360);
    s->started = 0;                              /* stopped: no more producer calls */
    unsigned calls = rt_calls;
    get_buffers(handle, 0x360, 4, 0);
    assert(rt_calls == calls);
    struct release_stream_params close = { .stream = handle };
    assert(ios_release_stream(&close) == 0 && close.result == S_OK && rt_drops == 1);
    current_tid = 1;
}

/* decision 0172: the RT callback's hysteresis over a 48 kHz float stereo ring */
static float mix_out[2 * 1024];
static unsigned mix(struct ios_stream *s, UInt32 nframes)
{
    unsigned played = 0;
    uint64_t before = atomic_load(&s->play_pos);
    memset(mix_out, 0, sizeof(mix_out));
    ios_mix_stream(s, mix_out, nframes, 2, 48000);
    for (UInt32 f = 0; f < nframes; f++) if (mix_out[2 * f] != 0.0f) played++;
    assert(played == atomic_load(&s->play_pos) - before);
    return played;
}
static void produce(struct ios_stream *s, UINT32 frames)
{
    uint64_t wr = atomic_load(&s->write_pos);
    for (UINT32 i = 0; i < frames; i++) {
        float *v = (float *)(s->ring + (size_t)((wr + i) % s->buffer_frames) * s->frame_bytes);
        v[0] = v[1] = 0.25f;
    }
    atomic_store(&s->write_pos, wr + frames);
}
static void test_underrun_refill(void)
{
    struct ios_stream s = { .started = 1, .mixable = 1, .is_float = 1, .sample_bits = 32,
        .sample_rate = 48000, .channels = 2, .frame_bytes = 8, .buffer_frames = 4800 };
    s.ring = calloc(s.buffer_frames, s.frame_bytes);
    produce(&s, 1024); assert(mix(&s, 1024) == 1024);  /* healthy: unchanged */
    produce(&s, 500); assert(mix(&s, 1024) == 500);    /* one short callback plays what is there */
    produce(&s, 1024); assert(mix(&s, 1024) == 1024);  /* and is not a refill */
    produce(&s, 300); assert(mix(&s, 1024) == 300);    /* the second short in 8 callbacks */
    uint64_t held = atomic_load(&s.play_pos);
    produce(&s, 700); assert(mix(&s, 1024) == 0);      /* refilling: silence, the clock holds */
    assert(atomic_load(&s.play_pos) == held);
    produce(&s, 400); assert(mix(&s, 1024) == 1024);   /* 1100 queued >= one callback: whole again */
    produce(&s, 100); assert(mix(&s, 1024) == 176);    /* one short after a refill: no refill */
    produce(&s, 100); assert(mix(&s, 1024) == 100);    /* a second one starts it */
    for (unsigned i = 0; i < IOS_REFILL_MAX_CALLBACKS; i++) {
        produce(&s, 100); assert(mix(&s, 1024) == 0);  /* at most IOS_REFILL_MAX_CALLBACKS silent ... */
    }
    produce(&s, 100); assert(mix(&s, 1024) == 400);    /* ... then what is there plays */
    uint64_t shorts = atomic_load(&s.short_callbacks);
    g_refill_on = 0;                                   /* MADEIRA_AUDIO_REFILL=0: the old behaviour */
    atomic_store(&s.short_history, 0);
    for (unsigned i = 0; i < 4; i++) { produce(&s, 200); assert(mix(&s, 1024) == 200); }
    assert(atomic_load(&s.short_callbacks) - shorts == 4);
    g_refill_on = 1;
    free(s.ring);
}
int main(void)
{
    window = (uintptr_t)backing;
    test_round_trip(); test_rejection(); test_buffers_and_detach();
    test_endpoints_midi_and_native();
    test_producer_gate(); test_underrun_refill();
    assert(attaches == detaches);
    puts("WoW64 iOS audio: PE32 layouts, 64-bit tokens, render/ring round trip, silence, HANDLE identity, pointer/owner rejection, capture, growth/OOM, release and owner teardown, producer gate and underrun refill passed");
    return 0;
}
