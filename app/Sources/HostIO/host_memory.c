/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * host_memory.c — the app's memory limit and its signature's entitlements
 * (host_io.h), for MemoryLimit.swift.
 *
 * The limit is what os_proc_available_memory() leaves plus the phys footprint
 * already used: the sum DXMT's video budget also takes (patches/dxmt-port 0041).
 * The entitlement comes from Security's SecTask, which the iOS SDK does not
 * declare, so it is looked up at run time; an entitlement every signed app
 * has (application-identifier) tells an absent value from one that cannot be
 * read.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/proc.h>

#include "host_io.h"

int host_memory_read(host_memory *out)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    out->available = (uint64_t)os_proc_available_memory();
    out->footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return -1;
    out->footprint = info.phys_footprint;
    return 0;
}

typedef CFTypeRef (*sectask_create_fn)(CFAllocatorRef);
typedef CFTypeRef (*sectask_value_fn)(CFTypeRef, CFStringRef, CFErrorRef *);

/* 1 when the entitlement's value is true, 0 when absent or not true, -1 when unreadable. */
static int entitlement_value(sectask_value_fn value, CFTypeRef task, const char *name)
{
    CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CFTypeRef v;
    int r;

    if (!key) return -1;
    v = value(task, key, NULL);
    CFRelease(key);
    if (!v) return 0;
    r = CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)v) : 1;
    CFRelease(v);
    return r;
}

int host_entitlement(const char *name)
{
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    sectask_create_fn create;
    sectask_value_fn value;
    CFTypeRef task;
    int r;

    if (!security) return -1;
    create = (sectask_create_fn)dlsym(security, "SecTaskCreateFromSelf");
    value = (sectask_value_fn)dlsym(security, "SecTaskCopyValueForEntitlement");
    if (!create || !value || !(task = create(NULL))) return -1;
    r = entitlement_value(value, task, name);
    if (r == 0 && entitlement_value(value, task, "application-identifier") == 0) r = -1;
    CFRelease(task);
    return r;
}
