#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Close the gaps left by stages/unix.sh (docs/BUILDING.md, "The pipeline" (unix)).
# Runs on a ROOT already produced by stages/unix.sh (stages clones shims
# configure gnutls freetype widl ntdll win32u); touches nothing outside ROOT.
#
# usage: stages/unix-gaps.sh ROOT [stage...]
#   stages (default: all, in order):
#     gnutls-config   add the two GnuTLS defines the reference's macOS configure
#                     had, then rebuild ntdll so the bcrypt/secur32/crypt32
#                     unixlibs are compiled with their GnuTLS code (§4)
#     wineserver      reconstruct the base libwineserver.a from the 27 unpatched
#                     wine/server units, then run Madeira's build/wineserver/build.sh
#                     unmodified on it (§5)
#     linktest        link every unix-side archive into a throwaway iOS executable (§6)
set -e

ROOT=${1:?usage: $0 ROOT [stage...]}
shift
STAGES=${*:-gnutls-config wineserver linktest}
HERE=$(cd "$(dirname "$0")" && pwd)
M=$ROOT/mythic
W=$ROOT/wine
A=$M/app/Madeira
G=$M/toolchains/gnutls-ios/lib
. "$HERE/../lib.sh"
export TMPDIR=${TMPDIR:-$ROOT/tmp}
mkdir -p "$TMPDIR"

test -x "$ROOT/shims/xcrun" || { echo "run stages/unix.sh $ROOT first"; exit 1; }
run() { env PATH="$ROOT/shims:$PATH" LC_ALL=C "$@"; }

stage_gnutls-config() {
    local c=$W/build-macos/include/config.h
    grep -q '^#define SONAME_LIBGNUTLS ' "$c" ||
        printf '\n/* Madeira iOS: GnuTLS is linked statically and reached through ios_gnutls_shim.h */\n#define HAVE_GNUTLS_CIPHER_INIT 1\n#define SONAME_LIBGNUTLS "libgnutls.30.dylib"\n' >> "$c"
    sha256sum "$c"
    bash "$HERE/unix.sh" "$ROOT" ntdll
    # wine-11.18 dropped bcrypt's unix side (SymCrypt on the PE side, no
    # dlls/bcrypt/gnutls.c), so bcrypt is checked only where Wine still has it.
    local libs="secur32 crypt32"
    test -f "$W/dlls/bcrypt/gnutls.c" && libs="bcrypt $libs"
    for l in $libs; do
        llvm-nm "$A/libntdll_unix.a" 2>/dev/null | grep -q " [DS] _${l}_unix_call_funcs$" ||
            { echo "${l}_unix_call_funcs missing"; exit 1; }
    done
    echo "gnutls unixlibs: $libs defined"
}

