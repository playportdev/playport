#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stage the runtime artifacts into the app package (app/).

Nothing this script copies is committed. The committed record is
app/artifacts.tsv: one row per embedded or linked artifact with its bundle
path, size, sha256, build root, source path and provenance key, plus `gap`
rows for the pieces that are not built. docs/BUILDING.md, "The pipeline" (stage).

  stage-artifacts.py stage    copy every artifact row into the package
                              (Sources/S1Probe/Runtime/, emptied first, Staged/lib/,
                              Sources/WinIOS/) after checking its size and
                              sha256 against the record, then apply
                              patches/madeira-winios to the Winios.m source
                              row; any mismatch, missing file or failing
                              patch stops the stage
  stage-artifacts.py record   rebuild artifacts.tsv from the build roots
                              (pp build runs it after every build)
  stage-artifacts.py release [DIR]
                              after `stage`: the release variant's package in
                              DIR (default app/.release; docs/BUILDING.md,
                              "Variants"): its own Package.swift, xtool.yml
                              (product Playport, Runtime/ at the package root)
                              and Info.plist,
                              links to the rest of app/, and Runtime/ holding
                              the resource rows, hard-linked from the staged
                              tree after checking each one, with the manifest

Build roots (env overrides; the defaults are the pipeline's run layout
under $PLAYPORT_RUN, default $PLAYPORT_BUILD/run):
  WINE_BUILD          pe/staged          stages/wine-pe.sh tree without DWARF (P2; stages/wine-pe-strip.py)
  FEX_DLL             fex/build-arm64ec/Bin/libarm64ecfex.dll (P1)
  FEX_WOW64_DLL       fex/build-wow64/Bin/libwow64fex.dll (P1)
  UNIX_ROOT           unix               stages/unix.sh + stages/unix-gaps.sh (P3/P4)
  DXMT_COMBINED_ROOT  dxmt-combined      stages/dxmt-combined.sh (P5-dxmt)
  DXMT_PE_ROOT        dxmt-patched/pe    stages/dxmt-patched.sh pe (P5-dxmt-pe); the
                                         same patched tree as P5-dxmt's unix objects
  VULKAN_PE_ROOT      vulkan-pe/pe       stages/vulkan-pe.sh (P6-vulkan-pe): DXVK and vkd3d-proton
  STEAMAPI_ROOT       steamapi/pe        stages/steamapi.sh (P8-steamapi): gbe_fork's steam_api DLLs
  session             session            stages/session-root.sh (P9-session, P9-url-opener): the session
                                         root and the URL opener
  idevice             idevice            stages/idevice.sh (P10-idevice): idevice's C FFI, one object
  registry            app/registry (committed; app/tools/prefix-registry.py, P7-reg)
  ca-bundle           $PLAYPORT_BUILD/cache/ca-bundle-<pin>
                                         stages/ca-bundle.sh (ca-bundle): the trusted roots
  wine-mono           $PLAYPORT_BUILD/cache/wine-mono-<pin>/wine-mono-<pin>
                                         stages/wine-mono.sh (wine-mono): the .NET runtime
  GENERATED           build/generated    the Wine PE manifests the P2 rows must equal
