#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# trial.sh ONTO RANGE BRANCH: cherry-pick each commit of RANGE onto ONTO in a
# new BRANCH; on a conflict, record the files and conflict hunks, then take the
# picked commit's side (-X theirs) so the count continues.
set -u
onto=$1 range=$2 br=$3
git checkout -q -B "$br" "$onto"
n=0 conf=0 hunks=0 empty=0
for c in $(git rev-list --reverse --no-merges "$range"); do
    n=$((n+1))
    s=$(git log -1 --format=%s "$c")
    if git cherry-pick --allow-empty -x "$c" >/dev/null 2>&1; then
        :
    else
        files=$(git diff --name-only --diff-filter=U)
        if [ -z "$files" ]; then
            # nothing conflicted: an empty pick
            git cherry-pick --skip >/dev/null 2>&1 || git cherry-pick --abort
            empty=$((empty+1)); echo "EMPTY $c $s"; continue
        fi
        h=0
        for f in $files; do
            k=$(grep -c '^<<<<<<< ' "$f" 2>/dev/null || true)
            h=$((h + ${k:-0}))
        done
        conf=$((conf+1)); hunks=$((hunks+h))
        echo "CONFLICT $c hunks=$h files=$(echo $files | tr ' ' ',') $s"
        git cherry-pick --abort
        if ! git cherry-pick --allow-empty -x -X theirs "$c" >/dev/null 2>&1; then
            # modify/delete and similar: take the commit's files as they are
            git checkout --theirs -- . 2>/dev/null
            git add -A && git -c core.editor=true cherry-pick --continue >/dev/null 2>&1 || { echo "STUCK $c"; git cherry-pick --abort; }
        fi
    fi
done
echo "TOTAL commits=$n conflicting=$conf hunks=$hunks empty=$empty"
