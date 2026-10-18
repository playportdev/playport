#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# msl-compile.sh: compile MSL that KosmicKrisp generated (the mock's
# KK_MOCK_MSL_DIR output) with Apple's Metal Developer Tools for Windows, run
# under Wine, one `metal -c` per file to AIR, and group the failures by first
# error. Front end only: no GPU back end, linking or pipeline state.
#
#   build/mesa-host-test/msl-compile.sh [-j JOBS] [-o OUTDIR] [-k] [-x FLAG]... INPUT...
#
# INPUT: .metal files or directories (every *.metal directly inside).
# -j     parallel jobs (default: nproc/2)
# -o     output directory (default: ./msl-compile.out); gets results.tsv,
#        groups.tsv, flags.txt, inputs.txt and logs/
# -k     keep the .air outputs (default: deleted after each compile)
# -x     extra compiler flag (repeatable), e.g. -x -std=metal3.2 to override
#        the default std
#
# Environment:
#   METAL_EXE   metal.exe, as a Unix path or a Windows path (required). Use the
#               real compiler metal/<build>/bin/metal.exe; bin/metal.exe is a
#               shim that forwards to it.
#   WINEPREFIX  the prefix the tools were installed into (required); the
#               installer (an Apple account download, never committed) installs
#               silently with /S /D=C:\MetalTools
#   WINE        wine binary (default: wine)
#   MSL_STD     default -std (default: metal4.0, the newest tools 6.2 accept;
#               the phone, on iOS 27, compiles at 4.1)
#   MSL_TARGET  default -target (default: air64-apple-ios26.0)
#   MSL_MATH    -fmetal-math-mode (default: fast, as KosmicKrisp's
#               mtl_new_library callers)
#   MSL_FP32    -fmetal-math-fp32-functions (default: fast, as above)
#
# Exit status: 0 when every file compiled, 1 when one did not, 2 on a usage
# error. Wine's persistent processes inherit stdio, so every wine call here
# writes to a file and never into a pipe; a wineserver started here exits 30 s
# after its last client.
set -euo pipefail

jobs=$(( $(nproc) / 2 )); [ "$jobs" -ge 1 ] || jobs=1
out=./msl-compile.out
keep=0
extra=()
while getopts "j:o:kx:h" opt; do
  case $opt in
    j) jobs=$OPTARG ;;
    o) out=$OPTARG ;;
    k) keep=1 ;;
    x) extra+=("$OPTARG") ;;
    h) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { echo "msl-compile.sh: no input (see -h)" >&2; exit 2; }
[ -n "${METAL_EXE:-}" ] || { echo "msl-compile.sh: set METAL_EXE to metal.exe" >&2; exit 2; }
[ -n "${WINEPREFIX:-}" ] || { echo "msl-compile.sh: set WINEPREFIX to the prefix holding the Metal tools" >&2; exit 2; }
export WINEPREFIX
export WINE=${WINE:-wine}
export WINEDEBUG=${WINEDEBUG:--all}
export BROWSER=/bin/false
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-winebrowser.exe=d;mscoree=d;mshtml=d}
unset DISPLAY WAYLAND_DISPLAY

# wine takes the program as a Unix path or a Windows path, not a Z: path.
case $METAL_EXE in
  /*) metal_win=$(realpath -- "$METAL_EXE") ;;
  *) metal_win=$METAL_EXE ;;
esac

mkdir -p "$out/logs" "$out/air"
out=$(realpath -- "$out")
list=$out/inputs.txt
: > "$list"
for in in "$@"; do
  if [ -d "$in" ]; then
    find "$(realpath -- "$in")" -maxdepth 1 -name '*.metal' -type f | sort >> "$list"
  else
    realpath -- "$in" >> "$list"
  fi
done
total=$(wc -l < "$list")
[ "$total" -ge 1 ] || { echo "msl-compile.sh: no .metal files" >&2; exit 2; }

flags=(-std="${MSL_STD:-metal4.0}" -target "${MSL_TARGET:-air64-apple-ios26.0}"
       -fmetal-math-mode="${MSL_MATH:-fast}" -fmetal-math-fp32-functions="${MSL_FP32:-fast}"
       "${extra[@]}")
printf '%s\n' "$metal_win" "${flags[@]}" > "$out/flags.txt"

"${WINESERVER:-wineserver}" -p 30 > /dev/null 2>&1 < /dev/null || true

# FLAGS is set by the xargs wrapper below, in the child shell.
# shellcheck disable=SC2153
compile_one() {
  local src=$1 name
  name=$(basename -- "$src" .metal)
  # Directory inputs may share basenames; prefix with the parent directory's name.
  name="$(basename -- "$(dirname -- "$src")")__$name"
  local log=$OUT/logs/$name.log air=$OUT/air/$name.air rc=0
  "$WINE" "$METAL_WIN" "${FLAGS[@]}" -c "Z:${src//\//\\}" -o "Z:${air//\//\\}" \
    > "$log" 2>&1 < /dev/null || rc=$?
  [ "$KEEP" = 1 ] || rm -f -- "$air"
  # Drop host driver chatter Wine prints on start (not from the compiler).
  sed -i '/^WARNING: radv is not a conformant/d' "$log"
  local first
  first=$(grep -m1 -E '(^|: )(fatal )?error: ' "$log" || true)
  if [ "$rc" -ne 0 ] && [ -z "$first" ]; then first="no-diagnostic rc=$rc: $(head -c 200 "$log" | tr '\n\t' '  ')"; fi
  printf '%s\t%s\t%s\n' "$name" "$rc" "$first"
}
export -f compile_one
export OUT=$out METAL_WIN=$metal_win KEEP=$keep
# Arrays cannot be exported; pass the flags through a NUL-separated variable.
FLAGS_STR=$(printf '%s\x1f' "${flags[@]}")
export FLAGS_STR

# shellcheck disable=SC2016  # expanded by the child bash, not here
xargs -a "$list" -d '\n' -P "$jobs" -n 1 bash -c '
  IFS=$'"'"'\x1f'"'"' read -r -a FLAGS <<< "$FLAGS_STR"; compile_one "$1"' _ \
  > "$out/results.unsorted.tsv"
sort -t $'\t' -k1,1 "$out/results.unsorted.tsv" > "$out/results.tsv"
rm -f "$out/results.unsorted.tsv"
[ "$keep" = 1 ] || rmdir "$out/air" 2>/dev/null || true

# Group failures: strip the location prefix, then replace quoted names (not quoted
# punctuation such as ';') and numbers.
awk -F'\t' '$2 != 0 {
    m = $3
    sub(/^.*(fatal )?error: /, "error: ", m)
    gsub(/\047[A-Za-z_][^\047]*\047/, "\047X\047", m)
    gsub(/"[^"]*"/, "\"X\"", m)
    gsub(/[0-9]+/, "N", m)
    print m
  }' "$out/results.tsv" | sort | uniq -c | sort -rn \
  | awk '{ n = $1; $1 = ""; sub(/^ /, ""); printf "%d\t%s\n", n, $0 }' > "$out/groups.tsv"

fail=$(awk -F'\t' '$2 != 0' "$out/results.tsv" | wc -l)
printf 'msl-compile: %d files, %d compiled, %d failed; results: %s\n' \
  "$total" "$((total - fail))" "$fail" "$out"
[ "$fail" -eq 0 ]
