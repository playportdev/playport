/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A Linux implicit Vulkan layer for replaying a Fossilize database on a
 * driver that lacks a feature or property Fossilize gates SPIR-V modules on,
 * where the driver compiles those modules anyway. Fossilize refuses a module
 * that declares a capability the device does not report ("Capability N is
 * not supported on this device, ignoring shader module"); KosmicKrisp checks
 * no capabilities when it creates a module, and spirv_to_nir only warns about
 * the ones below. So the layer reports, to the replayer only:
 *
 *    shaderStorageImageMultisample   ImageMSArray (48)
 *    every float-controls property   DenormPreserve, DenormFlushToZero,
 *      (Float16/32/64, independence  SignedZeroInfNanPreserve, RoundingModeRTE,
 *      ALL)                          RoundingModeRTZ (4464-4468)
 *
 * At vkCreateDevice it clears the 1.0 feature again where the driver does not
 * report it, so the driver sees its own truth, and restores the replayer's
 * structs afterwards (Fossilize keeps its feature filter in them). Properties
 * are never enabled, so they need nothing there. Pipeline-level gates (sample
 * counts, formats, required subgroup sizes) are left as the driver reports.
 * A workstation tool for build/mesa-host-test/run-replay.sh
 * --bypass-feature-gate; not shipped.
 *
 *    PP_REPLAY_GATE_OUT  directory for replay-gate.PID.log, which names each
 *                        module that declares a bypassed capability the
 *                        driver does not report, and spv/HASH.spv, those
 *                        modules (FNV-1a of the code).
 *                        Unset: nothing is written.
 *
 * The manifest, replay-gate.json, enables it with ENABLE_PP_REPLAY_GATE=1.
 */
#define _GNU_SOURCE
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

static PFN_vkGetInstanceProcAddr next_gipa;
static PFN_vkGetDeviceProcAddr next_gdpa;
static VkInstance g_inst;
static PFN_vkGetPhysicalDeviceFeatures n_GetFeatures;
static PFN_vkGetPhysicalDeviceFeatures2 n_GetFeatures2;
static PFN_vkGetPhysicalDeviceProperties2 n_GetProps2;
static PFN_vkCreateShaderModule n_CreateShaderModule;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *logf_;
static char outdir[1024];

static void mkdir_p(const char *dir) {
    char p[1200];
    snprintf(p, sizeof p, "%s", dir);
    for (char *s = p + 1; *s; s++)
        if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
    mkdir(p, 0755);
}

// The log, or NULL when PP_REPLAY_GATE_OUT is unset. Called with mu held.
static FILE *gate_log(void) {
    static int tried;
    if (tried) return logf_;
    tried = 1;
    const char *d = getenv("PP_REPLAY_GATE_OUT");
    if (!d || !*d) return NULL;
    snprintf(outdir, sizeof outdir, "%s", d);
    char p[1200];
    snprintf(p, sizeof p, "%s/spv", outdir); mkdir_p(p);
    snprintf(p, sizeof p, "%s/replay-gate.%d.log", outdir, (int)getpid());
    logf_ = fopen(p, "a");
    if (logf_) setvbuf(logf_, NULL, _IOLBF, 0);
    return logf_;
}
#define L(...) do { pthread_mutex_lock(&mu); FILE *f_ = gate_log(); if (f_) fprintf(f_, __VA_ARGS__); pthread_mutex_unlock(&mu); } while (0)

/* The SPIR-V capabilities the reports below cover, by name for the log, and
 * whether the device's driver reports it itself (set at vkCreateDevice: the
 * feature, or the property at any float width). */
static struct { uint32_t cap; const char *name; int driver_has; } bypassed_caps[] = {
    {48, "ImageMSArray", 0},
    {4464, "DenormPreserve", 0},
    {4465, "DenormFlushToZero", 0},
    {4466, "SignedZeroInfNanPreserve", 0},
    {4467, "RoundingModeRTE", 0},
    {4468, "RoundingModeRTZ", 0},
};
#define NCAPS (sizeof bypassed_caps / sizeof *bypassed_caps)

/* ---------------- what the replayer sees ---------------- */
static void report_features10(VkPhysicalDeviceFeatures *f) { f->shaderStorageImageMultisample = VK_TRUE; }

#define FLOAT_CONTROLS_ALL(p) do { \
    p->shaderSignedZeroInfNanPreserveFloat16 = p->shaderSignedZeroInfNanPreserveFloat32 = p->shaderSignedZeroInfNanPreserveFloat64 = VK_TRUE; \
    p->shaderDenormPreserveFloat16 = p->shaderDenormPreserveFloat32 = p->shaderDenormPreserveFloat64 = VK_TRUE; \
    p->shaderDenormFlushToZeroFloat16 = p->shaderDenormFlushToZeroFloat32 = p->shaderDenormFlushToZeroFloat64 = VK_TRUE; \
    p->shaderRoundingModeRTEFloat16 = p->shaderRoundingModeRTEFloat32 = p->shaderRoundingModeRTEFloat64 = VK_TRUE; \
    p->shaderRoundingModeRTZFloat16 = p->shaderRoundingModeRTZFloat32 = p->shaderRoundingModeRTZFloat64 = VK_TRUE; \
    p->denormBehaviorIndependence = p->roundingModeIndependence = VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_ALL; } while (0)

