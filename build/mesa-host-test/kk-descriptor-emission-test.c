/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Link the actual kk_debug.c. Linker wrappers are host-only syscall/stdio
 * seams; the independent writer never takes stderr's FILE lock. */
#include "kk_descriptor_stats.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

ssize_t __real_write(int, const void *, size_t);
int __real_vsnprintf(char *, size_t, const char *, va_list);
long __real_fpathconf(int, int);
int __real_fcntl64(int, int, ...);
int __real_fstat64(int, struct stat64 *);
int __wrap_fprintf(FILE *, const char *, ...);
ssize_t __wrap_write(int, const void *, size_t);
int __wrap_vsnprintf(char *, size_t, const char *, va_list);
long __wrap_fpathconf(int, int);
int __wrap_fcntl64(int, int, ...);
int __wrap_fstat64(int, struct stat64 *);
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int requested, completed, done, peer_fd, handshakes;
static const char peer[] = "info:  [client-like] independent raw writer\n";
static int armed, calls, target, injected, format_calls;
static int record_writes, poison_writes, stat_calls, flag_calls, pipe_calls;
static int poison_formats;
static size_t row_length, poison_length;
static const char *mode;
static unsigned seed;

static void rendezvous(void)
{
   assert(!pthread_mutex_lock(&lock));
   if (handshakes) {
      int sequence = ++requested;
      assert(!pthread_cond_broadcast(&changed));
      while (completed < sequence)
         assert(!pthread_cond_wait(&changed, &lock));
   }
   assert(!pthread_mutex_unlock(&lock));
}

static void *client_writer(void *unused)
{
   (void)unused;
   assert(!pthread_mutex_lock(&lock));
   for (;;) {
      while (requested == completed && !done)
         assert(!pthread_cond_wait(&changed, &lock));
      if (done) break;
      assert(__real_write(peer_fd, peer, sizeof(peer) - 1) == sizeof(peer) - 1);
      completed = requested;
      assert(!pthread_cond_broadcast(&changed));
   }
   assert(!pthread_mutex_unlock(&lock));
   return NULL;
}

/* Pause the old emitter AFTER its real write_records field fprintf. This
 * reproduces write_records=0info: mid-line, before the remaining real fields.
 * Pause the new emitter's write only after the whole real syscall. */
int __wrap_fprintf(FILE *file, const char *fmt, ...)
{
   va_list ap;
   va_start(ap, fmt);
   bool splice = false;
   if (file == stderr && !strncmp(fmt, " %s=", 4)) {
      va_list copy;
      va_copy(copy, ap);
      splice = !strcmp(va_arg(copy, const char *), "write_records");
      va_end(copy);
   }
   int n = vfprintf(file, fmt, ap);
   va_end(ap);
   if (splice) rendezvous();
   return n;
}

ssize_t __wrap_write(int fd, const void *buf, size_t len)
{
   if (fd != STDERR_FILENO) return __real_write(fd, buf, len);
   if (len >= 15 && !memcmp(buf, "[kk-descriptor]", 15)) {
      record_writes++;
      row_length = len;
   }
   if (len >= 16 && !memcmp(buf, "\n[kk-descriptor]", 16)) {
      poison_writes++;
      poison_length = len;
      poison_formats = format_calls;
      assert(len <= 512 && ((const char *)buf)[len - 1] == '\n');
      if (!strcmp(mode, "poison-error")) { errno = ENOSPC; return -1; }
   }
   if (armed) {
      calls++;
      if ((!strcmp(mode, "eintr") && calls <= 2) ||
          (!strcmp(mode, "eintr-limit") && calls <= 3)) {
         injected++;
         errno = EINTR;
         return -1;
      }
      if (calls == target) {
         if (!strcmp(mode, "write-zero")) { injected++; errno = EDOM; return 0; }
         if (!strcmp(mode, "write-max")) { injected++; errno = EDOM; return SSIZE_MAX; }
         if (!strcmp(mode, "write-error") || !strcmp(mode, "poison-error") ||
             !strcmp(mode, "pipe-write-error")) {
            injected++;
            errno = EIO;
            return -1;
         }
         if (!strcmp(mode, "short") || !strcmp(mode, "newline-short")) {
            injected++;
            size_t n = !strcmp(mode, "short") ? len / 2 : len - 1;
            ssize_t written = __real_write(fd, buf, n);
            errno = EDOM; /* Positive short is not an errno failure. */
            return written;
         }
      }
      /* Terminal sink failure: even best-effort poison cannot be delivered. */
      if (!strcmp(mode, "newline-short") && calls > target) {
         errno = EIO;
         return -1;
      }
   }
   ssize_t n = __real_write(fd, buf, len);
   if (n == (ssize_t)len) rendezvous();
   return n;
}

int __wrap_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap)
{
   if (armed) format_calls++;
   if (armed && !strcmp(mode, "format-empty")) { injected++; return 0; }
   if (armed && format_calls == 2) {
      if (!strcmp(mode, "format-error")) { injected++; return -1; }
      if (!strcmp(mode, "format-overflow")) { injected++; return (int)size; }
   }
   int result = __real_vsnprintf(buf, size, fmt, ap);
   if (armed && result > 0 && (size_t)result < size) {
      /* Fixture row size only; the real emitter has a 2048-byte row buffer. */
      row_length = 2048 - size + result;
   }
   return result;
}

