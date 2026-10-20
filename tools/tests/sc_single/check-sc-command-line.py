#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the production post-preflight helper classification and switch merge."""
import os
from pathlib import Path
import subprocess
import tempfile

from source import ROOT, SCRATCH, PATCH, added_file

refusal = next((ROOT / 'patches/madeira-unix').glob('0177-*.patch')).read_text()
part = refusal.split('+++ b/build/ntdll-unix/pp_game_sc_refuse.h\n', 1)[1].split('diff --git ', 1)[0]
name_header = '\n'.join(line[1:] for line in part.splitlines() if line.startswith('+'))

TEST = r'''
#include <assert.h>
#include <string.h>
#include <stdint.h>
typedef uint16_t WCHAR;
#include "pp_game_sc_refuse.h"
#include "pp_sc_single_cmdline.h"
static int wide(WCHAR *out, const char *s) {
    int i; for (i = 0; s[i]; i++) out[i] = (unsigned char)s[i]; out[i] = 0; return i;
}
int main(void) {
    WCHAR image[128], cmd[2048], out[2304]; char result[2304]; int n, how;
    int il = wide(image, "C:\\Social Club\\SOCIALCLUBHELPER.EXE");
    int cl = wide(cmd, "helper.exe --disable-features=Existing --lang=en");
    assert(sc_helper_kind(image, il, cmd, cl) == SC_BROWSER);
    n = sc_browser_cmdline(cmd, cl, 1, NULL, out, 2304, &how);
    assert(n > 0 && out[n] == 0);
    for (int i = 0; i <= n; i++) result[i] = out[i];
    assert(strstr(result, "--disable-features=PartitionAllocBackupRefPtr,Existing"));
    assert(strstr(result, " --single-process"));
    assert(strstr(result, " --js-flags=--jitless"));
    assert(strstr(result, " --no-proxy-server"));
    cl = wide(cmd, "helper.exe --type=renderer");
    assert(sc_helper_kind(image, il, cmd, cl) == SC_CHILD);
    cl = wide(cmd, "helper.exe --type=gpu-process");
    assert(sc_helper_kind(image, il, cmd, cl) == SC_CHILD);
    cl = wide(cmd, "helper.exe --type=utility");
    assert(sc_helper_kind(image, il, cmd, cl) == SC_CHILD);
    il = wide(image, "C:\\OtherHelper.exe");
    assert(sc_helper_kind(image, il, cmd, cl) == SC_NOT_HELPER);
    cl = wide(cmd, "helper --single-process --js-flags=--own --proxy-pac-url=http://example.invalid/pac --disable-features=First --disable-features=Last");
    n = sc_browser_cmdline(cmd, cl, 1, NULL, out, 2304, &how);
    for (int i = 0; i <= n; i++) result[i] = out[i];
    assert(!strstr(result, "--no-proxy-server"));
    assert(!strstr(result, "--js-flags=--jitless"));
    assert(strstr(result, "--disable-features=First --disable-features=PartitionAllocBackupRefPtr,Last"));
    assert(!(how & SC_SINGLE_ADDED) && (how & SC_OWN_JS_FLAGS));
    assert(sc_browser_cmdline(cmd, cl, 1, NULL, out, 1, &how) == -1);
    return 0;
}
'''
with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='sc-command-line-') as td:
    folder = Path(td)
    (folder / 'pp_game_sc_refuse.h').write_text(name_header)
    (folder / 'pp_sc_single_cmdline.h').write_text(added_file('pp_sc_single_cmdline.h'))
    (folder / 'test.c').write_text(TEST)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', str(folder / 'test.c'), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)

process = PATCH.read_text().split('+++ b/build/ntdll-unix/process_ios.c', 1)[1].split('diff --git ', 1)[0]
assert process.index('playport_sc_single_enabled()') < process.index('verified = pp_sc_single_preflight( fd )')
assert process.index('verified = pp_sc_single_preflight( fd )') < process.index('if (verified && kind == SC_CHILD)')
assert process.index('if (verified)') < process.index('sc_browser_cmdline( params->CommandLine.Buffer')
assert 'if (!sc_single) chromium_policy( &path, params );' in process
assert 'pp_sc_single_mapping = args->sc_single;' in process
assert 'args->sc_single = sc_single;' in process
print('PASS: helper-only classification, child kinds, flag/feature merges, proxy preservation, overflow and preflight-first wiring')
