#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Host experiment using two unmodified FEX decoder methods, not a FEX port.

Read a pinned/patched tree; compile only its executable-range check and byte
peek against a synthetic g32 query adapter. No decode, IR or guest execution.
All generated files stay in .work/guest32/fetch-audit. Not an app entry point.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def method(source: str, signature: str) -> str:
    """Extract the small audited methods; fail if the signature is ambiguous."""
    if source.count(signature) != 1:
        raise ValueError(f"expected one {signature}")
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[start:cursor]


PRELUDE = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <optional>
extern "C" {
#include "guest32.h"
}
struct RangeInfo { uint64_t Base, Size; bool Writable; };
struct QueryAdapter {
  g32_space *space;
  unsigned calls = 0;
  RangeInfo QueryGuestExecutableRange(void *, uint64_t address) {
    ++calls;
    if (address > UINT32_MAX) return {address, 0, false};
    g32_region region;
    assert(g32_query(space, static_cast<uint32_t>(address), &region) == G32_OK);
    if (region.state != G32_REGION_COMMITTED || !(region.permissions & G32_EXEC))
      return {address, 0, false};
    return {region.region_base, region.size, bool(region.permissions & G32_WRITE)};
  }
};
struct Context { QueryAdapter *SyscallHandler; };
struct Decoder {
  Context *CTX;
  void *Thread = nullptr;
  uint64_t ExecutableRangeBase = 0, ExecutableRangeEnd = 0;
  bool ExecutableRangeWritable = false;
  struct { const uint8_t *InstStream, *AdjustedInstStream; } InstStream;
  uint8_t InstructionSize = 0;
  bool CheckRangeExecutable(uint64_t Address, uint64_t Size);
  std::optional<uint8_t> PeekByte(uint8_t Offset);
  void reset() { ExecutableRangeBase = ExecutableRangeEnd = 0; }
  void at(g32_space *s, uint32_t pc) {
    // Only this experiment's stream setup uses unchecked base addition. It
    // supplies the SAME contiguous backing used by g32; production needs a
    // serialized fetch/lifetime adapter, including the address-space end.
    InstStream = {reinterpret_cast<const uint8_t*>(uintptr_t(pc)),
                  reinterpret_cast<const uint8_t*>(g32_backing_base(s) + pc)};
    InstructionSize = 0;
  }
};
'''

TEST = r'''
static void cases(size_t granule) {
  g32_space *s;
  assert(g32_create(granule, &s) == G32_OK);
  constexpr uint32_t base = 0x400000;
  assert(g32_reserve(s, base, 4 * G32_PAGE) == G32_OK);
  assert(g32_commit(s, base, 4 * G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
  const uint8_t marker[] = {0x90, 0xc3, 0x42, 0x43};
  assert(g32_write(s, base + G32_PAGE - 2, marker, sizeof(marker)) == G32_OK);
  // Execute-only and non-executable pages share native accessible backing.
  assert(g32_protect(s, base, G32_PAGE, G32_EXEC) == G32_OK);
  QueryAdapter adapter{s}; Context ctx{&adapter}; Decoder decoder{};
  decoder.CTX = &ctx;
  decoder.at(s, base + G32_PAGE - 2);
  assert(decoder.PeekByte(0) == 0x90);
  assert(!decoder.ExecutableRangeWritable);
  const unsigned calls = adapter.calls;
  assert(decoder.PeekByte(1) == 0xc3 && adapter.calls == calls);
  decoder.InstructionSize = 1;
  assert(decoder.PeekByte(0) == 0xc3);
  assert(!decoder.PeekByte(1));
  decoder.InstructionSize = 0;
  assert(!decoder.PeekByte(2));
  assert(!decoder.CheckRangeExecutable(base + G32_PAGE - 2, 4));
  uint8_t checked[4] = {7, 7, 7, 7};
  assert(g32_fetch(s, base + G32_PAGE - 2, checked, 4) == G32_ACCESS);
  for (uint8_t byte : checked) assert(byte == 7);
  // The marker is natively readable: a raw bias alone would wrongly fetch it.
  assert(decoder.InstStream.AdjustedInstStream[2] == 0x42);

  assert(g32_protect(s, base + G32_PAGE, G32_PAGE, G32_EXEC | G32_WRITE) == G32_OK);
  decoder.reset();
  assert(decoder.CheckRangeExecutable(base + G32_PAGE - 2, 4));
  assert(decoder.ExecutableRangeWritable);
  assert(decoder.PeekByte(2) == 0x42);
  assert(g32_fetch(s, base + G32_PAGE - 2, checked, 4) == G32_OK);
  for (unsigned i = 0; i < 4; ++i) assert(checked[i] == marker[i]);

  // Range cache is metadata, NOT a fresh permission check on every peek.
  decoder.at(s, base);
  decoder.reset();
  assert(decoder.PeekByte(0) == 0);
  assert(g32_protect(s, base, G32_PAGE, G32_READ) == G32_OK);
  const unsigned cached_calls = adapter.calls;
  assert(decoder.PeekByte(0) == 0 && adapter.calls == cached_calls);
  // This expected stale hit documents the mandatory VM/cache protocol.
  assert(g32_fetch(s, base, checked, 1) == G32_ACCESS);
  decoder.reset();
  assert(!decoder.PeekByte(0));
  assert(g32_decommit(s, base + G32_PAGE, G32_PAGE) == G32_OK);
  decoder.reset(); decoder.at(s, base + G32_PAGE);
  assert(!decoder.PeekByte(0)); // No native read into the decommitted page.
  decoder.at(s, 0); decoder.reset();
  assert(!decoder.PeekByte(0));

  // A width crossing 2^32 is denied, not wrapped to the first guest page.
  assert(g32_reserve(s, 0xffff0000u, G32_GRANULE) == G32_OK);
  assert(g32_commit(s, 0xfffff000u, G32_PAGE, G32_EXEC) == G32_OK);
  decoder.at(s, UINT32_MAX); decoder.reset();
  assert(decoder.PeekByte(0) == 0);
  assert(!decoder.PeekByte(1));
  assert(!decoder.CheckRangeExecutable(UINT32_MAX, 2));
  assert(g32_fetch(s, UINT32_MAX, checked, 2) == G32_RANGE);
  g32_destroy(s);
  std::printf("fetch-audit: granule=%zu byte/range checks pass; stale cache reproduced and reset\n", granule);
}
int main() { cases(0); cases(16384); cases(65536); }
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tree", type=Path, help="repository-local FEX source tree")
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    tree = args.tree.resolve()
    tree.relative_to(ROOT)  # Never generate a build record naming an external path.
    frontend = tree / "FEXCore/Source/Interface/Core/Frontend.cpp"
    source = frontend.read_text()
    methods = "\n\n".join(method(source, signature) for signature in (
        "bool Decoder::CheckRangeExecutable(uint64_t Address, uint64_t Size)",
        "std::optional<uint8_t> Decoder::PeekByte(uint8_t Offset)",
    ))
    out = ROOT / ".work/guest32/fetch-audit"
    out.mkdir(parents=True, exist_ok=True)
    (out / "audit.cpp").write_text(PRELUDE + methods + TEST)
    cc = shlex.split(os.environ.get("CC", "clang"))
    cxx = shlex.split(os.environ.get("CXX", "clang++"))
    flags = ["-Wall", "-Wextra", "-Werror", "-g"]
    flags += ["-fsanitize=address,undefined"] if args.sanitize else ["-O2"]
    subprocess.run(cc + ["-std=c11", *flags, "-c", "build/guest32/guest32.c",
                        "-o", str(out.relative_to(ROOT) / "guest32.o")], cwd=ROOT, check=True)
    subprocess.run(cxx + ["-std=c++17", *flags, "-Ibuild/guest32",
                         str(out.relative_to(ROOT) / "audit.cpp"),
                         str(out.relative_to(ROOT) / "guest32.o"), "-o",
                         str(out.relative_to(ROOT) / "audit")], cwd=ROOT, check=True)
    print(f"frontend={frontend.relative_to(ROOT)} sha256={hashlib.sha256(frontend.read_bytes()).hexdigest()}", flush=True)
    print(f"unmodified-methods-sha256={hashlib.sha256(methods.encode()).hexdigest()}", flush=True)
    subprocess.run([str(out / "audit")], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