long __wrap_fpathconf(int fd, int name)
{
   pipe_calls++;
   if (armed && name == _PC_PIPE_BUF) {
      assert(errno == 0); /* Required to distinguish indeterminate -1. */
      if (!strcmp(mode, "pipe-error")) { errno = EIO; return -1; }
      if (!strcmp(mode, "pipe-indeterminate")) return -1;
      if (!strcmp(mode, "pipe-invalid")) return LONG_MIN;
      if (!strcmp(mode, "pipe-zero")) return 0;
      if (!strcmp(mode, "pipe-exact")) return row_length;
      if (!strcmp(mode, "pipe-too-small")) { errno = EDOM; return row_length - 1; }
      if (!strcmp(mode, "pipe-small")) return 512;
      if (!strcmp(mode, "pipe-max")) return LONG_MAX;
   }
   return __real_fpathconf(fd, name);
}

/* Mesa's Linux host flags select the large-file syscall symbols. */
int __wrap_fcntl64(int fd, int command, ...)
{
   /* Only production F_GETFL is wrapped; setup uses __real_fcntl64. */
   assert(fd == STDERR_FILENO && command == F_GETFL);
   flag_calls++;
   if (armed && !strcmp(mode, "getfl-error")) {
      errno = EIO;
      return -1;
   }
   int flags = __real_fcntl64(fd, command);
   if (armed && !strcmp(mode, "flags-max")) return INT_MAX & ~O_APPEND;
   return flags;
}

int __wrap_fstat64(int fd, struct stat64 *st)
{
   int result = __real_fstat64(fd, st);
   if (fd == STDERR_FILENO) {
      stat_calls++;
      if (armed && !strcmp(mode, "fstat-error")) { errno = EBADF; return -1; }
      if (!result && armed && !strcmp(mode, "unsupported-type"))
         st->st_mode = (st->st_mode & ~S_IFMT) | S_IFSOCK;
   }
   return result;
}

static void test_rejected_sink(void)
{
   struct kk_descriptor_stats s = {0};
   bool after_init = !strcmp(mode, "nonappend-after-init");
   if (after_init) {
      kk_descriptor_stats_init(&s);
      assert(!s.emission_failed && record_writes == 17 && !poison_writes);
      int flags = __real_fcntl64(STDERR_FILENO, F_GETFL);
      assert(flags >= 0 && (flags & O_APPEND));
      assert(!__real_fcntl64(STDERR_FILENO, F_SETFL, flags & ~O_APPEND));
      calls = format_calls = record_writes = poison_writes = stat_calls = flag_calls = 0;
   }
   armed = 1;
   errno = EDOM;
   if (after_init) kk_descriptor_stats_log(&s, 0, true);
   else kk_descriptor_stats_init(&s);
   assert(errno == EDOM);
   int init_calls = calls, init_formats = format_calls;
   int init_stats = stat_calls, init_flags = flag_calls, init_pipes = pipe_calls;
   kk_descriptor_stats_log(&s, 0, true);
   kk_descriptor_stats_log(&s, 0, true);
   printf("sink=%s latch=%u record_writes=%d poison_writes=%d writes=%d "
          "stat_queries=%d flag_queries=%d future_writes=%d\n",
          mode, s.emission_failed, record_writes, poison_writes, calls,
          stat_calls, flag_calls, calls - init_calls);
   fflush(stdout);
   assert(s.emission_failed && record_writes == 0 && poison_writes == 1);
   assert(calls == 1 && calls == init_calls && format_calls == init_formats);
   assert(poison_formats == init_formats && errno == EDOM);
   assert(stat_calls == init_stats && flag_calls == init_flags && pipe_calls == init_pipes);
   assert(stat_calls == (strcmp(mode, "format-empty") ? 1 : 0));
   assert(flag_calls == ((!strcmp(mode, "nonappend") || after_init ||
                          !strcmp(mode, "getfl-error") || !strcmp(mode, "flags-max")) ? 1 : 0));
}

/* Free-running competition, with a pinned PRNG determining bounded burst
 * sizes. No sleeps, shared FILE locks or artificial serialization. */
static void *stress_writer(void *unused)
{
   (void)unused;
   unsigned state = seed;
   for (unsigned i = 0; i < 4000; i++) {
      state = state * 1664525u + 1013904223u;
      for (unsigned j = 0; j < 1 + (state & 3); j++)
         assert(__real_write(peer_fd, peer, sizeof(peer) - 1) == sizeof(peer) - 1);
   }
   return NULL;
}

static void *drain_pipe(void *arg)
{
   int fd = *(int *)arg;
   char buf[4096];
   ssize_t n;
   while ((n = read(fd, buf, sizeof(buf))) > 0)
      assert(__real_write(STDOUT_FILENO, buf, n) == n);
   assert(n == 0);
   return NULL;
}