"""

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "app"
MANIFEST = PKG / "artifacts.tsv"
RUNTIME = PKG / "Sources" / "S1Probe" / "Runtime"
GENERATED = Path(os.environ.get("GENERATED", REPO / "build" / "generated"))
BUILD = Path(os.environ.get("PLAYPORT_BUILD", REPO / ".work"))
RUN = Path(os.environ.get("PLAYPORT_RUN") or BUILD / "run")


def pin(name):
    for line in (REPO / "pins.lock").read_text().splitlines():
        f = line.split()
        if f and f[0] == name:
            return f[1]
    sys.exit(f"pins.lock has no {name}")


ROOTS = {
    "wine-build": Path(os.environ.get("WINE_BUILD", RUN / "pe" / "staged")),
    "fex": Path(os.environ.get("FEX_DLL", RUN / "fex/build-arm64ec/Bin/libarm64ecfex.dll")).parent,
    "fex-wow64": Path(os.environ.get("FEX_WOW64_DLL", RUN / "fex/build-wow64/Bin/libwow64fex.dll")).parent,
    "unix": Path(os.environ.get("UNIX_ROOT", RUN / "unix")),
    "dxmt": Path(os.environ.get("DXMT_COMBINED_ROOT", RUN / "dxmt-combined")),
    "dxmt-pe": Path(os.environ.get("DXMT_PE_ROOT", RUN / "dxmt-patched" / "pe")),
    "vulkan-pe": Path(os.environ.get("VULKAN_PE_ROOT", RUN / "vulkan-pe" / "pe")),
    "steamapi": Path(os.environ.get("STEAMAPI_ROOT", RUN / "steamapi" / "pe")),
    "session": RUN / "session",
    "idevice": RUN / "idevice",
    "registry": PKG / "registry",
    "ca-bundle": BUILD / "cache" / f"ca-bundle-{pin('ca-bundle')}",
    "wine-mono": BUILD / "cache" / f"wine-mono-{pin('wine-mono')}" / f"wine-mono-{pin('wine-mono')}",
}
MYTHIC_REV = pin("madeira")
WINE_MONO = pin("wine-mono")

HEADER = """\
# App artifact manifest. Generated by build/stages/stage-artifacts.py record; checked by `stage` and build/verify-ipa.py.
# Columns: kind  dest  bytes  sha256  root  source  provenance
#   kind   resource = copied into the app bundle (dest is relative to Sources/S1Probe/)
#          link     = static archive linked into the app executable (dest is relative to Staged/)
#          source   = adopted Madeira source compiled into the app (dest is relative to Sources/);
#                     the hash is of the unpatched upstream file, the patch is applied after the copy
#          gap      = required by the reference architecture but not built; nothing is staged
#   root   build root the source path is relative to (see the script docstring for defaults)
# Provenance keys (pins: pins.lock; patch series: patches/<target>/series; recipes: docs/BUILDING.md):
#   P1-de     FEX pin + patches/fex, llvm-mingw 20260922 (build/stages/fex.sh); shipped as xtajit64.dll and aarch64 xtajit.dll (WoW64; build-only until Portal 2 milestone 1 step 3); the ARM64EC [build-id] line carries the pin's commit time: SOURCE_DATE_EPOCH
#   P2        wine pin + patches/wine-pe, build/stages/wine-pe.sh, without DWARF (build/stages/wine-pe-strip.py); row hash equals build/generated/wine-pe-*.tsv
#   P2-ec     arm64ec ntdll.dll of the same P2 tree (the arm64ec patches only change it); row hash equals build/generated/wine-pe-arm64ec-windows.tsv
#   P3        Madeira pin build/ntdll-unix/build.sh via build/stages/unix.sh + stages/unix-gaps.sh gnutls-config, with patches/madeira-unix and patches/wine-unix applied
#   P4-win32u Madeira pin build/win32u-unix/build.sh via build/stages/unix.sh (patches/madeira-unix virtual-monitor-refresh: MADEIRA_SCREEN_HZ)
#   P4-server reconstructed base + Madeira build/wineserver/build.sh via build/stages/unix-gaps.sh wineserver (patches/madeira-unix real-suspend-safepoint, patches/wine-unix server-ios-*)
#   P4-crypto GnuTLS 3.8.9 / GMP 6.3.0 / Nettle 3.10.1 from Madeira's tracked tarballs via build/stages/unix.sh gnutls; nettle/hogweed hashes depend on UNIX_ROOT
#   nls       wine pin nls/ (tracked data files): the set Madeira app/Madeira/nls ships, plus every Windows ANSI code page (PLA-233)
#   fonts     wine pin fonts/{tahoma,tahomabd}.ttf (tracked prebuilts, not regenerated with FontForge); architecture-neutral GDI fallback faces
#   winsxs    wine pin dlls/<module>/*.manifest for the modules with a WINE_MANIFEST resource (tracked data files, the side-by-side assemblies wineboot's fakedll.c registers); wine_host.c link_winsxs installs them for x86 and arm64 into drive_c/windows/winsxs with links into the i386 and arm64ec sets
#   etc       wine pin dlls/ws2_32/{hosts,networks,protocol,services} (tracked data files, the ones ws2_32.dll carries as the resources wine.inf [EtcFiles] installs); wine_host.c copies the ones a prefix lacks into drive_c/windows/system32/drivers/etc
#   P5-dxmt   DXMT pin (3Shain/dxmt) + patches/dxmt-port + patches/dxmt unix slice (build/stages/dxmt-patched.sh unix: build/stages/dxmt-base.sh unix + the hand-ported AIR helpers in build/air-helpers) + LLVM 15.0.7 iOS static libs, combined by build/stages/dxmt-combined.sh as Madeira build/dxmt-ios/README.md does
#   P5-dxmt-pe  the same patched tree's PE DLLs (build/stages/dxmt-patched.sh pe, llvm-mingw 20260922); must match P5-dxmt's unix slot table (150 winemetal unix slots; newLibraryWithSource at 144)
#   P5-winios Madeira pin app/Madeira/Winios/ (the reference's app-side Winios display driver); Winios.m + patches/madeira-winios; WiniosGamepad.c, the controller snapshot Wine's xinput1_*.dll (P2) read through libwin32u_unix.a
#   P5-dxshim Madeira pin app/Madeira/IOSDisplayShim.{h,m}, unmodified: the macdrv_functions table DXMT's winemetal unix side looks up for a CAMetalLayer
#   P6-vulkan-pe DXVK at its pin, unmodified, and vkd3d-proton at its pin + patches/vkd3d-proton, for arm64ec (build/stages/vulkan-pe.sh, llvm-mingw 20260922), marked Wine builtins; staged under Runtime/vulkan/, which a launch set to Vulkan puts first on WINEDLLPATH (decision 0014)
#   P6-gst    winegstreamer's unix side (wine pin + patches/wine-port + patches/wine-unix) prelinked with the static plugin set from the pins.lock gstreamer iOS release (build/stages/gstreamer.sh); one object, one exported symbol
#   P8-steamapi gbe_fork (LGPL-3.0) at the gbe pin + patches/gbe: its regular steam_api for x86-64 and i386 with its static dependencies (build/stages/steamapi.sh, llvm-mingw 20260922); native DLLs under Runtime/steamapi/, which the app copies into a game's folder in place of the game's own (SteamClientKit SteamAPISwap)
#   P9-session app/SessionRoot/playport-session.c (Playport's own) compiled by build/stages/session-root.sh (llvm-mingw 20260922) as a freestanding x86-64 program: the one Wine main process of an app run, which starts every title as its child (decision 0027); in arm64ec-windows so the prefix's system32 has it
#   P9-url-opener app/UrlOpener/playport-url-opener.c (Playport's own) compiled by build/stages/session-root.sh (llvm-mingw 20260922) as a freestanding x86-64 program: the prefix's http and https handler, which hands a URL a game opens to the host app (decision 0064); in arm64ec-windows so the prefix's system32 has it
#   P10-idevice idevice (MIT) at the idevice pin, its C FFI with the features the app's restart uses, built for aarch64-apple-ios with the pins.lock Rust (build/stages/idevice.sh) and prelinked into one object that exports four calls (app/Sources/Relaunch); its crates are in the run's idevice/crates.tsv
#   P7-reg    app/registry/{system,user}.reg (committed): app/tools/prefix-registry.py applies the WINE_REGISTRY scripts of the staged arm64ec-windows DLLs as wineboot's register_fake_dll would; wine_host.c appends the sections a prefix lacks before the wineserver starts
#   ca-bundle Mozilla's root store (MPL-2.0) as curl's CA extract, the dated file pins.lock's ca-bundle row names, unmodified (build/stages/ca-bundle.sh checks its sha256): wine_host.c names it in MADEIRA_CA_BUNDLE, and crypt32's unix side imports it into the prefix's ROOT store (docs/ARCHITECTURE.md, "Trusted roots")
#   wine-mono WineHQ's Wine Mono release (MIT, LGPL and others; build/notices-wine-mono.py) at the wine-mono pin, the shared-directory tarball unmodified (build/stages/wine-mono.sh checks its sha256), a symbolic link staged as a copy of its target; under Runtime/mono/wine-mono-<pin>/, where the wine pin's mscoree finds it from WINEDATADIR, as in Proton's share/wine/mono (decision 0077)
"""

# Reference bundle layout (names only) from Madeira app/Madeira @ MYTHIC_REV:
# which Wine modules the reference app embeds per PE arch, and its nls/ set.
# Names absent from the P2 manifest are skipped: at the pin that is Madeira's
# native D3D12 runtime (madeira_d3d12.dll, out of scope, docs/LICENSING.md) and
# its test programs.
NLS = ["c_1252.nls", "c_20127.nls", "c_28591.nls", "c_437.nls", "l_intl.nls", "locale.nls",
       "normidna.nls", "normnfc.nls", "normnfd.nls", "normnfkc.nls", "normnfkd.nls", "sortdefault.nls"]
# Every other code page GetACP can return on Windows (PLA-233). A Delphi 2009+ program's
# AnsiString literals carry its build machine's ANSI code page, which the RTL converts with:
# GOG's Inno Setup, built with 1250, cannot name its script functions without c_1250.nls.
NLS += ["c_874.nls", "c_932.nls", "c_936.nls", "c_949.nls", "c_950.nls", "c_1250.nls", "c_1251.nls",
        "c_1253.nls", "c_1254.nls", "c_1255.nls", "c_1256.nls", "c_1257.nls", "c_1258.nls"]

FONTS = ["tahoma.ttf", "tahomabd.ttf"]

ETC = ["hosts", "networks", "protocol", "services"]

# The WINE_MANIFEST resources wineboot installs into C:\windows\winsxs: (module, manifest).
SXS = [("atl80", "atl80.manifest"), ("atl90", "atl90.manifest"), ("comctl32_v6", "comctl32.manifest"),
       ("gdiplus", "gdiplus.manifest"), ("gdiplus", "gdiplus11.manifest"), ("msvcr80", "msvcr80.manifest"),
       ("msvcr90", "msvcr90.manifest"), ("msxml3", "msxml3.manifest"), ("msxml4", "msxml4.manifest"),
       ("msxml6", "msxml6.manifest")]

LINK = [  # dest name, root, source, provenance
    ("libntdll_unix.a", "unix", "mythic/app/Madeira/libntdll_unix.a", "P3"),
    ("libwin32u_unix.a", "unix", "mythic/app/Madeira/libwin32u_unix.a", "P4-win32u"),
    ("libwineserver.a", "unix", "mythic/app/Madeira/libwineserver.a", "P4-server"),
    # toolchains/, not app/Madeira/: the app/Madeira copies are the reference's own prebuilts
    ("libgnutls.a", "unix", "mythic/toolchains/gnutls-ios/lib/libgnutls.a", "P4-crypto"),
    ("libhogweed.a", "unix", "mythic/toolchains/gnutls-ios/lib/libhogweed.a", "P4-crypto"),
    ("libnettle.a", "unix", "mythic/toolchains/gnutls-ios/lib/libnettle.a", "P4-crypto"),
    ("libgmp.a", "unix", "mythic/toolchains/gnutls-ios/lib/libgmp.a", "P4-crypto"),
    ("libdxmt_combined.a", "dxmt", "libdxmt_combined.a", "P5-dxmt"),
    ("libwinegstreamer_unix.a", "unix", "gstreamer/libwinegstreamer_unix.a", "P6-gst"),
    ("libidevice_ffi.a", "idevice", "libidevice_ffi.a", "P10-idevice"),
]

SOURCES = [  # dest (relative to Sources/), root, source, provenance
    ("WinIOS/Winios.m", "unix", "mythic/app/Madeira/Winios/Winios.m", "P5-winios"),
    ("WinIOS/include/Winios.h", "unix", "mythic/app/Madeira/Winios/Winios.h", "P5-winios"),
    # Winios.h includes it; libwin32u_unix.a reads the host controller snapshot from it.
    ("WinIOS/WiniosGamepad.c", "unix", "mythic/app/Madeira/Winios/WiniosGamepad.c", "P5-winios"),
    ("WinIOS/include/WiniosGamepad.h", "unix", "mythic/app/Madeira/Winios/WiniosGamepad.h", "P5-winios"),
    # The macdrv_functions table DXMT's winemetal unix side finds through
    # dlsym(RTLD_DEFAULT): one CAMetalLayer per swap chain.
    ("WinIOS/IOSDisplayShim.m", "unix", "mythic/app/Madeira/IOSDisplayShim.m", "P5-dxshim"),
    ("WinIOS/include/IOSDisplayShim.h", "unix", "mythic/app/Madeira/IOSDisplayShim.h", "P5-dxshim"),
]
# Source-row dest -> the patch series applied to it after the copy (-p4: the
# series is against Madeira's root, the copy sits in Sources/WinIOS/).
PATCHES = {"WinIOS/Winios.m": ("madeira-winios", 4)}


def series(target):
    d = REPO / "patches" / target
    return [d / l for l in (d / "series").read_text().splitlines() if l and not l.startswith("#")]

# The DXMT modules the reference bundles per arch: its arm64ec d3d10core.dll is
# DXMT's (imports D3D11.DLL), its aarch64 one is Wine's builtin (stays P2).
DXMT_PE = {"arm64ec": {"winemetal.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll"},
           "aarch64": {"winemetal.dll", "d3d11.dll", "dxgi.dll"}}

# Which Wine modules each set stages (decisions 0070 and 0071, Proton parity):
# every production module the Wine build makes for the architecture, as
# Proton's lib/wine/<arch>-windows holds everything Wine installs. Production
# means the manifest's dlls/ and programs/ entries without tests and without
# NOT_SHIPPED; i386 keeps its 16-bit modules (.dll16, .drv16, .exe16, .mod16,
# .vxd), as Proton's i386-windows does. All three sets take the whole
# production set; aarch64 is laid out as Proton's ARM64 build has it, where
# Wine builds most programs only for the native architecture.
# Replacements win over Wine's module of the same name: FEX's xtajit64.dll,
# the arm64ec ntdll.dll (P2-ec), DXMT_PE, FEX's aarch64 xtajit.dll. The Vulkan
# overlay and the Steam API are separate directories.
# winetest.exe: Wine's install leaves it out and Proton ships none. winedbg,
# control and winemenubuilder are staged; the registry seed turns off what
# they would do on the phone (app/tools/prefix-registry.py NEUTRALISE).
NOT_SHIPPED = {"winetest.exe"}

# DXVK's and vkd3d-proton's DLLs (build/stages/vulkan-pe.sh).
VULKAN_PE = ["d3d8.dll", "d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll", "d3d12.dll", "d3d12core.dll"]
VULKAN_PE_I386 = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]

def wine_mono_files():
    """Every file of the unpacked Wine Mono tree (build/stages/wine-mono.sh), relative to
    it; a symbolic link is a file here, recorded and staged as its target's bytes."""
    root = ROOTS["wine-mono"]
    if not (root / "bin").is_dir():
        sys.exit(f"{root} is not an unpacked Wine Mono tree: run build/stages/wine-mono.sh")
    return sorted(p.relative_to(root).as_posix() for p in root.rglob("*")
                  if p.is_file() and p.name != ".unpacked-from")


