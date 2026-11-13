# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise dxvk 0009's drain (PLA-875): how an allocation that must succeed meets memory
pressure. It first takes no heap past its budget; failing that, it waits for GPU work in flight until
that work has freed what it needs or nothing is left in flight, then is tried as asked; a relocation or
eviction is tried once as asked. The header is the patch's own; a mock queue stands in for DXVK's
submission queue (a completion thread that frees what each command list kept, then wakes waiters)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = next((ROOT / "patches/dxvk").glob("0009-*.patch"))
HEADER = "src/dxvk/dxvk_memory_drain.h"

TEST_CPP = r'''
#include "dxvk_memory_drain.h"
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

using namespace dxvk;
using D = DxvkMemoryDrain;

constexpr uint64_t MiB = 1ull << 20;
constexpr int64_t S = 1000000000ll;

static void budget() {
    /* A heap may grow up to its budget, not past it; no budget (0) never stops it. */
    assert(!D::overBudget(1900 * MiB, 100 * MiB, 2048 * MiB));
    assert(!D::overBudget(1948 * MiB, 100 * MiB, 2048 * MiB));
    assert(D::overBudget(1949 * MiB, 100 * MiB, 2048 * MiB));
    assert(D::overBudget(2128 * MiB, 1, 2048 * MiB));
    assert(!D::overBudget(64ull << 30, 64ull << 30, 0));
}

/* One allocation's tries: what each try was asked, and when the drain ran. */
struct Tries {
    std::vector<int> log;              /* 1: within budget, 0: as asked, 2: drain */
    std::vector<bool> results;         /* what each successive try returns */
    size_t next = 0;

    std::optional<int> run(bool mustSucceed) {
        auto create = [this] (bool withinBudget) -> std::optional<int> {
            log.push_back(withinBudget ? 1 : 0);
            bool ok = results.at(next++);
            return ok ? std::optional<int>(int(log.size())) : std::nullopt;
        };
        auto drain = [this] { log.push_back(2); };
        return D::allocate(mustSucceed, create, drain);
    }
};

static void sequence() {
    /* Fits within the budget: one try, no drain. */
    { Tries t; t.results = { true };
      assert(t.run(true)); assert((t.log == std::vector<int>{ 1 })); }
    /* Past the budget: drain, then tried as asked, which may grow past it. */
    { Tries t; t.results = { false, true };
      assert(t.run(true)); assert((t.log == std::vector<int>{ 1, 2, 0 })); }
    /* Nothing even after the drain: the last try's nothing comes back, and the allocator throws. */
    { Tries t; t.results = { false, false };
      assert(!t.run(true)); assert((t.log == std::vector<int>{ 1, 2, 0 })); }
    /* A relocation or eviction may fail: once, as asked, never a drain. */
    { Tries t; t.results = { false };
      assert(!t.run(false)); assert((t.log == std::vector<int>{ 0 })); }
    { Tries t; t.results = { true };
      assert(t.run(false)); assert((t.log == std::vector<int>{ 0 })); }
}

/* DXVK's submission queue, reduced to what the drain sees: command lists in flight, each holding
 * memory that a completion thread frees (D::freed) before it pops the list and wakes waiters. */
struct Queue {
    std::mutex mutex;
    std::condition_variable finished;
    std::deque<uint64_t> inFlight;     /* bytes each command list frees when it completes */
    D& drain;
    std::thread thread;
    bool go = false;
    size_t leftOnReturn = 0;           /* lists still in flight when a wait returned */

    explicit Queue(D& d) : drain(d) { }

    void start() {
        thread = std::thread([this] {
            for (;;) {
                uint64_t bytes;
                { std::unique_lock<std::mutex> lock(mutex);
                  finished.wait(lock, [this] { return go; });
                  if (inFlight.empty()) return;
                  bytes = inFlight.front(); }
                /* the GPU: the big lists take long, so a waiter that stops early is seen to */
                std::this_thread::sleep_for(std::chrono::milliseconds(bytes >= 64 * MiB ? 300 : 20));
                drain.freed(bytes);
                { std::lock_guard<std::mutex> lock(mutex);
                  inFlight.pop_front(); }
                finished.notify_all();
            }
        });
    }

    /* waitForCompletionUntil: true if anything was in flight */
    template<typename Pred> bool waitUntil(const Pred& pred) {
        std::unique_lock<std::mutex> lock(mutex);
        if (inFlight.empty()) return false;
        while (!pred() && !inFlight.empty())
            finished.wait_for(lock, std::chrono::milliseconds(10));
        leftOnReturn = inFlight.size();
        return true;
    }

    void release() { { std::lock_guard<std::mutex> lock(mutex); go = true; } finished.notify_all(); }
    size_t left() { std::lock_guard<std::mutex> lock(mutex); return inFlight.size(); }
};

static void drains() {
    /* Nothing in flight: no wait at all. */
    { D d; Queue q(d);
      auto w = d.begin(8 * MiB);
      assert(!q.waitUntil([&] { return d.done(w, false); })); }

    /* Four command lists hold 4, 4, 64 and 64 MiB. An allocation needing 6 MiB waits for two to
     * complete, not for the queue to empty. */
    { D d; Queue q(d);
      q.inFlight = { 4 * MiB, 4 * MiB, 64 * MiB, 64 * MiB };
      q.start();
      auto w = d.begin(6 * MiB);
      q.release();
      assert(q.waitUntil([&] { return d.done(w, false); }));
      assert(d.freedSince(w) >= 6 * MiB);
      assert(q.leftOnReturn == 2);   /* returned when the second list completed */
      q.thread.join();
      assert(q.left() == 0); }

    /* More than everything in flight frees: waits until nothing is left, then the allocation is
     * tried as asked. */
    { D d; Queue q(d);
      q.inFlight = { 1 * MiB, 2 * MiB };
      q.start();
      auto w = d.begin(512 * MiB);
      q.release();
      assert(q.waitUntil([&] { return d.done(w, false); }));
      assert(q.leftOnReturn == 0);
      assert(d.freedSince(w) == 3 * MiB);
      assert(!d.done(w, false) && d.done(w, true));
      q.thread.join(); }

    /* Memory freed before the drain started does not count; a need of 0 waits for one free. */
    { D d;
      d.freed(100 * MiB);
      auto w = d.begin(0);
      assert(!d.done(w, false));
      d.freed(1);
      assert(d.done(w, false)); }
}

static void counters_and_log() {
    D d;
    auto w = d.begin(8 * MiB);
    d.freed(10 * MiB);
    /* The first drain logs; another within a second does not; one a second later does. */
    assert(d.finish(w, 30 * 1000000ll, 100 * S));
    auto w2 = d.begin(1 * MiB);
    d.freed(2 * MiB);
    assert(!d.finish(w2, 5 * 1000000ll, 100 * S + S / 2));
    assert(d.finish(d.begin(1), 0, 101 * S));
    assert(d.drains() == 3);
    assert(d.waitedNs() == 35 * 1000000ull);
    assert(d.drainedBytes() == 12 * MiB);
}

int main() {
    budget();
    sequence();
    drains();
    counters_and_log();
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
class DxvkMemoryDrain(unittest.TestCase):
    def test_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "dxvk_memory_drain.h").write_text(added(PATCH, HEADER))
            (tmp / "test.cpp").write_text(TEST_CPP)
            exe = tmp / "drain-test"
            subprocess.run(["c++", "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-UNDEBUG", f"-I{tmp}", str(tmp / "test.cpp"), "-o", str(exe)], check=True)
            out = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=60)
            self.assertEqual(out.stdout.strip(), "ok")

    def test_allocator_uses_it(self):
        """The allocator runs every buffer and image allocation through the drain, throws rather than
        return no storage for one that must succeed, and a resource that never got storage
        unregisters itself."""
        text = PATCH.read_text()
        self.assertEqual(text.count("+    Rc<DxvkResourceAllocation> allocation = allocateUnderPressure(allocationInfo,\n"), 2)
        self.assertIn('+      throw DxvkError("DxvkMemoryAllocator: Memory allocation failed");', text)
        self.assertEqual(text.count("+      m_allocator->unregisterResource(this);\n+      throw;"), 2)
        self.assertEqual(text.count("+        m_drain.freed(allocation->m_size);"), 1)
        self.assertEqual(text.count("canGrowHeap(type, "), 3)


if __name__ == "__main__":
    unittest.main()
