#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Host candidate scalar helper ABI checks; no FEX helper-call emission."""
import hashlib
from pathlib import Path
import resource
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    output = ROOT / ".work/guest32/scalar-helper"
    output.mkdir(parents=True, exist_ok=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    source = ROOT / "build/guest32/scalar_access.c"
    test = ROOT / "build/guest32/scalar_access_test.c"
    memory = ROOT / "build/guest32/guest32.c"
    for path in (source, source.with_suffix(".h"), test, memory):
        print(f"sha256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(ROOT)}", flush=True)

    def compile_test(name, code=source, sanitize=False):
        executable = output / name
        flags = ["-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"] if sanitize else []
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", *flags,
                        "-I", str(source.parent), str(memory), str(code), str(test), "-o", str(executable)],
                       check=True, timeout=60)
        return executable

    for sanitize in (False, True):
        executable = compile_test("sanitized" if sanitize else "optimized", sanitize=sanitize)
        subprocess.run([str(executable)], check=True, timeout=60)
    text = source.read_text()
    controls = [
        ("native-address-truncation", " || address > UINT32_MAX", ""),
        ("store-width-truncation", "g32_write(space, (uint32_t)address, bytes, width)",
         "g32_write(space, (uint32_t)address, bytes, 1)"),
        ("rejected-value-clobber", "return pack(status, value);", "return pack(status, status == G32_OK ? value : 0);"),
        ("partial-register-clobber", "if (status == G32_OK) {", "if (status == G32_OK) {\n            value = 0;"),
        ("big-endian-store", "value >> (i * 8)", "value >> ((width - 1 - i) * 8)"),
        ("result-status-packing", "(uint64_t)status << 32", "(uint64_t)status << 16"),
    ]
    for name, old, new in controls:
        if text.count(old) != 1:
            raise RuntimeError(f"{name}: mutation no longer unique")
        mutant = output / f"{name}.c"
        mutant.write_text(text.replace(old, new))
        executable = compile_test(name, code=mutant)
        result = subprocess.run([str(executable)], capture_output=True, timeout=60)
        (output / f"{name}.log").write_bytes(result.stdout + result.stderr)
        # Require a test assertion, not a crash in memory handling or a build error.
        if result.returncode != -6 or b"Assertion" not in result.stderr:
            raise RuntimeError(f"{name}: missing assertion rejection ({result.returncode})")
        print(f"PASS: rejected {name} control", flush=True)
    print("PASS: 6 helper ABI corruption controls; host-only, no emitted helper call", flush=True)


if __name__ == "__main__":
    main()