# The Steam API emulator (build/stages/steamapi.sh), per game architecture.
STEAMAPI = [("x86_64", "steam_api64.dll"), ("i386", "steam_api.dll")]

GAPS = [  # kind-of-thing, dest, reason
    ("resource", "Runtime/arm64ec-windows/wineios.drv", "Madeira build/wineios-drv/wineios.c has no build recipe at the Madeira pin, and the wine-port tree's dlls/wineios.drv is not in its configure, so stages/wine-pe.sh does not build it; audio does not need it: mmdevapi loads winepulse.drv by name and virtual_ios.c answers with the linked audio_null_ios table"),
    ("resource", "Runtime/prefix-template.tar.gz", "reference seeds the whole prefix from an untracked-recipe template; the app seeds only the builtins' own registrations (Runtime/registry, P7-reg), so the rest of wine.inf (font registry, services, file associations) is not applied"),
]


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def reference_names(arch):
    out = subprocess.run(["git", "-C", str(ROOTS["unix"] / "mythic"), "ls-tree", "--name-only",
                          MYTHIC_REV, f"app/Madeira/{arch}-windows/"],
                         check=True, capture_output=True, text=True).stdout.split()
    return sorted(os.path.basename(n) for n in out)


def production(arch, generated=None):
    """basename (lower-case) -> (build-tree path, size, sha256) of every production
    module in the committed P2 manifest (see NOT_SHIPPED). Two modules with one
    name, in any case, stop the stage."""
    tree = "build-arm64ec" if arch == "arm64ec" else "build-macos"
    idx = {}
    for line in ((generated or GENERATED) / f"wine-pe-{arch}-windows.tsv").read_text().splitlines():
        path, size, digest = line.split("\t")[:3]
        name = os.path.basename(path).lower()
        if "/tests/" in path or not path.startswith(("dlls/", "programs/")) or name in NOT_SHIPPED:
            continue
        if name in idx:
            sys.exit(f"wine-pe-{arch}-windows.tsv: {idx[name][0]} and {tree}/{path} are both {name}")
        idx[name] = (f"{tree}/{path}", int(size), digest)
    return idx


