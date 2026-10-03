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
FAULT_PATCH = REPO / "patches/madeira-unix/0062-ntdll-service-a-WoW64-window-s-low-faults-in-the-Mac.patch"
GUEST_HEADER = "dlls/wow64/wow64_window.h"
GUEST_PATCH = REPO / "patches/wine-pe/0016-wow64-convert-guest-pointers-through-the-iOS-guest-w.patch"


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
        (root / "fault_api.h").write_text(
            patched_function(FAULT_PATCH, "uintptr_t ios_wow64_fault_base_for_peb( void *owner )"))
        fault_exe = root / "fault-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str(root), str(REPO / "build/wow64/fault_test.c"), "-o", str(fault_exe)], check=True)
        subprocess.run([str(fault_exe)], check=True)
        # wow64.dll's PE-side conversions, from the wine-pe patch.
        subprocess.run(["git", "-C", tmp, "apply", f"--include={GUEST_HEADER}",
                        str(GUEST_PATCH)], check=True)
        guest_exe = root / "guest-ptr-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / GUEST_HEADER).parent),
                        str(REPO / "build/wow64/guest_ptr_test.c"), "-o", str(guest_exe)], check=True)
        subprocess.run([str(guest_exe)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
