#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that FEX addresses every i386 guest memory access through the window.

Assembles window_corpus.s with llvm-mc, then translates each instruction in
32-bit mode with the real FEX frontend, dispatcher and IR passes of the
series-applied native build (see README.md) and checks the IR. Nothing runs
guest code. Generated files stay under .work.
"""
import argparse
from pathlib import Path
import re
import subprocess

from native_link_audit import ROOT, link_native_test


def assemble(corpus):
    lines = []
    for text in corpus.read_text().splitlines():
        text = text.strip()
        if not text or text.startswith("#"):
            continue
        if text.startswith(".byte "):
            # Raw bytes for an encoding the assembler only emits with a label.
            data = [int(byte, 16) for byte in text[6:].split("#")[0].split(",")]
            lines.append(" ".join(f"{byte:02x}" for byte in data) + "\t" + text)
            continue
        result = subprocess.run(
            ["llvm-mc", "-triple=i386-unknown-unknown", "-x86-asm-syntax=intel",
             "-output-asm-variant=1", "--show-encoding"],
            input=text + "\n", capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise SystemExit(f"{text}: {result.stderr.strip()}")
        encodings = re.findall(r"encoding: \[([^\]]*)\]", result.stdout)
        if len(encodings) != 1:
            raise SystemExit(f"{text}: expected one instruction, got {result.stdout!r}")
        data = [int(byte, 16) for byte in encodings[0].split(",")]
        lines.append(" ".join(f"{byte:02x}" for byte in data) + "\t" + text)
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="configured native FEX build directory")
    args = parser.parse_args()
    output = ROOT / ".work/guest32/window-coverage"
    output.mkdir(parents=True, exist_ok=True)
    corpus = output / "corpus.tsv"
    corpus.write_text("\n".join(assemble(ROOT / "build/guest32/window_corpus.s")) + "\n")
    binary = output / "window-coverage-test"
    link_native_test(args.build, ROOT / "build/guest32/window_coverage_test.cpp", binary, parser)
    subprocess.run([str(binary), str(corpus)], check=True, timeout=120)
    # Negative control: the same translation without a window must be rejected.
    control = subprocess.run([str(binary), str(corpus), "--control"], capture_output=True,
                             text=True, timeout=120)
    first = next((line for line in control.stderr.splitlines() if line.startswith("FAIL")), "")
    if control.returncode != 1 or "not" not in first:
        raise SystemExit(f"control was not rejected: exit {control.returncode} {first!r}")
    print(f"PASS: control without a window rejected: {first}")


if __name__ == "__main__":
    main()