def selection(arch, idx, reference):
    """The staged names of a Runtime/<arch>-windows set (arm64ec or aarch64): the
    whole production set and the replacements, in the reference's spelling where
    it has the name (Normaliz.dll), else the manifest's. Reference-only names
    neither built nor replaced (Madeira's own D3D12 runtime and its test
    programs) are not staged."""
    spelled = {n.lower(): n for n in reference}
    wanted = set(idx) | DXMT_PE[arch] | ({"xtajit64.dll"} if arch == "arm64ec" else set())
    return sorted(spelled.get(n, n) for n in wanted)


def record():
    rows = []

    def add(kind, dest, root, source, prov):
        p = ROOTS[root] / source
        rows.append((kind, dest, str(p.stat().st_size), sha256(p), root, source, prov))

    for arch in ("arm64ec", "aarch64"):
        idx = production(arch)
        for name in selection(arch, idx, reference_names(arch)):
            dest = f"Runtime/{arch}-windows/{name}"
            if arch == "arm64ec" and name == "xtajit64.dll":
                add("resource", dest, "fex", "libarm64ecfex.dll", "P1-de")
            elif arch == "arm64ec" and name == "ntdll.dll":
                add("resource", dest, "wine-build", "build-arm64ec/dlls/ntdll/arm64ec-windows/ntdll.dll", "P2-ec")
            elif name.lower() in DXMT_PE[arch]:
                add("resource", dest, "dxmt-pe", f"{arch}-windows/{name}", "P5-dxmt-pe")
            elif name.lower() in idx:
                src, size, digest = idx[name.lower()]
                add("resource", dest, "wine-build", src, "P2")
                if rows[-1][2:4] != (str(size), digest):
                    sys.exit(f"{src}: build tree differs from generated/wine-pe-{arch}-windows.tsv")
            else:
                sys.exit(f"{name}: selected for {arch} but has no provider")
    # WoW64 has no reference bundle set: the complete i386 production set, its
    # loader is Wine's, not a hand-picked PE32 loader.
    for name, (src, size, digest) in sorted(production("i386").items()):
        add("resource", f"Runtime/i386-windows/{name}", "wine-build", src, "P2")
        if rows[-1][2:4] != (str(size), digest):
            sys.exit(f"{src}: build tree differs from generated/wine-pe-i386-windows.tsv")
    add("resource", "Runtime/aarch64-windows/xtajit.dll", "fex-wow64", "libwow64fex.dll", "P1-de")
    # The Vulkan Direct3D backend (decision 0014), under Runtime/vulkan/.
    for name in VULKAN_PE:
        add("resource", f"Runtime/vulkan/arm64ec-windows/{name}", "vulkan-pe", f"arm64ec-windows/{name}",
            "P6-vulkan-pe")
    # DXVK's Direct3D 9 to 11 for an i386 (WoW64) title, over Wine's wined3d ones.
    for name in VULKAN_PE_I386:
        add("resource", f"Runtime/vulkan/i386-windows/{name}", "vulkan-pe", f"i386-windows/{name}", "P6-vulkan-pe")
    for arch, name in STEAMAPI:
        add("resource", f"Runtime/steamapi/{arch}-windows/{name}", "steamapi", f"{arch}-windows/{name}", "P8-steamapi")
    add("resource", "Runtime/arm64ec-windows/playport-session.exe", "session", "playport-session.exe", "P9-session")
    add("resource", "Runtime/arm64ec-windows/playport-url-opener.exe", "session", "playport-url-opener.exe", "P9-url-opener")
    for name in NLS:
        add("resource", f"Runtime/nls/{name}", "unix", f"wine/nls/{name}", "nls")
    for name in FONTS:
        add("resource", f"Runtime/fonts/{name}", "unix", f"wine/fonts/{name}", "fonts")
    for name in ETC:
        add("resource", f"Runtime/etc/{name}", "unix", f"wine/dlls/ws2_32/{name}", "etc")
    for module, name in SXS:
        add("resource", f"Runtime/winsxs/{module}/{name}", "unix", f"wine/dlls/{module}/{name}", "winsxs")
    for name in ("system.reg", "user.reg"):
        add("resource", f"Runtime/registry/{name}", "registry", name, "P7-reg")
    add("resource", "Runtime/certs/cacert.pem", "ca-bundle", "cacert.pem", "ca-bundle")
    for name in wine_mono_files():
        add("resource", f"Runtime/mono/wine-mono-{WINE_MONO}/{name}", "wine-mono", name, "wine-mono")
    for dest, root, source, prov in LINK:
        add("link", f"lib/{dest}", root, source, prov)
    for dest, root, source, prov in SOURCES:
        add("source", dest, root, source, prov)
    for kind, dest, reason in GAPS:
        rows.append(("gap", dest, "-", "-", "-", kind, reason))
    seen = {}
    for r in rows:   # one file per destination, in any case: a later row would overwrite a replacement
        if r[1].lower() in seen:
            sys.exit(f"{r[1]}: recorded twice ({seen[r[1].lower()]} and {r[6]})")
        seen[r[1].lower()] = r[6]
    MANIFEST.write_text(HEADER + "".join("\t".join(r) + "\n" for r in rows))
    print(f"recorded {len(rows)} rows in {MANIFEST.relative_to(REPO)}")


