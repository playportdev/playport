#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the actual patch's arithmetic header, not a parallel implementation."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("PLAYPORT_BUILD", REPO / ".work"))
HEADER = "build/ntdll-unix/wow64_window.h"
OWNER_HEADER = "build/ntdll-unix/ios_process_image.h"
OWNER_PATCH = REPO / "patches/madeira-unix/0050-ntdll-isolate-child-startup-image-identity.patch"
IDENTITY_PATCH = REPO / "patches/wine-unix/0008-ntdll-query-owner-WoW64-identity-on-iOS.patch"
VIEWS_HEADER = "build/ntdll-unix/wow64_views.h"
VIEWS_PATCH = REPO / "patches/madeira-unix/0051-ntdll-suballocate-owned-WoW64-window-views.patch"
PAIR_HEADER = "build/ntdll-unix/wow64_pair.h"
PAIR_PATCH = REPO / "patches/madeira-unix/0052-ntdll-bootstrap-owner-local-window-backed-TEB-pairs.patch"
IMAGE_HEADER = "build/ntdll-unix/wow64_image.h"
IMAGE_PATCH = REPO / "patches/madeira-unix/0053-ntdll-map-fixed-i386-images-into-the-owned-window.patch"
PARAMS_HEADER = "build/ntdll-unix/wow64_params.h"
PARAMS_PATCH = REPO / "patches/madeira-unix/0054-ntdll-build-owner-local-window-backed-startup-parame.patch"
PLACEMENT_PATCH = REPO / "patches/madeira-unix/0055-ntdll-place-and-relocate-i386-images-in-guest-space.patch"
VM_PATCH = REPO / "patches/madeira-unix/0056-ntdll-route-owned-window-anonymous-VM-operations.patch"
GAP_PATCH = REPO / "patches/madeira-unix/0057-ntdll-allocate-guest-constrained-VM-in-owner-local-gaps.patch"
QUERY_PATCH = REPO / "patches/madeira-unix/0058-ntdll-query-owner-local-WoW64-window-memory.patch"
SECTION_PATCH = REPO / "patches/madeira-unix/0059-ntdll-route-owned-window-image-sections.patch"
PROTECT_PATCH = REPO / "patches/madeira-unix/0060-ntdll-protect-owned-WoW64-window-pages-per-Wine-page.patch"
LOADER_PATCH = REPO / "patches/madeira-unix/0061-ntdll-start-the-WoW64-child-s-native-loader.patch"
THREADS_PATCH = REPO / "patches/madeira-unix/0073-ntdll-keep-a-WoW64-window-until-its-threads-and-faul.patch"
DC_ATTR_PATCH = REPO / "patches/madeira-unix/0065-ntdll-share-win32u-s-DC_ATTR-arena-with-every-WoW64-.patch"
SIMD_LANE_PATCH = REPO / "patches/madeira-unix/0070-signal-emulate-LD1-and-ST1-lanes-in-the-low-fault-em.patch"
GDI32_DC_ATTR_PATCH = REPO / "patches/wine-pe/0019-gdi32-reach-a-native-DC_ATTR-through-the-WoW64-windo.patch"
VULKAN_PATCH = REPO / "patches/wine-unix/0011-winevulkan-win32u-convert-an-i386-child-s-Vulkan-poi.patch"
GUEST_HEADER = "dlls/wow64/wow64_window.h"
WOW64WIN_PATCH = REPO / "patches/wine-pe/0018-wow64win-convert-audited-win32u-thunks-through-the-i.patch"
CLASS_LOOKUP_PATCH = REPO / "patches/wine-pe/0022-wow64win-audit-the-class-raw-input-hook-display-mode.patch"
FAULT_LOG_PATCH = REPO / "patches/wine-pe/0023-wow64-log-a-windowed-guest-s-faults-with-its-registe.patch"
MESSAGE_PARAMS_PATCH = REPO / "patches/wine-pe/0024-wow64win-preserve-guest-SendMessage-dispatch-paramet.patch"
CLASS_MENU_PATCH = REPO / "patches/wine-pe/0025-wow64win-keep-a-class-s-client-menu-name-in-one-form.patch"
PACKED_CREATESTRUCT_PATCH = REPO / "patches/wine-pe/0027-wow64win-keep-win32u-s-inline-string-marker-in-packe.patch"
GUEST_PATCH = REPO / "patches/wine-pe/0016-wow64-convert-guest-pointers-through-the-iOS-guest-w.patch"
AUDIO_PATCH = REPO / "patches/madeira-unix/0074-audio-give-an-i386-child-the-iOS-audio-driver-throug.patch"
AUDIO_SOURCE = "build/ntdll-unix/audio_null_ios.c"
RESOLVER_PATCH = REPO / "patches/wine-unix/0013-ws2_32-convert-an-i386-child-s-resolver-pointers-thr.patch"
RESOLVER_SOURCES = ("dlls/ws2_32/unixlib.c", "dlls/ntdll/unix/socket.c")


