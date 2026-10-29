# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the startup replay shipped in wine-pe 0055 (PLA-476)."""
import pathlib
import re
import signal
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / 'patches/wine-pe/0055-ntdll-replay-early-images-after-the-emulator-starts.patch'


def first_hunk(patch):
    # Count both sides so blank context is preserved only inside the hunk,
    # never in the message, signature or following diff metadata.
    header = re.search(r'^@@ -\d+,(\d+) \+\d+,(\d+) @@[^\n]*\n', patch, re.M)
    assert header is not None
    old, new = map(int, header.groups())
    lines = []
    for line in patch[header.end():].splitlines():
        if old == new == 0:
            break
        line = line or ' '  # git accepts an empty line as blank context
        assert line[0] in ' +-'
        old -= line[0] in ' -'
        new -= line[0] in ' +'
        assert old >= 0 and new >= 0
        lines.append(line)
    assert old == new == 0
    return lines


def startup_phase(replay_patch=None):
    # 0008 carries the complete init phase; apply 0055's actual before/after
    # hunk to it, without depending on a configured Wine build tree.
    trace = ROOT / 'patches/wine-port/0008-loader-trace-load_arm64ec_module-arm64ec_process_ini.patch'
    hunk = first_hunk(trace.read_text())
    source = '\n'.join(line[1:] for line in hunk if line.startswith((' ', '+')))
    if replay_patch is not None:
        hunk = first_hunk(replay_patch)
        before = '\n'.join(line[1:] for line in hunk if line.startswith((' ', '-')))
        after = '\n'.join(line[1:] for line in hunk if line.startswith((' ', '+')))
        assert source.count(before) == 1
        source = source.replace(before, after)
    return source.split('/* Phase 2:', 1)[1].split('*/', 1)[1].split('\n}\n', 1)[0]


HARNESS = r'''
#include <assert.h>
#include <stddef.h>
#include <stdlib.h>

typedef struct list { struct list *Flink, *Blink; } LIST_ENTRY;
typedef struct module { LIST_ENTRY InLoadOrderLinks; void *DllBase; } LDR_DATA_TABLE_ENTRY;
struct ldr { LIST_ENTRY InLoadOrderModuleList; } ldr;
struct peb { struct ldr *LdrData; } peb = { &ldr };
struct teb { struct peb *Peb; } teb = { &peb };
#define NtCurrentTeb() (&teb)
#define CONTAINING_RECORD(p,t,f) ((t *)((char *)(p) - offsetof(t,f)))
#define ERR(...) ((void)0)
#define GetCurrentProcess() 0

static LDR_DATA_TABLE_ENTRY modules[5]; /* main, ntdll, queued map, kernel32, kernelbase */
static struct { LDR_DATA_TABLE_ENTRY ldr; } emulator, *wm = &emulator;
static unsigned registered, notifications, ready, failed;
static unsigned phase_calls;

/* Existing intervals-only export: unavailable before ProcessInit; duplicate
 * inserts are idempotent. Full map/ImageTracker callbacks must not be called. */
static void arm64ec_notify_image_map(void *base)
{
    unsigned i = (LDR_DATA_TABLE_ENTRY *)base - modules;
    assert(i < 5);
    if (!ready) return;
    notifications++;
    registered |= 1u << i;
}
static int arm64ec_process_init(void *base)
{
    (void)base;
    phase_calls++;
    if (failed) return 1;
    ready = 1;
    /* FEX already registered main, ntdll, and a queued syscall notification. */
    registered |= 7;
    return 0;
}
static void NtTerminateProcess(int process, int status)
{
    (void)process;
    assert(status && failed && !notifications);
    exit(42);
}
static void startup(void)
{
    int status;
SHIPPED_PHASE
}
int main(int argc, char **argv)
{
    (void)argv;
    LIST_ENTRY *list = &ldr.InLoadOrderModuleList;
    list->Flink = &modules[0].InLoadOrderLinks;
    list->Blink = &modules[4].InLoadOrderLinks;
    for (unsigned i = 0; i < 5; i++) {
        modules[i].DllBase = &modules[i];
        modules[i].InLoadOrderLinks.Flink = i == 4 ? list : &modules[i+1].InLoadOrderLinks;
        modules[i].InLoadOrderLinks.Blink = i ? &modules[i-1].InLoadOrderLinks : list;
        arm64ec_notify_image_map(modules[i].DllBase); /* too early: no tracker/export */
    }
    assert(!registered && !notifications);
    failed = argc > 1;
    startup();
    assert(phase_calls == 1);
    assert(registered == 31); /* LoadLibraryExW's early kernel32 is now covered too */
    assert(notifications == 5);
    startup();
    assert(phase_calls == 2 && registered == 31 && notifications == 10);
    /* Empty loader list: nothing dereferenced or notified. */
    list->Flink = list->Blink = list;
    startup();
    assert(registered == 31 && notifications == 10);
    return 0;
}
'''


class Arm64ecEarlyImagesTests(unittest.TestCase):
    def test_blank_context_forms_reconstruct_identical_startup_source(self):
        normalized = PATCH.read_text()
        context = '\n }\n\n #endif\n'
        self.assertEqual(normalized.count(context), 1)
        conventional = normalized.replace(context, '\n }\n \n #endif\n') + '-- \n2.56.0\n\n'
        self.assertEqual(startup_phase(normalized), startup_phase(conventional))

    def test_startup_replays_dependencies_after_successful_emulator_init(self):
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / 'test.c').write_text(HARNESS.replace('SHIPPED_PHASE', startup_phase(PATCH.read_text())))
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=undefined', str(d / 'test.c'), '-o', str(d / 'test')], check=True)
            subprocess.run([str(d / 'test')], check=True)
            failed = subprocess.run([str(d / 'test'), 'fail-init'])
            self.assertEqual(failed.returncode, 42, 'failed init must terminate before replay')
            (d / 'before.c').write_text(HARNESS.replace('SHIPPED_PHASE', startup_phase()))
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(d / 'before.c'), '-o', str(d / 'before')], check=True)
            baseline = subprocess.run([str(d / 'before')], cwd=d, capture_output=True, text=True)
            self.assertEqual(baseline.returncode, -signal.SIGABRT)
            self.assertIn('registered == 31', baseline.stderr)