def stage():
    rows = [l.split("\t") for l in MANIFEST.read_text().splitlines() if l and not l.startswith("#")]
    shutil.rmtree(RUNTIME, ignore_errors=True)   # generated: only this manifest's rows go in
    bad = []
    for kind, dest, size, digest, root, source, prov in rows:
        if kind == "gap":
            print(f"GAP      {dest}: {prov}")
            continue
        src = ROOTS[root] / source
        if not src.is_file():
            bad.append(f"missing  {src}")
            continue
        got = (str(src.stat().st_size), sha256(src))
        if got != (size, digest):
            bad.append(f"mismatch {src}: {got[0]} {got[1]} (recorded {size} {digest})")
            continue
        out = {"resource": PKG / "Sources" / "S1Probe", "link": PKG / "Staged",
               "source": PKG / "Sources"}[kind] / dest
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, out)
        target, strip = PATCHES.get(dest, (None, 0)) if kind == "source" else (None, 0)
        for patch in series(target) if target else []:
            with open(patch) as f:
                r = subprocess.run(["patch", "--quiet", "--forward", "--fuzz=0", "--no-backup-if-mismatch",
                                    f"-p{strip}", "-d", str(out.parent)], stdin=f)
            if r.returncode:
                bad.append(f"patch    {patch.name} does not apply to {out}")
                break
    if bad:
        sys.exit("\n".join(bad))
    shutil.copyfile(MANIFEST, RUNTIME / "artifacts.tsv")   # the app re-verifies the bundle against it
    n = sum(r[0] != "gap" for r in rows)
    print(f"staged {n} artifacts ({sum(r[0] == 'gap' for r in rows)} gaps); all sizes and sha256 match")