def pin(name):
    """The pins.lock commit of one upstream."""
    for line in (REPO / "pins.lock").read_text().splitlines():
        fields = line.split()
        if fields and fields[0] == name:
            return fields[1]
    raise ValueError(f"pins.lock has no {name}")


def series_patches(*targets):
    for target in targets:
        for name in (REPO / "patches" / target / "series").read_text().splitlines():
            if name and not name.startswith("#"):
                yield REPO / "patches" / target / name


def patched_upstream_files(git_dir, commit, targets, paths, root, include=()):
    """Whole upstream files at a pin with every series patch that touches them.

    Some tests need a file's unchanged functions too, which no patch carries.
    Returns False when the upstream objects are not here (a CI checkout has
    no Madeira submodule and no Wine cache).
    """
    for path in paths:
        show = subprocess.run(["git", "-C", str(git_dir), "show", f"{commit}:{path}"],
                              capture_output=True)
        if show.returncode:
            return False
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_bytes(show.stdout)
    includes = [f"--include={p}" for p in (*paths, *include)]
    for patch in series_patches(*targets):
        text = patch.read_text(errors="replace")
        if any(f"diff --git a/{p} " in text or f"+++ b/{p}\n" in text for p in (*paths, *include)):
            subprocess.run(["git", "-C", str(root), "apply", *includes, str(patch)], check=True)
    return True


def c_function(text, name):
    """One complete static function of a reconstructed source, by name."""
    start = text.index("static ", text.rindex("\n", 0, text.index(name + "(")) + 1)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += {"{": 1, "}": -1}.get(text[end], 0)
        end += 1
    return text[start:end] + "\n"


