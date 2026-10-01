// SPDX-License-Identifier: GPL-3.0-or-later
// The JIT helper extension's entry point. xtool links an extension with
// `-e _NSExtensionMain`; this definition, in the executable, is the one the
// entry point names, and it hands on to Foundation's after one change.
//
// The app passes its anonymous listener's NSXPCListenerEndpoint inside the
// extension request's NSExtensionItem userInfo. The extension side decodes
// that item with an allow-list of property-list classes, which refuses the
// endpoint, so the helper would never learn where to connect. The helper
// process only ever talks to the app that started it, so the class check is
// turned off for this process before the request is decoded.

#include <dlfcn.h>
#include <objc/runtime.h>

static BOOL allow_class(id self, SEL cmd, Class cls, id key, BOOL invocations)
{
    (void)self, (void)cmd, (void)cls, (void)key, (void)invocations;
    return YES;
}

__attribute__((used, visibility("default")))
int NSExtensionMain(int argc, char *argv[])
{
    Class decoder = objc_getClass("NSXPCDecoder");
    Method m = decoder ? class_getInstanceMethod(decoder, sel_registerName("_validateAllowedClass:forKey:allowingInvocations:")) : NULL;
    if (m) method_setImplementation(m, (IMP)allow_class);
    int (*foundation_main)(int, char **) = (int (*)(int, char **))dlsym(RTLD_NEXT, "NSExtensionMain");
    return foundation_main(argc, argv);
}