# The 27 wine/server units build.sh does not replace; CC_FLAGS copied verbatim
# from Madeira build/wineserver/build.sh.
UNPATCHED="atom change clipboard completion console d3dkmt debugger device directory
event file handle hook inproc_sync mailslot mutex named_pipe procfs ptrace registry
semaphore serial signal symlink timer token trace"
stage_wineserver() {
    local b=$M/build/wineserver base=$ROOT/wineserver-base u
    local cc_flags=(
        -arch arm64 -isysroot "$IOSSDK" -miphoneos-version-min=17.0 -O2
        -I"$W/include" -I"$W/include/wine" -I"$W/build-macos/include"
        -I"$b" -I"$W/server" -I"$M/build/ntdll-unix/shims"
        -include "$b/config_ios.h" -include stdarg.h
        -include "$b/unicode_fix.h" -include "$b/wineserver_ios_kill.h"
        -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
        -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main
        -Wno-implicit-function-declaration
    )
    rm -rf "$base" "$b/obj"; mkdir -p "$base"
    # wine-11.18 added server/alpc.c, which Madeira does not replace
    test -f "$W/server/alpc.c" && UNPATCHED="alpc $UNPATCHED"
    for u in $UNPATCHED; do
        run xcrun -sdk iphoneos clang "${cc_flags[@]}" -c "$W/server/$u.c" -o "$base/$u.o"
    done
    rm -f "$A/libwineserver.a"
    llvm-ar rcs "$A/libwineserver.a" "$base"/*.o
    echo "reconstructed base: $(llvm-ar t "$A/libwineserver.a" | wc -l) members"
    run bash "$b/build.sh"
}

stage_linktest() {
    local t=$ROOT/linktest cc
    cc="clang --target=arm64-apple-ios17.0 -isysroot $IOSSDK -fuse-ld=lld -Wno-unused-command-line-argument"
    mkdir -p "$t"
    cat > "$t/entry.c" <<'EOF'
/* entry points the Madeira app calls into the unix-side archives */
extern int wineserver_main(int, char **), __wine_main(int, char **);
extern void wineserver_log_set_file(const char *), wineserver_set_nls_dir(const char *), wineserver_inject_client_fd(int);
void *keep[] = { wineserver_main, wineserver_log_set_file, wineserver_set_nls_dir, wineserver_inject_client_fd, __wine_main };
int main(void) { return keep[0] != 0; }
/* stand-ins for symbols the Madeira app sources define
 * (WineServerBridge.m, WineProcessBridge.m, wine_stubs.c, Winios.m) */
volatile int g_wineserver_should_stop;
void fatal_error(const char *e, ...) { for (;;); }
const char *wine_build = "linktest";
__thread int wine_ios_exit_code, wine_ios_exit_initialized;
__thread long wine_ios_exit_jmpbuf[64];
__thread void *wine_ios_main_thread;
int winios_phase;
EOF
    $cc -c "$t/entry.c" -o "$t/entry.o"
    # candidate: the build.sh ws_ rename sweep extended by the 4 symbols that
    # still collide with libntdll_unix.a (not applied to app/Madeira)
    rm -rf "$t/ren"; mkdir "$t/ren"
    ( cd "$t/ren" && llvm-ar x "$A/libwineserver.a" &&
      for f in *.o; do
          llvm-objcopy --redefine-sym _server_start_time=_ws_server_start_time \
              --redefine-sym _supported_machines=_ws_supported_machines \
              --redefine-sym _supported_machines_count=_ws_supported_machines_count \
              --redefine-sym _native_machine=_ws_native_machine "$f"
      done && llvm-ar rcs "$t/libwineserver-ws4.a" *.o )
    local fw="-framework Foundation -framework CoreFoundation -framework Security -framework CoreText
              -framework CoreGraphics -framework IOSurface -framework AudioToolbox -framework IOKit -lc++"
    local rest="$A/libntdll_unix.a $A/libwin32u_unix.a $G/libgnutls.a $G/libhogweed.a $G/libnettle.a $G/libgmp.a"
    # app-provided symbols (Winios driver, DXMT slice) are left to dynamic_lookup
    for ws in "$A/libwineserver.a" "$t/libwineserver-ws4.a"; do
        if $cc "$t/entry.o" "$ws" $rest $fw -Wl,-undefined,dynamic_lookup -o "$t/a.out" > "$t/link.log" 2>&1
        then echo "LINK OK   $ws ($(llvm-nm "$t/a.out" | grep -c ' T _gnutls_') gnutls_* functions linked)"
        else echo "LINK FAIL $ws: $(grep -o 'duplicate symbol: [a-z_]*' "$t/link.log" | sort -u | tr '\n' ' ')"
        fi
    done
    printf '%s %s %s\n' "$(stat -c %s "$A/libntdll_unix.a")" "$(sha256sum "$A/libntdll_unix.a" | cut -d' ' -f1)" "$A/libntdll_unix.a"
    printf '%s %s %s\n' "$(stat -c %s "$A/libwineserver.a")" "$(sha256sum "$A/libwineserver.a" | cut -d' ' -f1)" "$A/libwineserver.a"
    printf '%s %s %s\n' "$(stat -c %s "$t/libwineserver-ws4.a")" "$(sha256sum "$t/libwineserver-ws4.a" | cut -d' ' -f1)" "$t/libwineserver-ws4.a"
}

for s in $STAGES; do echo "=== stage $s"; "stage_$s"; done