int main(int argc, char **argv)
{
   assert(argc >= 3);
   mode = argv[1];
   seed = argc > 3 ? strtoul(argv[3], NULL, 0) : 1;
   int flags = O_WRONLY | O_CREAT | O_TRUNC;
   if (strcmp(mode, "nonappend")) flags |= O_APPEND;
   int log = open(argv[2], flags, 0600);
   assert(log >= 0);
   assert(dup2(log, STDERR_FILENO) == STDERR_FILENO);
   close(log);
   setbuf(stderr, NULL); /* Same unbuffered native stderr as Wine init_options. */
   if (!strcmp(mode, "nonappend") || !strcmp(mode, "nonappend-after-init") ||
       !strcmp(mode, "unsupported-null") || !strcmp(mode, "unsupported-type") ||
       !strcmp(mode, "getfl-error") || !strcmp(mode, "fstat-error") ||
       !strcmp(mode, "flags-max") || !strcmp(mode, "format-empty")) {
      if (!strcmp(mode, "nonappend"))
         assert(!(__real_fcntl64(STDERR_FILENO, F_GETFL) & O_APPEND));
      if (!strcmp(mode, "unsupported-null")) {
         int null = open("/dev/null", O_WRONLY);
         assert(null >= 0 && dup2(null, STDERR_FILENO) == STDERR_FILENO);
         close(null);
      }
      test_rejected_sink();
      return 0;
   }
   int p[2];
   pthread_t drain, client;
   bool pipe_mode = !strncmp(mode, "pipe", 4);
   if (pipe_mode) {
      assert(!pipe(p));
      assert(dup2(p[1], STDERR_FILENO) == STDERR_FILENO);
      close(p[1]);
      peer_fd = dup(STDERR_FILENO);
      assert(!pthread_create(&drain, NULL, drain_pipe, &p[0]));
   } else {
      /* Separate open file description, not dup, for the append competition. */
      peer_fd = open(argv[2], O_WRONLY | O_APPEND);
   }
   assert(peer_fd >= 0);
   bool nominal = !strcmp(mode, "append") || !strcmp(mode, "pipe");
   handshakes = nominal;
   if (nominal) assert(!pthread_create(&client, NULL, client_writer, NULL));
   struct kk_descriptor_stats s = {0};
   kk_descriptor_stats_init(&s);
   if (!strcmp(mode, "stress"))
      assert(!pthread_create(&client, NULL, stress_writer, NULL));
   if (!strcmp(mode, "max")) {
      s.generation = s.init_ns = s.frames = s.entered = s.completed = UINT64_MAX;
      s.snapshot = UINT64_MAX - 1;
      s.overflow = 1;
      s.report_clock_errors = UINT64_MAX;
      for (unsigned op = 0; op < KK_DESCRIPTOR_OP_COUNT; op++)
         for (unsigned f = 0; f < KK_DESCRIPTOR_FIELD_COUNT; f++)
            s.values[op][f] = UINT64_MAX;
   }
   armed = 1;
   target = !strcmp(mode, "newline-short") ? 10 : 1;
   errno = EDOM;
   kk_descriptor_stats_log(&s, 0, !nominal);
   assert(errno == EDOM);
   if (nominal) {
      s.last_log_ns = 0;
      kk_descriptor_stats_log(&s, 1, true);
      assert(!pthread_mutex_lock(&lock));
      done = 1;
      assert(!pthread_cond_broadcast(&changed));
      assert(!pthread_mutex_unlock(&lock));
      assert(!pthread_join(client, NULL));
   } else if (!strcmp(mode, "stress")) {
      for (unsigned i = 0; i < 400; i++) kk_descriptor_stats_log(&s, 0, true);
      assert(!pthread_join(client, NULL));
   } else if (strcmp(mode, "max") && strcmp(mode, "eintr") &&
              strcmp(mode, "pipe-exact") && strcmp(mode, "pipe-max")) {
      int before = calls, formats_before = format_calls;
      int stats_before = stat_calls, flags_before = flag_calls, pipes_before = pipe_calls;
      kk_descriptor_stats_log(&s, 0, true);
      /* A failed device never retries a suffix or emits another snapshot. */
      assert(calls == before && format_calls == formats_before);
      assert(stat_calls == stats_before && flag_calls == flags_before && pipe_calls == pipes_before);
      if (strncmp(mode, "pipe", 4)) assert(injected);
      assert(s.emission_failed && poison_writes == 1);
      assert(poison_formats == formats_before && errno == EDOM);
      if (!strcmp(mode, "eintr-limit")) assert(injected == 3 && calls == 4);
   } else if (!strcmp(mode, "eintr")) {
      assert(injected == 2 && calls == 12);
   }
   if (!pipe_mode) printf("reason-case=%s rowlen=%zu poisonlen=%zu formats=%d stat=%d flags=%d pipe=%d\n",
          mode, row_length, poison_length, format_calls, stat_calls, flag_calls, pipe_calls);
   close(peer_fd);
   if (pipe_mode) {
      close(STDERR_FILENO);
      assert(!pthread_join(drain, NULL));
      close(p[0]);
   }
   return 0;
}
