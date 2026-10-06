# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by the build/*.sh scripts: pins, mirrors and the patch series, after
# build/env.sh (repository paths, the build area and the cached external
# inputs). Every tree's digest includes this file (build/pipeline); env.sh is
# kept apart so where things are found does not rebuild the trees (the
# toolchain part of the digest covers what they are built with).

. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# pin NAME: the commit (or tag) pins.lock records for NAME.
pin() {
    local v
    v=$(awk -v k="$1" '$1 == k { print $2 }' "$PLAYPORT_REPO/pins.lock")
    [ -n "$v" ] || { echo "pins.lock has no $1" >&2; return 1; }
    echo "$v"
}

# pin_url NAME: the repository pins.lock records for NAME.
pin_url() { awk -v k="$1" '$1 == k { print $3 }' "$PLAYPORT_REPO/pins.lock"; }

# mirror NAME REV: a bare clone of NAME's pins.lock repository in the cache
# ($CACHE, default $PLAYPORT_BUILD/cache) that has REV; fetched only when it lacks REV.
mirror() {
    local mm=${CACHE:-$PLAYPORT_BUILD/cache}/$1.git
    mkdir -p "$(dirname "$mm")"
    test -d "$mm" || git clone -q --bare "$(pin_url "$1")" "$mm"
    git -C "$mm" cat-file -e "$2^{commit}" 2>/dev/null ||
        git -C "$mm" fetch -q "$(pin_url "$1")" "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"
    echo "$mm"
}

# series TARGET: the patch files of patches/TARGET, in order.
series() {
    local d=$PLAYPORT_REPO/patches/$1
    grep -v -e '^#' -e '^$' "$d/series" | sed "s|^|$d/|"
}

# apply_series TREE TARGET: git am -3 the series onto TREE, which must be
# clean and at its pin. The commits carry the patch authors; the committer is
# fixed so the resulting tree and history do not depend on who builds. A
# submodule is left out of the cleanliness check: ensure_series' checkout of the
# pin leaves it where its own series put it (FEX's External/rpmalloc), and it is
# checked on its own.
apply_series() {
    local tree=$1 target=$2
    git -C "$tree" diff --quiet --ignore-submodules=all HEAD || { echo "$tree has local changes" >&2; return 1; }
    # shellcheck disable=SC2046
    GIT_COMMITTER_NAME=build-from-pins GIT_COMMITTER_EMAIL=build@localhost \
        GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
        git -C "$tree" am -3 --quiet $(series "$target")
    echo "$target: $(series "$target" | wc -l) patches on $(git -C "$tree" rev-parse --short=12 HEAD)"
}

# series_ids TARGETS: the stable patch-id of each patch of TARGETS, in order.
# Only the part from the first `---` line is read: patch-id takes a message
# line that starts with "diff " for the start of a diff (wine-port 0035 has one).
series_ids() {
    local t f
    for t in $1; do
        for f in $(series "$t"); do sed -n '/^---$/,$p' "$f" | git patch-id --stable | cut -d' ' -f1; done
    done
}

# check_series TREE TARGETS PIN [SUBMODULE]: TREE is PIN plus exactly the series
# of each of TARGETS (one name, or several separated by spaces, applied in that
# order), clean. The commits are compared by content (patch-id), so a patch
# edited in place makes the tree stale. A SUBMODULE path is left out of the
# cleanliness check (it carries a series of its own and is checked separately).
check_series() {
    local tree=$1 targets=$2 pin=$3 n=0 t
    local exclude=()
    [ -z "${4:-}" ] || exclude=(-- . ":(exclude)$4")
    for t in $targets; do n=$((n + $(series "$t" | wc -l))); done
    [ "$(git -C "$tree" rev-parse "HEAD~$n" 2>/dev/null)" = "$(git -C "$tree" rev-parse "$pin^{commit}")" ] &&
        [ "$(git -C "$tree" log --format=%s "$pin..HEAD" | wc -l)" = "$n" ] &&
        [ "$(git -C "$tree" log --reverse -p --format='commit %H' "$pin..HEAD" -- "${exclude[@]:1}" |
             git patch-id --stable | cut -d' ' -f1)" = "$(series_ids "$targets")" ] &&
        git -C "$tree" diff --quiet HEAD "${exclude[@]}" ||
        { echo "$tree is not $pin plus the $targets series" >&2; return 1; }
}

# ensure_series TREE TARGETS PIN [SUBMODULE]: make TREE PIN plus the series of
# TARGETS: nothing when check_series already holds, else check out PIN (which
# drops a stale or partial application, not untracked build outputs) and
# apply each series again.
ensure_series() {
    local tree=$1 targets=$2 pin=$3 t
    check_series "$tree" "$targets" "$pin" "${4:-}" 2>/dev/null && return 0
    echo "$tree: (re)applying $targets onto $pin"
    git -C "$tree" am --abort 2>/dev/null || true
    git -C "$tree" -c advice.detachedHead=false checkout -q -f "$pin"
    for t in $targets; do apply_series "$tree" "$t"; done
    check_series "$tree" "$targets" "$pin" "${4:-}"
}

# ios_cxx_stdlib: the flag that points an iOS C++ compile with the host clang
# at the SDK's libc++ headers. For an Apple target clang takes them from beside
# itself (<bin>/../include/c++/v1) before the SDK's, so a host with libc++
# installed (Arch's /usr/include/c++/v1) compiles against upstream headers.
# Those carry no Apple availability markup: they call libc++.1.dylib functions
# newer than the deployment target, std::__hash_memory (LLVM 21) first, and dyld
# refuses the app on an older iOS ("Symbol not found: __ZNSt3__113__hash_memoryEPKvm"
# on iOS 26.1). -stdlib++-isystem replaces that search; the SDK's headers gate
# each such call on the target's minos (build/verify-ipa.py "libc++").
ios_cxx_stdlib() {
    local d=$IOSSDK/usr/include/c++/v1
    [ -f "$d/__config" ] || d=$DARWIN_SDK/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1
    [ -f "$d/__config" ] ||
        { echo "no libc++ headers in the iPhoneOS SDK ($IOSSDK) or its toolchain" >&2; return 1; }
    echo "-stdlib++-isystem $d"
}
