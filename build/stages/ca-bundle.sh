#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetches the trusted root certificates the runtime ships as
# Runtime/certs/cacert.pem (docs/ARCHITECTURE.md, "Trusted roots"): Mozilla's
# root store as curl publishes it, the dated extract pins.lock's ca-bundle row
# names, checked against its sha256 below. Moving it is by hand, to the newest
# extract before each release (docs/BUILDING.md, "The trusted roots").
#
#   build/stages/ca-bundle.sh
#
# The file is cached as $PLAYPORT_BUILD/cache/ca-bundle-<date>/cacert.pem;
# build/stages/stage-artifacts.py stages it from there unmodified, and
# build/notices-assemble.sh takes its header from it.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

SHA256=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
date=$(pin ca-bundle)
url=$(pin_url ca-bundle)/cacert-$date.pem
cache=$PLAYPORT_BUILD/cache/ca-bundle-$date
pem=$cache/cacert.pem

# Written to a private temporary beside its final path, then moved into place: two
# builds (a pp sync candidate's and this checkout's) may share this cache.
tmps=()
trap 'rm -rf "${tmps[@]}"' EXIT
mkdir -p "$cache"
if ! echo "$SHA256  $pem" | sha256sum -c --status 2>/dev/null; then
    part=$(mktemp "$cache/pem.XXXXXX"); tmps+=("$part")
    curl -fsSL -o "$part" "$url"
    echo "$SHA256  $part" | sha256sum -c --status || { echo "stage-ca-bundle: $url is not sha256 $SHA256" >&2; exit 1; }
    mv "$part" "$pem"
fi
echo "ca-bundle $date: $(grep -c 'BEGIN CERTIFICATE' "$pem") roots, $(sha256sum "$pem" | cut -c1-16) cacert.pem"
