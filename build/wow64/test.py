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
        (root / "image_api.h").write_text(
            patched_function(IMAGE_PATCH, "static int mprotect_range( void *base, size_t size, BYTE set, BYTE clear )"))
        image_exe = root / "image-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-DWINE_IOS", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / IMAGE_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/image_test.c"), "-o", str(image_exe)], check=True)
        subprocess.run([str(image_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={PARAMS_HEADER}",
                        str(PARAMS_PATCH)], check=True)
        (root / "params_api.h").write_text(
            patched_function(PARAMS_PATCH, "static NTSTATUS ios_wow64_init_parameters( PEB *owner, uintptr_t window,"))
        params_exe = root / "params-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / PARAMS_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/params_test.c"), "-o", str(params_exe)], check=True)
        subprocess.run([str(params_exe)], check=True)
        subprocess.run(["git", "-C", tmp, "apply",
                        "--include=build/ntdll-unix/wow64_placement.h",
                        "--include=build/ntdll-unix/image_reloc.h", str(PLACEMENT_PATCH)], check=True)
        placement_exe = root / "placement-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-DWINE_IOS", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / IMAGE_HEADER).parent), "-I", str(root),
                        str(REPO / "build/wow64/placement_test.c"), "-o", str(placement_exe)], check=True)
        subprocess.run([str(placement_exe)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
