/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Real generated mock bridge: deferred completion must not reenter a driver's
 * locked commit path, and every copied callback must drain exactly once. */
#include "kosmickrisp/bridge/mtl_bridge.h"
#include "kosmickrisp/bridge/mtl_command_queue.h"
#include "kosmickrisp/bridge/mtl_sync.h"
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned completed;
static bool committing;

static void feedback(struct mtl_feedback_data *data)
{
   assert(!committing); /* The old synchronous mock fails here, not a hang. */
   assert(*(unsigned *)data->user_data == completed);
   assert(data->error == MTL_COMMAND_QUEUE_ERROR_NONE);
   completed++;
}

int main(void)
{
   assert(!setenv("KK_MOCK_DEFER_FEEDBACK", "1", 1));
   mtl_command_queue *queue = mtl_new_command_queue(NULL);
   mtl_commit_options *options = mtl_new_commit_options();
   mtl_event *event = mtl_new_event(NULL);
   unsigned order[] = {0, 1, 2, 3};
   for (unsigned i = 0; i < 2; i++) {
      mtl_commit_options_add_feedback_handler(options, feedback, &order[i]);
      committing = true;
      mtl_command_queue_commit(queue, NULL, 0, options);
      committing = false;
      assert(completed == 0);
   }
   /* Changing/releasing options cannot change the queued feedback payload. */
   mtl_commit_options_add_feedback_handler(options, NULL, NULL);
   mtl_release(options);
   mtl_signal_event(queue, event, 7);
   assert(completed == 2);
   assert(mtl_shared_event_get_signaled_value((mtl_shared_event *)event) == 7);
   mtl_signal_event(queue, event, 8);
   assert(completed == 2);
   options = mtl_new_commit_options();
   mtl_commit_options_add_feedback_handler(options, feedback, &order[2]);
   mtl_command_queue_commit(queue, NULL, 0, options);
   assert(completed == 2);
   mtl_release(queue); /* Also drains any pending tail, before handle teardown. */
   assert(completed == 3);
   queue = mtl_new_command_queue(NULL);
   unsetenv("KK_MOCK_DEFER_FEEDBACK");
   mtl_commit_options_add_feedback_handler(options, feedback, &order[3]);
   mtl_command_queue_commit(queue, NULL, 0, options);
   assert(completed == 4); /* Historical default remains synchronous. */
   mtl_release(options);
   mtl_release(event);
   mtl_release(queue);
   puts("ok mock feedback: deferred FIFO, copied payload, exactly-once signal/release drain, synchronous default");
   return 0;
}
