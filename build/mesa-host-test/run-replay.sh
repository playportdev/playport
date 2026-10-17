#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Replay captured Fossilize databases on the host mock of KosmicKrisp and
# group the pipelines that crash by their message. It builds no driver: the
# hosttest stage (build/stages/mesa.sh ROOT hosttest) must have made the mock
# driver and its ICD manifest.
#
#   build/mesa-host-test/run-replay.sh [--bypass-feature-gate] FOZ...
#
# --bypass-feature-gate  builds vk-replay-gate/ into $PLAYPORT_BUILD/run/replay/
#                   replay-gate-layer/ and replays under it: Fossilize then
#                   takes the modules it refuses for a capability the driver
#                   does not report but compiles anyway (ImageMSArray, float
#                   controls; the list is in replay-gate.c). The modules that
#                   relied on it are listed, and saved, in NAME/gate/.
# KK_MOCK_ICD       the mock's ICD manifest, default
#                   $PLAYPORT_BUILD/run/mesa/hosttest/kk-mock-icd.json
# FOSSILIZE_REPLAY  fossilize_replay, default the one on PATH (Steam ships one
#                   in ubuntu12_64/)
# REPLAY_OUT        logs, default $PLAYPORT_BUILD/run/replay/NAME/ per database
# JOBS              parallel single-pipeline replays, default nproc
#
# Fossilize's master replays the database in child processes and names each
# pipeline that crashed; its children's stderr is not kept. Each crashed
# pipeline is then replayed alone, which shows the assertion or message.
# Fossilize skips the pipelines that share a module with one that crashed, so
# the crash count moves a little between runs and falls as crashes are fixed
# only to show what they hid.
#
# Exit status: 0 when no pipeline crashed, 1 when one did, 2 on a usage error.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib.sh"
GATE=
[ "${1:-}" = --bypass-feature-gate ] && { GATE=1; shift; }
[ $# -gt 0 ] || { echo "usage: $0 [--bypass-feature-gate] FOZ..." >&2; exit 2; }
ICD=$(realpath -m "${KK_MOCK_ICD:-$PLAYPORT_BUILD/run/mesa/hosttest/kk-mock-icd.json}")
REPLAY=${FOSSILIZE_REPLAY:-$(command -v fossilize_replay || true)}
JOBS=${JOBS:-$(nproc)}
[ -f "$ICD" ] || { echo "no mock ICD at $ICD (build/stages/mesa.sh ROOT hosttest, or KK_MOCK_ICD)" >&2; exit 2; }
[ -n "$REPLAY" ] && [ -x "$REPLAY" ] || { echo "no fossilize_replay (FOSSILIZE_REPLAY)" >&2; exit 2; }

# Only the mock, no layers, no window system, no shader cache.
export VK_DRIVER_FILES=$ICD VK_LOADER_LAYERS_DISABLE='~all~' MESA_SHADER_CACHE_DISABLE=true
unset DISPLAY WAYLAND_DISPLAY VK_ICD_FILENAMES VK_ADD_DRIVER_FILES
if [ -n "$GATE" ]; then
    layer=$(realpath -m "$PLAYPORT_BUILD/run/replay/replay-gate-layer")
    mkdir -p "$layer"
    cc -shared -fPIC -O1 -Wall -o "$layer/libpp_replay_gate.so" "$HERE/vk-replay-gate/replay-gate.c" -lpthread
    cp "$HERE/vk-replay-gate/replay-gate.json" "$layer/"
    export VK_ADD_IMPLICIT_LAYER_PATH=$layer ENABLE_PP_REPLAY_GATE=1 VK_LOADER_LAYERS_ENABLE='*PLAYPORT_replay_gate'
fi

# single FOZ KIND START LOG: replay one pipeline alone; LOG gets its output.
single() {
    "$REPLAY" --num-threads 1 "--$2-pipeline-range" "$3" "$(($3 + 1))" "$1" >"$4" 2>&1 || true
}

# message LOG: the crash's message, with addresses and numbers that differ
# between pipelines of one defect folded away.
message() {
    local m
    m=$(grep -v '^Fossilize ' "$1" | grep -v '^\[kk-' | tail -n 1 || true)
    if [ -z "$m" ]; then
        grep -q 'crashed or hung' "$1" && m="no message (signal or hang)" || m="did not crash when replayed alone"
    fi
    printf '%s\n' "$m" | sed -E 's/^fossilize_replay: //; s/0x[0-9a-fA-F]+/0x?/g'
}

status=0
for foz in "$@"; do
    foz=$(realpath "$foz")
    name=$(basename "$foz" .foz)
    out=$(realpath -m "${REPLAY_OUT:-$PLAYPORT_BUILD/run/replay}/$name")
    rm -rf "$out"; mkdir -p "$out/single"
    [ -n "$GATE" ] && export PP_REPLAY_GATE_OUT=$out/gate
    "$REPLAY" --progress "$foz" >"$out/master.log" 2>&1 || true

    # "graphics pipeline crashed or hung: HASH. Repro with: --graphics-pipeline-range A B"
    sed -nE 's/.* (graphics|compute|raytracing) pipeline crashed or hung: [0-9a-f]+\. Repro with: --[a-z]+-pipeline-range ([0-9]+) [0-9]+.*/\1 \2/p' \
        "$out/master.log" | sort -u >"$out/crashed.txt"
    while read -r kind start; do
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
        single "$foz" "$kind" "$start" "$out/single/$kind-$start.log" &
    done <"$out/crashed.txt"
    wait

    echo "== $name ($foz)"
    awk '/Progress report/ { n = NR } { line[NR] = $0 } END {
        for (i = n + 1; i <= NR && line[i] !~ /=====/; i++) { sub(/^Fossilize INFO: +/, "", line[i]); print "  " line[i] } }' \
        "$out/master.log"
    if [ -n "$GATE" ]; then
        gated=$(cat "$out"/gate/replay-gate.*.log 2>/dev/null | awk '$1 == "module" { print $2 }' | sort -u | wc -l)
        echo "  feature gate bypassed for $gated modules (listed and saved in $out/gate)"
    fi
    crashes=$(wc -l <"$out/crashed.txt")
    echo "  crashed pipelines: $crashes (logs in $out)"
    [ "$crashes" -eq 0 ] && continue
    status=1
    while read -r kind start; do
        printf '%s\t%s %s\n' "$(message "$out/single/$kind-$start.log")" "$kind" "$start"
    done <"$out/crashed.txt" >"$out/messages.tsv"
    printf '  %5s  %-9s  %-12s  %s\n' count kind 'e.g. range' message
    sort -t "$(printf '\t')" -k1,1 "$out/messages.tsv" | awk -F '\t' '
        { split($2, k, " "); key = $1 "\t" k[1]; n[key]++; if (!(key in ex)) ex[key] = k[2] }
        END { for (key in n) { split(key, f, "\t"); printf "  %5d  %-9s  %-12s  %s\n", n[key], f[2], ex[key] " " ex[key] + 1, f[1] } }' |
        sort -rn
done
exit $status
