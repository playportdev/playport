/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Link the real diagnostic implementation, not a second accounting model. */
#include "kk_descriptor_stats.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static void *publish(void *arg) {
  struct kk_descriptor_stats *s = arg;
  for (unsigned i = 0; i < 1000; i++) {
    struct kk_descriptor_scope scope =
        kk_descriptor_begin(s, KK_DESCRIPTOR_UPDATE);
    scope.start = 100;
    kk_descriptor_end_at(scope, false, 110);
  }
  return NULL;
}

int main(void) {
  assert(!kk_descriptor_clock_value(0, 1, 1));
  assert(!kk_descriptor_clock_value(TIME_MONOTONIC, -1, 1));
  assert(!kk_descriptor_clock_value(TIME_MONOTONIC, 1, -1));
  assert(!kk_descriptor_clock_value(TIME_MONOTONIC, 1, 1000000000));
  assert(!kk_descriptor_clock_value(TIME_MONOTONIC, INT64_MAX, 0));
  assert(kk_descriptor_clock_value(TIME_MONOTONIC, 1, 23) == 1000000023);
  assert(kk_descriptor_clock());
  struct kk_descriptor_stats s = {0};
  kk_descriptor_stats_init(&s);
  kk_descriptor_stats_log(&s, 1, false);
  uint64_t first_snapshot = s.snapshot;
  kk_descriptor_stats_log(&s, 2, false);
  assert(s.snapshot == first_snapshot && s.frames == 3);

  struct kk_descriptor_scope scope =
      kk_descriptor_begin(&s, KK_DESCRIPTOR_BIND);
  scope.start = 10;
  kk_descriptor_end_at(scope, true, 0);
  scope = kk_descriptor_begin(&s, KK_DESCRIPTOR_BIND);
  scope.start = 10;
  kk_descriptor_end_at(scope, false, 9);
  scope = kk_descriptor_begin(&s, KK_DESCRIPTOR_BIND);
  scope.start = 0;
  kk_descriptor_end_at(scope, false, 11);
  scope = kk_descriptor_begin(&s, KK_DESCRIPTOR_BIND);
  scope.start = 10;
  kk_descriptor_end_at(scope, false, 10); /* Quantized zero is not CPU time. */
  uint64_t *v = s.values[KK_DESCRIPTOR_BIND];
  assert(v[KK_DESCRIPTOR_CLOCK_ERRORS] == 3 &&
         v[KK_DESCRIPTOR_TIMED_CALLS] == 1);
  assert(v[KK_DESCRIPTOR_FAILURES] == 1 && v[KK_DESCRIPTOR_CALLS] == 4);
  assert(v[KK_DESCRIPTOR_ELAPSED] == 0 && v[KK_DESCRIPTOR_ACTIVE] == 0);
  scope = kk_descriptor_begin(&s, KK_DESCRIPTOR_BIND);
  kk_descriptor_stats_log(&s, 0, true); /* Must expose an incomplete scope. */
  kk_descriptor_end(scope, false);
  pthread_t a, b;
  assert(!pthread_create(&a, NULL, publish, &s));
  assert(!pthread_create(&b, NULL, publish, &s));
  assert(!pthread_join(a, NULL) && !pthread_join(b, NULL));
  v = s.values[KK_DESCRIPTOR_UPDATE];
  assert(v[KK_DESCRIPTOR_CALLS] == 2000 &&
         v[KK_DESCRIPTOR_TIMED_CALLS] == 2000);
  assert(v[KK_DESCRIPTOR_ELAPSED] == 20000 && v[KK_DESCRIPTOR_MAX] == 10);
  assert(v[KK_DESCRIPTOR_ACTIVE] == 0 && s.entered == s.completed);
  kk_descriptor_stats_log(&s, 7, true);
  kk_descriptor_add(&s, KK_DESCRIPTOR_UPDATE, KK_DESCRIPTOR_ELAPSED,
                    UINT64_MAX);
  assert(s.overflow && v[KK_DESCRIPTOR_ELAPSED] == UINT64_MAX);
  kk_descriptor_stats_log(&s, UINT32_MAX, true);
  s.frames = UINT64_MAX;
  kk_descriptor_stats_log(&s, 1, true);
  assert(s.frames == UINT64_MAX);
  struct kk_descriptor_stats unsupported = {0};
  kk_descriptor_stats_log(&unsupported, 0, false);
  assert(unsupported.report_clock_errors == 1 && unsupported.snapshot == 1);
  kk_descriptor_stats_log(&unsupported, 0, false);
  assert(unsupported.report_clock_errors == 2 && unsupported.snapshot == 1);
  kk_descriptor_stats_log(&unsupported, 0, true);
  assert(unsupported.report_clock_errors == 3 && unsupported.snapshot == 2);
  puts("ok descriptor helper: checked clock/error/zero/max/active/overflow and "
       "two-thread publication");
  return 0;
}