static void VKAPI_CALL g_GetFeatures(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) { n_GetFeatures(pd, f); report_features10(f); }
static void VKAPI_CALL g_GetFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) { n_GetFeatures2(pd, f); report_features10(&f->features); }
static void VKAPI_CALL g_GetProps2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    n_GetProps2(pd, p);
    for (VkBaseOutStructure *h = (VkBaseOutStructure *)p->pNext; h; h = h->pNext) {
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES) { VkPhysicalDeviceVulkan12Properties *q = (void *)h; FLOAT_CONTROLS_ALL(q); }
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES) { VkPhysicalDeviceFloatControlsProperties *q = (void *)h; FLOAT_CONTROLS_ALL(q); }
    }
}

/* ---------------- instance ---------------- */
static VkResult VKAPI_CALL g_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out) {
    VkLayerInstanceCreateInfo *li = (VkLayerInstanceCreateInfo *)ci->pNext;
    while (li && !(li->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && li->function == VK_LAYER_LINK_INFO))
        li = (VkLayerInstanceCreateInfo *)li->pNext;
    if (!li) return VK_ERROR_INITIALIZATION_FAILED;
    next_gipa = li->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    li->u.pLayerInfo = li->u.pLayerInfo->pNext;
    VkResult r = ((PFN_vkCreateInstance)next_gipa(NULL, "vkCreateInstance"))(ci, a, out);
    if (r == VK_SUCCESS) {
        g_inst = *out;
        n_GetFeatures = (PFN_vkGetPhysicalDeviceFeatures)next_gipa(*out, "vkGetPhysicalDeviceFeatures");
        n_GetFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)next_gipa(*out, "vkGetPhysicalDeviceFeatures2");
        if (!n_GetFeatures2) n_GetFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)next_gipa(*out, "vkGetPhysicalDeviceFeatures2KHR");
        n_GetProps2 = (PFN_vkGetPhysicalDeviceProperties2)next_gipa(*out, "vkGetPhysicalDeviceProperties2");
        if (!n_GetProps2) n_GetProps2 = (PFN_vkGetPhysicalDeviceProperties2)next_gipa(*out, "vkGetPhysicalDeviceProperties2KHR");
    }
    return r;
}

/* ---------------- device: the driver's own truth ---------------- */
static VkResult VKAPI_CALL g_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *out) {
    VkLayerDeviceCreateInfo *li = (VkLayerDeviceCreateInfo *)ci->pNext;
    while (li && !(li->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && li->function == VK_LAYER_LINK_INFO))
        li = (VkLayerDeviceCreateInfo *)li->pNext;
    if (!li) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = li->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    next_gdpa = li->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    li->u.pLayerInfo = li->u.pLayerInfo->pNext;

    VkPhysicalDeviceFeatures driver;
    n_GetFeatures(pd, &driver);
    int strip = !driver.shaderStorageImageMultisample;
    VkPhysicalDeviceFloatControlsProperties fc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES};
    VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &fc};
    n_GetProps2(pd, &p2);
    int has[NCAPS] = {
        driver.shaderStorageImageMultisample,
        fc.shaderDenormPreserveFloat16 || fc.shaderDenormPreserveFloat32 || fc.shaderDenormPreserveFloat64,
        fc.shaderDenormFlushToZeroFloat16 || fc.shaderDenormFlushToZeroFloat32 || fc.shaderDenormFlushToZeroFloat64,
        fc.shaderSignedZeroInfNanPreserveFloat16 || fc.shaderSignedZeroInfNanPreserveFloat32 || fc.shaderSignedZeroInfNanPreserveFloat64,
        fc.shaderRoundingModeRTEFloat16 || fc.shaderRoundingModeRTEFloat32 || fc.shaderRoundingModeRTEFloat64,
        fc.shaderRoundingModeRTZFloat16 || fc.shaderRoundingModeRTZFloat32 || fc.shaderRoundingModeRTZFloat64,
    };
    for (size_t k = 0; k < NCAPS; k++) bypassed_caps[k].driver_has = has[k];
    VkDeviceCreateInfo c = *ci;
    VkPhysicalDeviceFeatures f10;
    VkBool32 asked = VK_FALSE;
    if (strip && ci->pEnabledFeatures) {
        f10 = *ci->pEnabledFeatures;
        asked |= f10.shaderStorageImageMultisample;
        f10.shaderStorageImageMultisample = VK_FALSE;
        c.pEnabledFeatures = &f10;
    }
    VkPhysicalDeviceFeatures2 *f2 = NULL;
    VkBool32 f2_had = VK_FALSE;
    for (VkBaseOutStructure *h = (VkBaseOutStructure *)ci->pNext; strip && h; h = h->pNext)
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) {
            f2 = (VkPhysicalDeviceFeatures2 *)h;
            f2_had = f2->features.shaderStorageImageMultisample;
            asked |= f2_had;
            f2->features.shaderStorageImageMultisample = VK_FALSE;
        }
    VkResult r = ((PFN_vkCreateDevice)gipa(g_inst, "vkCreateDevice"))(pd, &c, a, out);
    if (f2) f2->features.shaderStorageImageMultisample = f2_had;
    L("device result %d: shaderStorageImageMultisample asked %u, %s\n", r, asked,
      strip ? "cleared (the driver does not report it)" : "passed (the driver reports it)");
    if (r == VK_SUCCESS) n_CreateShaderModule = (PFN_vkCreateShaderModule)next_gdpa(*out, "vkCreateShaderModule");
    return r;
}

