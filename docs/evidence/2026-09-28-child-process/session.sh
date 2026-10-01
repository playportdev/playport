#!/bin/sh
# One device-lock session (pp phone lock -- sh THIS): the child-process proof.
#   a: the scratch IPA, PLAYPORT_CHILDTEST=x64: an x86-64 root starts two window
#      children of itself and waits for each, then Hollow Knight as its child;
#      the pad quits Hollow Knight, and the root's wait on it must return.
#   b: the same with an ARM64EC root (PLAYPORT_CHILDTEST=ec).
#   c: the branch's own IPA, Hollow Knight as the one process (the shipped path).
set -u
SCRATCH=$1
BRANCH=$2
OUT=$3
mkdir -p "$OUT"
ENV_X64='app-367520:{"environment":[{"name":"PLAYPORT_CHILDTEST","value":"x64"}]}'
ENV_EC='app-367520:{"environment":[{"name":"PLAYPORT_CHILDTEST","value":"ec"}]}'

./pp install --ipa "$SCRATCH" > "$OUT/install-scratch.log" 2>&1 || { echo "install scratch failed"; exit 1; }

# a
./pp ui --expect-ipa "$SCRATCH" --settings "$ENV_X64" --play app-367520 \
    --until first-frame+10 --wait 240 --shot --out "$OUT/a" > "$OUT/a.jsonl" 2>&1
echo "a: ui exit $?"
./pp phone crashes "$OUT/a-crashes" > "$OUT/a-crashes.log" 2>&1

# b
./pp ui --expect-ipa "$SCRATCH" --settings "$ENV_EC" --play app-367520 \
    --until first-frame+15 --wait 240 --shot --out "$OUT/b" > "$OUT/b.jsonl" 2>&1
echo "b: ui exit $?"
./pp phone crashes "$OUT/b-crashes" > "$OUT/b-crashes.log" 2>&1

# c
./pp install --ipa "$BRANCH" > "$OUT/install-branch.log" 2>&1 || { echo "install branch failed"; exit 1; }
./pp ui --expect-ipa "$BRANCH" --settings 'app-367520:{}' --play app-367520 \
    --until first-frame+10 --wait 240 --shot --out "$OUT/c" > "$OUT/c.jsonl" 2>&1
echo "c: ui exit $?"
echo "session done"