# The release package's links into app/: everything xtool.yml and Package.swift
# name except the two files it gets its own copies of and Runtime/.
RELEASE_LINKS = ["Sources", "Staged", "Icon", "HostIOKit", "ContentKit", "GOGClient", "EpicClient", "JITKit", "PlayportKit", "SteamClient", "PlayportJIT",
                 "PlayportJIT-Info.plist", "S1Probe.entitlements"]


def release_xtool_yml(text):
    """app/xtool.yml for the release package: product Playport, Runtime/ at its root,
    with the icon that has no DEV tab."""
    out, product, runtime, icon = [], 0, 0, 0
    for line in text.splitlines(keepends=True):
        if line == "product: S1Probe\n":
            line, product = "product: Playport\n", product + 1
        elif line == "iconPath: Icon/AppIcon-dev.png\n":
            line, icon = "iconPath: Icon/AppIcon.png\n", icon + 1
        elif line.lstrip().startswith("- Sources/S1Probe/Runtime/"):
            line, runtime = line.replace("Sources/S1Probe/Runtime/", "Runtime/", 1), runtime + 1
        out.append(line)
    if product != 1 or not runtime or icon != 1:
        sys.exit(f"app/xtool.yml: expected one `product: S1Probe`, its Runtime/ resources"
                 f" and one `iconPath: Icon/AppIcon-dev.png`, found {product}, {runtime} and {icon}")
    return ("# Generated by build/stages/stage-artifacts.py release from app/xtool.yml; do not edit.\n"
            + "".join(out))