static uint64_t fnv(const void *p, size_t n) {
    const unsigned char *c = p; uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= c[i]; h *= 1099511628211ull; }
    return h;
}

// Logs and saves a module that declares a bypassed capability its driver does
// not report (OpCapability comes first, after the five-word header).
static void note_module(const VkShaderModuleCreateInfo *ci) {
    const uint32_t *w = ci->pCode;
    size_t n = ci->codeSize / 4;
    char caps[256] = "";
    size_t used = 0;
    for (size_t i = 5; i < n;) {
        uint32_t op = w[i] & 0xffff, len = w[i] >> 16;
        if (op != 17 /* OpCapability */ || len < 2 || i + len > n) break;
        for (size_t k = 0; k < NCAPS; k++)
            if (w[i + 1] == bypassed_caps[k].cap && !bypassed_caps[k].driver_has && used < sizeof caps)
                used += snprintf(caps + used, sizeof caps - used, "%s%s", used ? "," : "", bypassed_caps[k].name);
        i += len;
    }
    if (!used) return;
    uint64_t h = fnv(ci->pCode, ci->codeSize);
    pthread_mutex_lock(&mu);
    FILE *lf = gate_log();
    if (lf) {
        fprintf(lf, "module %016llx %s\n", (unsigned long long)h, caps);
        char p[1200];
        snprintf(p, sizeof p, "%s/spv/%016llx.spv", outdir, (unsigned long long)h);
        struct stat st;
        if (stat(p, &st) != 0) { FILE *f = fopen(p, "wb"); if (f) { fwrite(ci->pCode, 1, ci->codeSize, f); fclose(f); } }
    }
    pthread_mutex_unlock(&mu);
}

static VkResult VKAPI_CALL g_CreateShaderModule(VkDevice d, const VkShaderModuleCreateInfo *ci, const VkAllocationCallbacks *a, VkShaderModule *m) {
    note_module(ci);
    return n_CreateShaderModule(d, ci, a, m);
}

/* ---------------- dispatch ---------------- */
EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ppgate_GetDeviceProcAddr(VkDevice d, const char *n) {
    if (!strcmp(n, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)ppgate_GetDeviceProcAddr;
    if (!strcmp(n, "vkCreateShaderModule") && n_CreateShaderModule) return (PFN_vkVoidFunction)g_CreateShaderModule;
    return next_gdpa(d, n);
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ppgate_GetInstanceProcAddr(VkInstance i, const char *n) {
    if (!strcmp(n, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)ppgate_GetInstanceProcAddr;
    if (!strcmp(n, "vkCreateInstance")) return (PFN_vkVoidFunction)g_CreateInstance;
    if (!strcmp(n, "vkCreateDevice")) return (PFN_vkVoidFunction)g_CreateDevice;
    if (!strcmp(n, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)ppgate_GetDeviceProcAddr;
    if (i && n_GetFeatures && !strcmp(n, "vkGetPhysicalDeviceFeatures")) return (PFN_vkVoidFunction)g_GetFeatures;
    if (i && n_GetFeatures2 && (!strcmp(n, "vkGetPhysicalDeviceFeatures2") || !strcmp(n, "vkGetPhysicalDeviceFeatures2KHR")))
        return (PFN_vkVoidFunction)g_GetFeatures2;
    if (i && n_GetProps2 && (!strcmp(n, "vkGetPhysicalDeviceProperties2") || !strcmp(n, "vkGetPhysicalDeviceProperties2KHR")))
        return (PFN_vkVoidFunction)g_GetProps2;
    return next_gipa ? next_gipa(i, n) : NULL;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL ppgate_NegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
    if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
    v->pfnGetInstanceProcAddr = ppgate_GetInstanceProcAddr;
    v->pfnGetDeviceProcAddr = ppgate_GetDeviceProcAddr;
    v->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
