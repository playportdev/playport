#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build-output patch digests, matching source-bundle.py's series_digests.
# Hash every top-level .patch in byte filename order, not locale/glob order.
set -euo pipefail
export LC_ALL=C
shopt -s nullglob
for target in "$1"/*/; do
    patches=("$target"*.patch)
    digest=$(
        if [ "${#patches[@]}" -gt 0 ]; then cat "${patches[@]}"; fi |
            sha256sum | cut -c1-16
    )
    echo "series $(basename "$target") $digest"
done
