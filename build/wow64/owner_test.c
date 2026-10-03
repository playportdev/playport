/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

/* This seam tests selection/copying, not Wine layout or TEB allocation. */
typedef struct { uint16_t Machine; void *TransferAddress; } SECTION_IMAGE_INFORMATION;
typedef int BOOL;
static const BOOL is_win64 = 1;
static const uint16_t native_machine = 0xaa64;
static inline BOOL is_machine_64bit(uint16_t machine)
{
    return machine == 0x8664 || machine == 0xaa64;
}
#include "ios_process_image.h"
struct thread_data { void *ios_startup_image; };
static _Thread_local struct thread_data test_data;
static struct thread_data *get_thread_data(void) { return &test_data; }
static _Thread_local void *current_owner;
static SECTION_IMAGE_INFORMATION main_image_info = {0x8664, (void *)(uintptr_t)0x140001000};
static void *main_module = (void *)(uintptr_t)0x140000000;
static void *ios_jit_current_peb(void) { return current_owner; }

const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void)
{
    struct ios_startup_image *startup = ios_startup_image_for_owner(current_owner);
    return startup ? &startup->info : &main_image_info;
}
/* Generated from the actual patches: the write-slot implementations and
 * Wine's is_wow64(), including the WINE_IOS/non-iOS branches. */
#include "owner_api.h"

static pthread_barrier_t barrier;
static int owners[2];

static void *child(void *arg)
{
    struct ios_startup_image startup = {0};
    void *owner = arg;
    current_owner = owner;
    assert(!ios_begin_startup_image(owner, &main_image_info)); /* no storage */
    test_data.ios_startup_image = &startup;
    assert(!ios_begin_startup_image(NULL, &main_image_info));
    assert(ios_begin_startup_image(owner, &main_image_info));
    assert(!ios_begin_startup_image(owner, &main_image_info)); /* no nesting */
    assert(ios_main_image_info_slot() != &main_image_info);
    assert(ios_main_module_slot() != &main_module);
    assert(!*ios_main_module_slot()); /* never inherits the session module */
    assert(!ios_startup_image_for_owner(NULL));
    assert(!ios_startup_image_for_owner(owner == &owners[0] ? &owners[1] : &owners[0]));
    ios_main_image_info_slot()->Machine = 0x14c;
    ios_main_image_info_slot()->TransferAddress = owner;
    *ios_main_module_slot() = owner;
    assert(is_wow64());
    pthread_barrier_wait(&barrier);
    pthread_barrier_wait(&barrier);
    assert(ios_cur_image_info()->Machine == 0x14c);
    assert(ios_cur_image_info()->TransferAddress == owner);
    assert(*ios_main_module_slot() == owner);
    if (owner == &owners[0]) return NULL; /* failed startup: no end/restore */
    ios_end_startup_image();
    test_data.ios_startup_image = NULL;
    assert(!ios_startup_image_for_owner(owner));
    assert(ios_main_image_info_slot() == &main_image_info);
    assert(ios_main_module_slot() == &main_module);
    return NULL;
}

int main(void)
{
    pthread_t threads[2];
    assert(!ios_startup_image_for_owner(&owners[0]));
    assert(ios_main_image_info_slot() == &main_image_info);
    assert(ios_main_module_slot() == &main_module);
    assert(!is_wow64());
    assert(!pthread_barrier_init(&barrier, NULL, 3));
    for (int i = 0; i < 2; i++) assert(!pthread_create(&threads[i], NULL, child, &owners[i]));
    pthread_barrier_wait(&barrier);
    /* Two i386 startups must not flip an ARM64EC session's identity. */
    assert(!is_wow64());
    assert(main_image_info.Machine == 0x8664);
    assert(main_image_info.TransferAddress == (void *)(uintptr_t)0x140001000);
    assert(main_module == (void *)(uintptr_t)0x140000000);
    assert(!ios_startup_image_for_owner(&owners[0]));
    pthread_barrier_wait(&barrier);
    for (int i = 0; i < 2; i++) assert(!pthread_join(threads[i], NULL));
    assert(!is_wow64());
    assert(!pthread_barrier_destroy(&barrier));
    puts("WoW64 owner: private slots, concurrent startups, NULL/wrong owner, nesting and failed-startup isolation");
    return 0;
}
