/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Link the actual kk_debug.c. Linker wrappers are host-only syscall/stdio
 * seams; the independent writer never takes stderr's FILE lock. */
#include "kk_descriptor_stats.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
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
int __wrap_fprintf(FILE *, const char *, ...);
ssize_t __wrap_write(int, const void *, size_t);
int __wrap_vsnprintf(char *, size_t, const char *, va_list);
long __wrap_fpathconf(int, int);
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int requested, completed, done, peer_fd, handshakes;
static const char peer[] = "info:  [client-like] independent raw writer\n";
static int armed, calls, target, injected, format_calls;
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
   if (armed) {
      calls++;
      if ((!strcmp(mode, "eintr") && calls <= 2) ||
          (!strcmp(mode, "eintr-limit") && calls <= 3)) {
         injected++;
         errno = EINTR;
         return -1;
      }
      if (calls == target) {
         if (!strcmp(mode, "write-error")) {
            injected++;
            errno = EIO;
            return -1;
         }
         if (!strcmp(mode, "short") || !strcmp(mode, "newline-short")) {
            injected++;
            size_t n = !strcmp(mode, "short") ? len / 2 : len - 1;
            return __real_write(fd, buf, n);
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
   if (armed && ++format_calls == 2) {
      if (!strcmp(mode, "format-error")) { injected++; return -1; }
      if (!strcmp(mode, "format-overflow")) { injected++; return (int)size; }
   }
   return __real_vsnprintf(buf, size, fmt, ap);
}

long __wrap_fpathconf(int fd, int name)
{
   if (armed && !strcmp(mode, "pipe-small") && name == _PC_PIPE_BUF)
      return 512;
   return __real_fpathconf(fd, name);
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
   int log = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0600);
   assert(log >= 0);
   assert(dup2(log, STDERR_FILENO) == STDERR_FILENO);
   close(log);
   setbuf(stderr, NULL); /* Same unbuffered native stderr as Wine init_options. */
   int p[2];
   pthread_t drain, client;
   bool pipe_mode = !strcmp(mode, "pipe") || !strcmp(mode, "pipe-small");
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
   kk_descriptor_stats_log(&s, 0, !nominal);
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
   } else if (strcmp(mode, "max") && strcmp(mode, "eintr")) {
      int before = calls, formats_before = format_calls;
      kk_descriptor_stats_log(&s, 0, true);
      /* A failed device never retries a suffix or emits another snapshot. */
      assert(calls == before && format_calls == formats_before);
      if (strcmp(mode, "pipe-small")) assert(injected);
      if (!strcmp(mode, "eintr-limit")) assert(injected == 3 && calls == 4);
   } else if (!strcmp(mode, "eintr")) {
      assert(injected == 2 && calls == 12);
   }
   close(peer_fd);
   if (pipe_mode) {
      close(STDERR_FILENO);
      assert(!pthread_join(drain, NULL));
      close(p[0]);
   }
   return 0;
}
