/* SPDX-License-Identifier: MIT
 * PLA-72: exercise the real once-only environment parser in fresh children.
 * No Metal libraries are generated (in particular none with MSL 4.1).
 */
#include "kk_debug.h"
#include "util/macros.h"
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void)
{
   const uint64_t hazards = KK_EXPERIMENTAL_NO_FP_PRESERVE |
      KK_EXPERIMENTAL_FP_PRECISE_ONLY | KK_EXPERIMENTAL_UBO_UNBOUNDED |
      KK_EXPERIMENTAL_NARROW_BARRIERS | KK_EXPERIMENTAL_DS_DONT_CARE;
   const struct {
      const char *experimental, *unsafe;
      uint64_t expected_hazards;
   } cases[] = {
      {NULL, NULL, 0},
      {NULL, "ubo_unbounded", 0},
      {"all", NULL, 0},
      {"all", "ubo_unbounded", 0},
      {"ubo_unbounded", NULL, 0},
      {"ubo_unbounded", "all", 0},
      {"ubo_unbounded", "1", 0},
      {"ubo_unbounded", "ubo_unbounded_extra", 0},
      {"ubo_unbounded", "ubo_unbounded", KK_EXPERIMENTAL_UBO_UNBOUNDED},
      {"all,ubo_unbounded", NULL, 0},
      {"all,ubo_unbounded", "ubo_unbounded", KK_EXPERIMENTAL_UBO_UNBOUNDED},
      {"all,no_fp_preserve", NULL, KK_EXPERIMENTAL_NO_FP_PRESERVE},
      {"all,fp_precise_only", NULL, KK_EXPERIMENTAL_FP_PRECISE_ONLY},
      {"all,narrow_barriers", NULL, KK_EXPERIMENTAL_NARROW_BARRIERS},
      {"all,ds_dont_care", NULL, KK_EXPERIMENTAL_DS_DONT_CARE},
      {"no_fp_preserve,fp_precise_only,narrow_barriers,ds_dont_care", NULL,
       hazards & ~KK_EXPERIMENTAL_UBO_UNBOUNDED},
      {"not_ubo_unbounded,ubo_unbounded_extra", "ubo_unbounded", 0},
   };
   for (unsigned i = 0; i < ARRAY_SIZE(cases); i++) {
      pid_t child = fork();
      assert(child >= 0);
      if (!child) {
         unsetenv("MESA_KK_BATCH2");
         unsetenv("MESA_KK_DEBUG");
         if (cases[i].experimental)
            setenv("MESA_KK_EXPERIMENTAL", cases[i].experimental, 1);
         else
            unsetenv("MESA_KK_EXPERIMENTAL");
         if (cases[i].unsafe)
            setenv("MESA_KK_UNSAFE", cases[i].unsafe, 1);
         else
            unsetenv("MESA_KK_UNSAFE");
         kk_process_debug_variable();
         assert((kk_mesa_experimental_flags & hazards) == cases[i].expected_hazards);
         if (cases[i].experimental && !strncmp(cases[i].experimental, "all", 3))
            assert(kk_mesa_experimental_flags & KK_EXPERIMENTAL_ROOT_TABLE_LOADS);
         _exit(0);
      }
      int status;
      assert(waitpid(child, &status, 0) == child);
      assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
   }
   puts("ok kk experimental parser: 17 cases (wildcards, explicit hazards, independent unsafe consent)");
   return 0;
}