def run_audio_tests(scratch):
    """0074's WoW64 audio table over the driver's own stream code."""
    with tempfile.TemporaryDirectory(prefix="audio-", dir=scratch) as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q", tmp], check=True)
        if not patched_upstream_files(REPO / "upstream/madeira", pin("madeira"), ["madeira-unix"],
                                      [AUDIO_SOURCE], root,
                                      include=["build/ntdll-unix/audio_wow64_buffer.h",
                                               "build/ntdll-unix/audio_wow64_ios.h"]):
            print("build/wow64/test.py: WoW64 audio skipped (upstream/madeira not checked out)", flush=True)
            return
        s = (root / AUDIO_SOURCE).read_text()
        types = s[s.index("typedef int NTSTATUS;"):s.index("/* ---------------------------------------------------------------- */")]
        stream = s[s.index("struct ios_stream {"):s.index('#include "audio_wow64_buffer.h"')]
        stream = stream[:stream.index("};") + 2]
        midi = s[s.index("struct midi_init_params {"):s.index("/* midi_get_driver:")]
        # The driver defines this twice; the test keeps the later definition.
        (root / "native_types.h").write_text(
            (types + "\n" + stream + "\n" + midi).replace(
                "#define AUDCLNT_E_NOT_INITIALIZED ((HRESULT)0x88890001L)\n", "", 1))
        (root / "native_functions.h").write_text("".join(c_function(s, n) for n in (
            "stream_from_handle", "stream_register", "stream_unregister", "ios_create_stream",
            "ios_release_stream", "ios_get_render_buffer", "ios_release_render_buffer")))
        (root / "native_other_functions.h").write_text(
            'static const char IOS_DEVICE_NAME[] = "ios-null";\n'
            "static uint64_t elapsed_frames(const struct ios_stream *s) { (void)s; return 0; }\n"
            "static uint64_t mach_absolute_time(void) { return 0; }\n"
            "static uint64_t mach_to_ns(uint64_t t) { return t; }\n"
            "static unsigned long long ios_current_tid(void) { return 0; }\n"
            "static NTSTATUS ios_process_attach(void *p) { (void)p; return 0; }\n"
            "static NTSTATUS ios_start(void *p) { ((struct stream_handle_params *)p)->result = S_OK; return 0; }\n"
            "static NTSTATUS ios_stop(void *p) { ((struct stream_handle_params *)p)->result = S_OK; return 0; }\n"
            "static NTSTATUS ios_reset(void *p) { ((struct stream_handle_params *)p)->result = S_OK; return 0; }\n" +
            "".join(c_function(s, n) for n in (
                "ios_main_loop_start", "ios_main_loop_stop", "ios_get_endpoint_ids", "ios_get_capture_buffer",
                "ios_release_capture_buffer", "ios_is_format_supported", "ios_get_mix_format",
                "ios_get_device_period", "ios_get_buffer_size", "ios_get_latency", "ios_get_current_padding",
                "ios_get_next_packet_size", "ios_get_frequency", "ios_get_position", "ios_set_volumes",
                "ios_set_event_handle", "ios_set_sample_rate", "ios_test_connect", "ios_is_started",
                "ios_midi_stub", "ios_midi_message")))
        (root / "vm_api.h").write_text(
            patched_function(AUDIO_PATCH, "NTSTATUS ios_wow64_audio_alloc( void *owner, uintptr_t window, size_t length, void **host )") +
            patched_function(AUDIO_PATCH, "NTSTATUS ios_wow64_audio_free( void *owner, uintptr_t window, void *host )"))
        for name in ("audio_wow64", "audio_vm"):
            exe = root / (name + "-test")
            subprocess.run(["clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                            "-I", str(root / "build/ntdll-unix"), "-I", str(root),
                            str(REPO / "build/wow64" / (name + "_test.c")), "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True)


def run_resolver_tests(scratch):
    """0013's ws2_32 resolver thunks and 0012's socket conversion, from the patched files."""
    with tempfile.TemporaryDirectory(prefix="ws2-", dir=scratch) as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q", tmp], check=True)
        if not patched_upstream_files(BUILD / "cache/wine.git", pin("wine"),
                                      ["wine-port", "wine-valve", "wine-unix"], list(RESOLVER_SOURCES),
                                      root, include=["include/wine/ios_wow64.h"]):
            print("build/wow64/test.py: ws2_32 resolvers skipped (no Wine cache in $PLAYPORT_BUILD/cache)", flush=True)
            return
        ws = (root / RESOLVER_SOURCES[0]).read_text()
        (root / "ws2_resolver_api.h").write_text(
            ws[ws.index("typedef ULONG PTR32;"):ws.rindex("#endif  /* _WIN64 */")])
        (root / "socket_wow64_api.h").write_text(
            c_function((root / RESOLVER_SOURCES[1]).read_text(), "socket_wow64_ptr"))
        exe = root / "ws2-resolver-test"
        cc = ["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
              "-fno-sanitize-recover=all", "-I", str(root / "include"), "-I", str(root)]
        subprocess.run(cc + ["-DWINE_IOS", str(REPO / "build/wow64/ws2_resolver_test.c"), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
        # The conventional WoW64 branch must still compile.
        subprocess.run(cc + ["-fsyntax-only", str(REPO / "build/wow64/ws2_resolver_test.c")], check=True)


def run_packed_createstruct_tests(scratch):
    """0027's packed CREATESTRUCT conversion over 0018's, from the patched user.c."""
    user = "dlls/wow64win/user.c"
    private = "dlls/wow64win/wow64win_private.h"
    with tempfile.TemporaryDirectory(prefix="wow64win-", dir=scratch) as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q", tmp], check=True)
        if not patched_upstream_files(BUILD / "cache/wine.git", pin("wine"),
                                      ["wine-port", "wine-valve", "wine-pe"], [user, private],
                                      root, include=[GUEST_HEADER]):
            print("build/wow64/test.py: packed CREATESTRUCT skipped (no Wine cache in $PLAYPORT_BUILD/cache)", flush=True)
            return
        if "packed_createstruct_64to32" not in PACKED_CREATESTRUCT_PATCH.read_text():
            raise ValueError(f"{PACKED_CREATESTRUCT_PATCH.name}: no packed_createstruct_64to32")
        u = (root / user).read_text()
        p = (root / private).read_text()
        struct32 = u[u.rindex("typedef struct", 0, u.index("} CREATESTRUCT32;")):u.index("} CREATESTRUCT32;")]
        marker = next(line for line in u.splitlines() if line.startswith("#define PACKED_INLINE_STRING "))
        (root / "packed_createstruct_api.h").write_text(
            "".join(c_function(p, n) for n in ("wow64_to_host", "wow64_to_guest",
                                               "wow64_intres_to_host", "wow64_intres_to_guest")) +
            struct32 + "} CREATESTRUCT32;\n" + marker + "\n" +
            c_function(u, "createstruct_64to32") + c_function(u, "packed_createstruct_64to32"))
        exe = root / "packed-createstruct-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / GUEST_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/packed_createstruct_test.c"), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


def patched_function(patch, signature):
    """Recover a complete function's new-side lines from a format-patch hunk.

    These small functions are fully present in their hunks (context + adds).
    Fail if they stop fitting there, rather than silently testing a copy.
    """
    lines = []
    in_hunk = False
    for line in patch.read_text().splitlines():
        if line.startswith("@@ "):
            in_hunk = True
            lines.append("/* hunk boundary */")
        elif line.startswith(("diff --git ", "-- ")):
            in_hunk = False
        elif in_hunk and line.startswith(("+", " ")):
            lines.append(line[1:])
    start = lines.index(signature)
    end = lines.index("}", start)
    body = lines[start:end + 1]
    if "/* hunk boundary */" in body:
        raise ValueError(f"{signature}: function split across patch hunks")
    return "\n".join(body) + "\n"


def evolved_function(original, update, signature):
    """Apply the update's exact edit blocks to a recovered production function.

    Format-patches must keep default context for the pipeline's patch-id gate.
    Later edits need not contain the whole original function in one hunk.
    Require unique, context-anchored matches; unrelated file edits are skipped.
    """
    body = patched_function(original, signature)
    for patch in update if isinstance(update, list) else [update]:
        body = evolve_body(body, patch, signature)
    return body


def evolve_body(body, update, signature):
    """Apply one later patch to an already reconstructed function."""
    lines = update.read_text().splitlines()
    applied = 0
    i = 0
    in_hunk = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("@@ "):
            in_hunk = True
        elif line.startswith(("diff --git ", "-- ")):
            in_hunk = False
        elif in_hunk and line.startswith(("+", "-")):
            before = lines[i - 1][1:] + "\n" if lines[i - 1].startswith(" ") else ""
            old, new = [], []
            while i < len(lines) and lines[i].startswith(("+", "-")):
                (new if lines[i][0] == "+" else old).append(lines[i][1:] + "\n")
                i += 1
            after = lines[i][1:] + "\n" if i < len(lines) and lines[i].startswith(" ") else ""
            old_text = before + "".join(old) + after
            if old_text and old_text in body:
                if body.count(old_text) != 1:
                    raise ValueError(f"{signature}: ambiguous update block")
                body = body.replace(old_text, before + "".join(new) + after, 1)
                applied += 1
            continue
        i += 1
    if not applied:
        raise ValueError(f"{signature}: no update blocks matched")
    return body


def patched_added_statement(patch, prefix):
    """Recover one added conversion statement, rejecting ambiguous matches."""
    matches = [line[1:] for line in patch.read_text().splitlines()
               if line.startswith("+") and not line.startswith("+++")
               and line[1:].strip().startswith(prefix)]
    if len(matches) != 1 or not matches[0].rstrip().endswith(";"):
        raise ValueError(f"{patch.name}: expected one complete added {prefix!r} statement")
    return matches[0] + "\n"


def run_user_conversion_tests(root, guest_header_dir):
    """wow64win's SendMessage return, class-menu conversions and the fault log's stack reads."""
    # The SendMessage helper is complete in its patch; the generic narrowing
    # converter is stubbed by the C test and native dispatch is not run.
    (root / "message_params_api.h").write_text(patched_function(
        MESSAGE_PARAMS_PATCH,
        "static void send_message_params_64to32( const struct win_proc_params *src, struct win_proc_params32 *dst,"))
    # The actual thunk statements, not a copied conversion; the wrappers mock
    # win32u's opaque menu-name storage only.
    menu_helpers = "".join(patched_function(WOW64WIN_PATCH, sig) for sig in (
        "static inline void *wow64_to_host( ULONG guest )",
        "static inline ULONG wow64_to_guest( const void *host )",
        "static inline void *wow64_intres_to_host( ULONG guest )",
        "static inline ULONG wow64_intres_to_guest( const void *host )"))
    (root / "class_menu_api.h").write_text(
        menu_helpers +
        "static void *register_class_menu( UINT **input )\n{\n    UINT *args = *input;\n" +
        patched_added_statement(CLASS_MENU_PATCH, "struct client_menu_name *menu_name =") +
        "    *input = args;\n    return menu_name;\n}\n" +
        "static ULONG get_class_menu( void *menu_name )\n{\n    ULONG value, *menu_name32 = &value;\n" +
        patched_added_statement(CLASS_LOOKUP_PATCH, "*menu_name32 =") +
        "    return value;\n}\n" +
        "static ULONG unregister_class_menu( void *menu_name )\n{\n    ULONG value = 0, *menu_name32 = &value;\n    BOOL ret = TRUE;\n" +
        patched_added_statement(CLASS_LOOKUP_PATCH, "if (ret) *menu_name32 =") +
        "    return value;\n}\n")
    (root / "stack_span_api.h").write_text(patched_function(
        FAULT_LOG_PATCH, "static const ULONG *guest_stack_span( ULONG limit, ULONG base, ULONG addr, ULONG size )"))
    for name in ("message_params", "class_menu", "stack_span"):
        exe = root / (name + "-test")
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str(guest_header_dir), "-I", str(root),
                        str(REPO / "build/wow64" / (name + "_test.c")), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


def main():
    scratch = BUILD / "c-test"
    scratch.mkdir(parents=True, exist_ok=True)
    # A separate scratch index prevents git apply from discovering the enclosing
    # superproject and writing into it. No Madeira checkout needed on CI.
    with tempfile.TemporaryDirectory(prefix="wow64-window-", dir=scratch) as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q", tmp], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={HEADER}",
                        str(REPO / "patches/madeira-unix/0049-ntdll-reserve-an-owned-i386-address-window.patch")], check=True)
        exe = root / "window-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / HEADER).parent),
                        str(REPO / "build/wow64/window_test.c"), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={OWNER_HEADER}",
                        str(OWNER_PATCH)], check=True)
        (root / "owner_api.h").write_text(
            patched_function(OWNER_PATCH, "struct ios_startup_image *ios_get_startup_image(void)") +
            patched_function(OWNER_PATCH, "SECTION_IMAGE_INFORMATION *ios_main_image_info_slot(void)") +
            patched_function(OWNER_PATCH, "void **ios_main_module_slot(void)") +
            patched_function(IDENTITY_PATCH, "static inline BOOL is_wow64(void)"))
        owner_exe = root / "owner-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-DWINE_IOS", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / OWNER_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/owner_test.c"), "-o", str(owner_exe)], check=True)
        subprocess.run([str(owner_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={VIEWS_HEADER}",
                        str(VIEWS_PATCH)], check=True)
        (root / "views_api.h").write_text(
            patched_function(VIEWS_PATCH, "static void ios_wow64_delete_views( uintptr_t base )") +
            patched_function(VIEWS_PATCH, "NTSTATUS ios_wow64_allocate_for_peb( void *owner, uint32_t guest, size_t size,"))
        views_exe = root / "views-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / VIEWS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/views_test.c"), "-o", str(views_exe)], check=True)
        subprocess.run([str(views_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={PAIR_HEADER}",
                        str(PAIR_PATCH)], check=True)
        (root / "pair_api.h").write_text(
            patched_function(PAIR_PATCH, "static NTSTATUS ios_wow64_pair_initial_teb( unsigned int slot )") +
            patched_function(PAIR_PATCH, "static BOOL ios_wow64_restore_initial_teb( unsigned int slot )"))
        pair_exe = root / "pair-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / PAIR_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/pair_test.c"), "-o", str(pair_exe)], check=True)
        subprocess.run([str(pair_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={IMAGE_HEADER}",
                        str(IMAGE_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_protect.h",
                        "--include=build/ntdll-unix/wow64_vprot.h", str(PROTECT_PATCH)], check=True)
        (root / "image_api.h").write_text(
            evolved_function(IMAGE_PATCH, [VM_PATCH, PROTECT_PATCH], "static int mprotect_range( void *base, size_t size, BYTE set, BYTE clear )"))
        image_exe = root / "image-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-DWINE_IOS", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / IMAGE_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/image_test.c"), "-o", str(image_exe)], check=True)
        subprocess.run([str(image_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={PARAMS_HEADER}",
                        str(PARAMS_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={PARAMS_HEADER}",
                        str(GAP_PATCH)], check=True)
        (root / "params_api.h").write_text(
            evolved_function(PARAMS_PATCH, [VM_PATCH, GAP_PATCH, QUERY_PATCH], "static NTSTATUS ios_wow64_init_parameters( PEB *owner, uintptr_t window,"))
        params_exe = root / "params-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / PARAMS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/params_test.c"), "-o", str(params_exe)], check=True)
        subprocess.run([str(params_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply",
                        "--include=build/ntdll-unix/wow64_placement.h",
                        "--include=build/ntdll-unix/image_reloc.h", str(PLACEMENT_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply",
                        "--include=build/ntdll-unix/wow64_placement.h",
                        "--include=build/ntdll-unix/wow64_gap.h", str(GAP_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_placement.h",
                        str(SECTION_PATCH)], check=True)
        placement_exe = root / "placement-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-DWINE_IOS", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / IMAGE_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/placement_test.c"), "-o", str(placement_exe)], check=True)
        subprocess.run([str(placement_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_vm.h",
                        str(VM_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_vm.h",
                        str(GAP_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_vm.h",
                        str(PROTECT_PATCH)], check=True)
        (root / "vm_api.h").write_text(
            evolved_function(VM_PATCH, [GAP_PATCH, PROTECT_PATCH], "static BOOL ios_wow64_route_vm( unsigned int operation, HANDLE process, void **addr,") +
            patched_function(LOADER_PATCH, "NTSTATUS ios_wow64_alloc_stack32( void *owner, SIZE_T reserve_size, SIZE_T commit_size,"))
        vm_exe = root / "vm-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / VIEWS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/vm_test.c"), "-o", str(vm_exe)], check=True)
        subprocess.run([str(vm_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_query.h",
                        str(QUERY_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_query.h",
                        "--include=build/ntdll-unix/wow64_section.h",
                        "--include=build/ntdll-unix/wow64_image_mapper.h", str(SECTION_PATCH)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_image_mapper.h",
                        str(PROTECT_PATCH)], check=True)
        (root / "query_api.h").write_text(
            evolved_function(QUERY_PATCH, SECTION_PATCH, "static BOOL ios_wow64_route_query( HANDLE process, const void *addr,"))
        query_exe = root / "query-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / VIEWS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/query_test.c"), "-o", str(query_exe)], check=True)
        subprocess.run([str(query_exe)], check=True)
        (root / "section_map_api.h").write_text('#include "wow64_image_mapper.h"\n')
        (root / "section_server_api.h").write_text(
            patched_function(SECTION_PATCH, "static NTSTATUS ios_wow64_server_map( struct file_view *view )") +
            patched_function(SECTION_PATCH, "static NTSTATUS ios_wow64_server_unmap( struct file_view *view )"))
        (root / "section_route_api.h").write_text(
            evolved_function(SECTION_PATCH, PROTECT_PATCH, "static BOOL ios_wow64_route_section( HANDLE mapping, HANDLE process, void **addr, SIZE_T *size,") +
            patched_function(SECTION_PATCH, "static BOOL ios_wow64_route_unmap( HANDLE process, const void *addr, ULONG flags, NTSTATUS *status )"))
        section_exe = root / "section-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / VIEWS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/section_test.c"), "-o", str(section_exe)], check=True)
        subprocess.run([str(section_exe)], check=True)
        protect_exe = root / "protect-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / VIEWS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/protect_test.c"), "-o", str(protect_exe)], check=True)
        subprocess.run([str(protect_exe), str(root)], check=True)
        # The window's thread records and the Mach handler's pinned lookups.
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_threads.h",
                        str(THREADS_PATCH)], check=True)
        for name in ("fault", "threads"):
            exe = root / f"{name}-test"
            subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-function", "-pthread", "-fsanitize=undefined",
                            "-fno-sanitize-recover=all", "-I", str((root / VIEWS_HEADER).parent),
                            str(REPO / f"build/wow64/{name}_test.c"), "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", "--include=build/ntdll-unix/wow64_dc_attr.h",
                        str(DC_ATTR_PATCH)], check=True)
        (root / "pair_layout.h").write_text("".join(
            line + "\n" for line in (root / PAIR_HEADER).read_text().splitlines()
            if line.startswith("#define IOS_WOW64_") and not line.startswith("#define IOS_WOW64_PAIR_H")))
        (root / "dc_attr_api.h").write_text(
            patched_function(VIEWS_PATCH, "static void ios_wow64_delete_views( uintptr_t base )") +
            patched_function(DC_ATTR_PATCH, "static void *ios_wow64_dc_attr_create(void)") +
            patched_function(DC_ATTR_PATCH, "void *ios_wow64_dc_attr_arena( SIZE_T *size )") +
            patched_function(GDI32_DC_ATTR_PATCH,
                             "static void *client_ptr_from_dc_attr_arena( const UINT64 *arena, UINT64 ptr )"))
        dc_attr_exe = root / "dc-attr-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / VIEWS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/dc_attr_test.c"), "-o", str(dc_attr_exe)], check=True)
        subprocess.run([str(dc_attr_exe)], check=True)
        (root / "simd_lane_api.h").write_text(
            patched_function(SIMD_LANE_PATCH, "static int ios_simd_lane( uint32_t insn, int *offset )"))
        simd_exe = root / "simd-lane-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all", "-I", str(root),
                        str(REPO / "build/wow64/simd_lane_test.c"), "-o", str(simd_exe)], check=True)
        subprocess.run([str(simd_exe)], check=True)
        # wow64.dll's PE-side conversions, from the wine-pe patch.
        subprocess.run(["git", "-C", tmp, "apply", f"--include={GUEST_HEADER}",
                        str(GUEST_PATCH)], check=True)
        guest_exe = root / "guest-ptr-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / GUEST_HEADER).parent),
                        str(REPO / "build/wow64/guest_ptr_test.c"), "-o", str(guest_exe)], check=True)
        subprocess.run([str(guest_exe)], check=True)
        run_user_conversion_tests(root, (root / GUEST_HEADER).parent)
        # winevulkan's WoW64 thunk conversions, from the wine-unix patch.
        (root / "vulkan_api.h").write_text("".join(patched_function(VULKAN_PATCH, sig) for sig in (
            "static inline ULONG_PTR vulkan_wow64_window_base(void)",
            "static inline void *vulkan_wow64_to_host(ULONG guest)",
            "static inline ULONG vulkan_wow64_to_guest(const void *host)",
            "static inline UINT64 vulkan_wow64_client_handle(UINT64 handle)")))
        vulkan_exe = root / "vulkan-ptr-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all", "-I", str(root),
                        str(REPO / "build/wow64/vulkan_ptr_test.c"), "-o", str(vulkan_exe)], check=True)
        subprocess.run([str(vulkan_exe)], check=True)
    run_audio_tests(scratch)
    run_resolver_tests(scratch)
    run_packed_createstruct_tests(scratch)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
