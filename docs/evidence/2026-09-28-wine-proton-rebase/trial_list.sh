#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# trial_list.sh ONTO LIST BRANCH: cherry-pick the commits in LIST onto ONTO, in
# order, into BRANCH; a conflicting commit is recorded and skipped.
set -u
onto=$1 list=$2 br=$3
git checkout -q -B "$br" "$onto"
n=0 conf=0 hunks=0 empty=0
while read -r c s; do
    n=$((n+1))
    if git cherry-pick -x "$c" >/dev/null 2>&1; then continue; fi
    files=$(git diff --name-only --diff-filter=U)
    if [ -z "$files" ]; then
        git cherry-pick --skip >/dev/null 2>&1 || git cherry-pick --abort
        empty=$((empty+1)); echo "EMPTY $c $s"; continue
    fi
    h=0
    for f in $files; do k=$(grep -c '^<<<<<<< ' "$f" 2>/dev/null || true); h=$((h + ${k:-0})); done
    conf=$((conf+1)); hunks=$((hunks+h))
    echo "CONFLICT $c hunks=$h files=$(echo $files | tr ' ' ',') $s"
    git cherry-pick --abort
done < "$list"
echo "TOTAL commits=$n conflicting=$conf hunks=$hunks empty=$empty applied=$(git rev-list --count $onto..HEAD)"
