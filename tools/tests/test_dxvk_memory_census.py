# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise dxvk 0008's memory census (PLA-808), the counters behind a dev build's
[dxvk-mem] line: which kind each image and buffer allocation is counted under, the pending frees
(released, waiting on GPU completion) and how long the oldest has waited, and the cadence shared
with KosmicKrisp's [kk-mem] (mesa 0135): every 10 s, within a second while memory grows fast. The
header is the patch's own, on a stand-in for the few Vulkan names it uses; nothing reads a log."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = next((ROOT / "patches/dxvk").glob("0008-*.patch"))
HEADER = "src/dxvk/dxvk_memory_census.h"

# The Vulkan names the census uses, with the specification's values.
VULKAN = r'''
#pragma once
#include <stdint.h>
typedef uint32_t VkFlags;
typedef VkFlags VkImageUsageFlags;
typedef VkFlags VkMemoryPropertyFlags;
enum {
    VK_IMAGE_USAGE_TRANSFER_SRC_BIT = 0x1, VK_IMAGE_USAGE_TRANSFER_DST_BIT = 0x2,
    VK_IMAGE_USAGE_SAMPLED_BIT = 0x4, VK_IMAGE_USAGE_STORAGE_BIT = 0x8,
    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = 0x10, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT = 0x20,
    VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT = 0x40, VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT = 0x80,
};
enum {
    VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = 0x1, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = 0x2,
    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = 0x4, VK_MEMORY_PROPERTY_HOST_CACHED_BIT = 0x8,
};
'''

TEST_CPP = r'''
#include "dxvk_memory_census.h"
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

using namespace dxvk;
using K = DxvkMemoryKind;
using C = DxvkMemoryCensus;

constexpr int64_t S = 1000000000ll;
constexpr uint64_t MiB = 1ull << 20;

static DxvkMemoryCensusCount kind(const DxvkMemoryCensusSnapshot& s, K k) { return s.kinds[size_t(k)]; }

static void classification() {
    /* Images: an attachment usage is a render target, whatever else it has; storage without one
     * is a storage image; the rest, sampled or copied only, a sampled texture. */
    assert(C::classifyImage(VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT) == K::Sampled);
    assert(C::classifyImage(VK_IMAGE_USAGE_TRANSFER_SRC_BIT) == K::Sampled);
    assert(C::classifyImage(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT) == K::RenderTarget);
    assert(C::classifyImage(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) == K::RenderTarget);
    assert(C::classifyImage(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_STORAGE_BIT) == K::RenderTarget);
    assert(C::classifyImage(VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT) == K::Storage);
    /* Buffers: host-visible memory (KosmicKrisp's second type is visible, coherent, cached and
     * device-local) is staging and upload; device-local only is any other buffer. */
    assert(C::classifyBuffer(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
                             VK_MEMORY_PROPERTY_HOST_CACHED_BIT | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) == K::Staging);
    assert(C::classifyBuffer(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == K::Staging);
    assert(C::classifyBuffer(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) == K::Buffer);
    assert(C::classifyBuffer(0) == K::Buffer);
}

static void kinds_and_pending() {
    C census;
    DxvkMemoryCensusEntry rt, tex, uav, upload, vbo, imported;
    census.add(rt, K::RenderTarget, 8 * MiB);
    census.add(tex, K::Sampled, 4 * MiB);
    census.add(uav, K::Storage, 2 * MiB);
    census.add(upload, K::Staging, 1 * MiB);
    census.add(vbo, K::Buffer, 3 * MiB);
    census.add(imported, K::None, 5 * MiB);   /* not counted, and nothing to release or free */
    census.release(imported, 5 * MiB, 1 * S);
    census.remove(imported, 5 * MiB);

    auto s = census.snapshot(100 * S);
    assert(kind(s, K::RenderTarget).count == 1 && kind(s, K::RenderTarget).bytes == 8 * MiB);
    assert(kind(s, K::Sampled).bytes == 4 * MiB && kind(s, K::Storage).bytes == 2 * MiB);
    assert(kind(s, K::Staging).bytes == 1 * MiB && kind(s, K::Buffer).bytes == 3 * MiB);
    assert(kind(s, K::None).count == 0 && s.pending.count == 0 && s.oldestPendingNs == 0);
    assert(s.totalBytes() == 18 * MiB);

    /* Released: out of its kind into the pending frees, once; the total stays */
    census.release(upload, 1 * MiB, 100 * S);
    census.release(vbo, 3 * MiB, 101 * S);
    census.release(upload, 1 * MiB, 102 * S);
    s = census.snapshot(103 * S);
    assert(kind(s, K::Staging).count == 0 && kind(s, K::Buffer).count == 0);
    assert(s.pending.count == 2 && s.pending.bytes == 4 * MiB);
    assert(s.oldestPendingNs == 3 * S);
    assert(s.totalBytes() == 18 * MiB);

    /* Freed: the oldest goes, the next is the oldest */
    census.remove(upload, 1 * MiB);
    s = census.snapshot(103 * S);
    assert(s.pending.count == 1 && s.pending.bytes == 3 * MiB && s.oldestPendingNs == 2 * S);
    census.remove(vbo, 3 * MiB);
    census.remove(rt, 8 * MiB);
    s = census.snapshot(103 * S);
    assert(s.pending.count == 0 && s.oldestPendingNs == 0);
    assert(kind(s, K::RenderTarget).count == 0 && s.totalBytes() == 6 * MiB);

    /* A release that raced in with an earlier time than the one before it: the list keeps
     * release order, each wait counted from no earlier than the release before it, so the
     * first in the list has waited longest; freed newest first */
    census.release(tex, 4 * MiB, 200 * S);
    census.release(uav, 2 * MiB, 199 * S);
    assert(census.snapshot(205 * S).oldestPendingNs == 5 * S);
    census.remove(tex, 4 * MiB);
    assert(census.snapshot(205 * S).oldestPendingNs == 5 * S);
    census.remove(uav, 2 * MiB);
    s = census.snapshot(205 * S);
    assert(s.totalBytes() == 0 && s.pending.count == 0 && s.oldestPendingNs == 0);

    /* An entry freed and handed out again (an allocation cache) starts live */
    census.add(tex, K::Sampled, 4 * MiB);
    assert(tex.releasedNs == 0 && kind(census.snapshot(1 * S), K::Sampled).count == 1);
    census.remove(tex, 4 * MiB);
}

static void cadence() {
    C census;
    DxvkMemoryCensusEntry a, b, c;
    /* The first call logs */
    auto t = census.tick(10 * S);
    assert(t.log && !t.growing && t.grewBytes == 0);
    /* Nothing within the 10 s while the total holds */
    assert(!census.tick(10 * S + S / 2).log);
    assert(!census.tick(15 * S).log);
    /* 64 MiB more: within a second of the last line, never sooner */
    census.add(a, K::Sampled, 64 * MiB);
    assert(!census.tick(10 * S + S / 2).log);
    t = census.tick(15 * S + S / 2);
    assert(t.log && t.growing && t.grewBytes == int64_t(64 * MiB));
    assert(!census.tick(16 * S).log);
    /* 63 MiB more is not fast growth; 64 is, counted from the last line */
    census.add(b, K::Staging, 63 * MiB);
    assert(!census.tick(17 * S).log);
    census.add(c, K::Buffer, 1 * MiB);
    t = census.tick(17 * S + 1);
    assert(t.log && t.growing && t.grewBytes == int64_t(64 * MiB));
    /* Releasing moves memory between kinds, it does not grow it */
    census.release(a, 64 * MiB, 18 * S);
    assert(!census.tick(18 * S + S / 2).log);
    /* Shrinking is never fast growth; the 10 s line still comes */
    census.remove(a, 64 * MiB);
    assert(!census.tick(26 * S).log);
    t = census.tick(27 * S + 1);
    assert(t.log && !t.growing && t.grewBytes == -int64_t(64 * MiB));
    census.remove(b, 63 * MiB);
    census.remove(c, 1 * MiB);
}

static void threads() {
    /* Allocations live, released and freed on several threads at once: the counters and the
     * pending list come back to nothing */
    C census;
    std::vector<std::thread> workers;
    for (int w = 0; w < 4; w++) {
        workers.emplace_back([&census, w] {
            std::vector<DxvkMemoryCensusEntry> entries(2000);
            for (size_t i = 0; i < entries.size(); i++)
                census.add(entries[i], K(1 + (i + w) % 5), 256 + i);
            for (size_t i = 0; i < entries.size(); i += 2)
                census.release(entries[i], 256 + i, int64_t(i + 1));
            for (size_t i = 0; i < entries.size(); i++)
                census.remove(entries[i], 256 + i);
        });
    }
    for (auto& worker : workers)
        worker.join();
    auto s = census.snapshot(1 * S);
    assert(s.totalBytes() == 0 && s.pending.count == 0 && s.oldestPendingNs == 0);
    for (size_t k = 0; k < s.kinds.size(); k++)
        assert(s.kinds[k].count == 0);
}

int main() {
    classification();
    kinds_and_pending();
    cadence();
    threads();
    std::puts("ok");
    return 0;
}
'''