def release(dest=None):
    dest = Path(dest) if dest else PKG / ".release"
    staged = RUNTIME / "artifacts.tsv"
    if not staged.is_file():
        sys.exit(f"{staged} is missing: run `stage` first")
    text = staged.read_text()
    dest.mkdir(parents=True, exist_ok=True)
    for name in RELEASE_LINKS:
        link = dest / name
        if link.is_symlink() or link.exists():
            if not link.is_symlink():
                sys.exit(f"{link} exists and is not a link")
            link.unlink()
        link.symlink_to(Path("..") / name)
    shutil.copyfile(PKG / "Package.swift", dest / "Package.swift")
    info = dest / "Info.plist"
    if info.is_symlink():
        info.unlink()
    shutil.copyfile(PKG / "Info.plist", info)
    (dest / "xtool.yml").write_text(release_xtool_yml((PKG / "xtool.yml").read_text()))
    runtime = dest / "Runtime"
    shutil.rmtree(runtime, ignore_errors=True)
    rows = [l.split("\t") for l in text.splitlines() if l and not l.startswith("#")]
    bad, n = [], 0
    for kind, dest_path, size, digest, root, source, prov in rows:
        if kind != "resource":
            continue
        src = PKG / "Sources" / "S1Probe" / dest_path
        if not src.is_file() or (str(src.stat().st_size), sha256(src)) != (size, digest):
            bad.append(f"staged {src} is missing or does not match its row")
            continue
        out = runtime / dest_path.removeprefix("Runtime/")
        out.parent.mkdir(parents=True, exist_ok=True)
        os.link(src, out)
        n += 1
    if bad:
        sys.exit("\n".join(bad))
    (runtime / "artifacts.tsv").write_text(text)
    print(f"release package {dest}: {n} resources linked")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "stage"
    if cmd == "release":
        release(*sys.argv[2:3])
    else:
        {"record": record, "stage": stage}[cmd]()
