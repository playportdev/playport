#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regenerate only GN, never rerun CEF's stock patcher over our patched sources.
set -euo pipefail
adapter_dir="$(cd "$(dirname "$0")" && pwd)"
source "$adapter_dir/env-win.sh"
trap 'rc=$?; printf "%s\n" "$rc" > "$CEF_WORK/logs/project-files-lowva.exit"' EXIT
python3 - "$adapter_dir/args.gn" <<'PY'
import json
import os
from pathlib import Path
import sys

work = Path(os.environ['CEF_WORK'])
out = work / 'src/out/Release_GN_x64_lowva'
out.mkdir(parents=True, exist_ok=True)
args = Path(sys.argv[1]).read_text()
for key, path in (
    ('visual_studio_path', work / 'tools/vs-xwin'),
    ('windows_sdk_path', work / 'tools/vs-xwin/Windows Kits/10'),
):
    args += f'{key}={json.dumps(str(path))}\n'
(out / 'args.gn').write_text(args)
PY
cd "$CEF_WORK/src"
gn gen out/Release_GN_x64_lowva