def added(patch, path):
    """The new file PATH as the patch adds it."""
    section = patch.read_text().split(f"diff --git a/{path} b/{path}\n", 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    body = section.split("\n@@", 1)[1].split("\n", 1)[1]
    return "\n".join(line[1:] for line in body.splitlines() if line.startswith("+")) + "\n"


@unittest.skipUnless(shutil.which("c++"), "no C++ compiler")
class DxvkMemoryCensus(unittest.TestCase):
    def test_census(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "dxvk").mkdir()
            (tmp / "vulkan").mkdir()
            (tmp / "dxvk/dxvk_memory_census.h").write_text(added(PATCH, HEADER))
            (tmp / "vulkan/vulkan_core.h").write_text(VULKAN)
            (tmp / "test.cpp").write_text(TEST_CPP)
            exe = tmp / "census-test"
            subprocess.run(["c++", "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-UNDEBUG", f"-I{tmp}", f"-I{tmp / 'dxvk'}", str(tmp / "test.cpp"),
                            "-o", str(exe)], check=True)
            out = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=60)
            self.assertEqual(out.stdout.strip(), "ok")

    def test_dev_app_turns_it_on(self):
        """The dev app asks for the census beside MESA_KK_DEBUG=memory; the release app does not."""
        source = (ROOT / "app/Sources/S1Probe/WineHostRuntime.swift").read_text()
        dev = source.split("#if PLAYPORT_RELEASE\n        Self.quietRuntime()\n        #else\n", 1)[1]
        dev = dev.split("#endif", 1)[0]
        self.assertIn('setenv("PLAYPORT_DXVK_MEMORY", "1", 0)', dev)
        self.assertEqual(source.count("PLAYPORT_DXVK_MEMORY"), 1)
        self.assertIn('env::getEnvVar("PLAYPORT_DXVK_MEMORY") == "1"', PATCH.read_text())


if __name__ == "__main__":
    unittest.main()
