// SPDX-License-Identifier: GPL-3.0-or-later
// Tests the shipped source helper, not a second accounting implementation.
#include "dxvk_descriptor_stats.h"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>
#include <stdexcept>
#include <future>
using namespace dxvk;

static thread_local std::vector<int64_t> ticks;
static thread_local size_t cursor;
static std::atomic<unsigned> reads{0};
static bool fake(uint64_t& value) noexcept {
  reads++;
  assert(cursor < ticks.size());
  auto t = ticks[cursor++];
  if (t < 0) return false;
  value = uint64_t(t);
  return true;
}
static void clockValues(std::initializer_list<int64_t> values) { ticks = values; cursor = 0; }
static DescriptorClock clockSource(uint64_t hz = 100) { return {fake, hz, "fake"}; }
static std::vector<std::string> lines;
static void emit(const std::string& line) { lines.push_back(line); }
static uint64_t field(const DescriptorStats::Snapshot& s, DescriptorOp op, DescriptorStats::Field f, size_t category = 0) {
  return s.rows[DescriptorStats::row(op, category)][f];
}
static auto capture(DescriptorStats& stats) {
  clockValues({1000, 1000});
  return stats.capture();
}

static void exactNested() {
  clockValues({1, 10, 20, 25, 30, 40, 50, 70, 90, 100, 110});
  DescriptorStats stats(true, nullptr, clockSource(), false);
  {
    DescriptorScope prep(stats.enabled(), DescriptorOp::Prep);
    prep.sets(2); prep.writes(3, 3);
    {
      DescriptorScope pool(stats.enabled(), DescriptorOp::PoolAlloc);
      { DescriptorScope vk(stats.enabled(), DescriptorOp::VkAllocate); }
    }
    { DescriptorScope bind(stats.enabled(), DescriptorOp::VkBind); }
  }
  { DescriptorScope standalone(stats.enabled(), DescriptorOp::PoolRecycle); }
  auto s = capture(stats);
  assert(s.quiescent && s.clockOk && !s.overflow);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Inclusive) == 80);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Children) == 40);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Exclusive) == 40);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::ThreadSumOuter) == 80);
  assert(field(s, DescriptorOp::PoolAlloc, DescriptorStats::Inclusive) == 20);
  assert(field(s, DescriptorOp::PoolAlloc, DescriptorStats::Exclusive) == 15);
  assert(field(s, DescriptorOp::VkAllocate, DescriptorStats::Exclusive) == 5);
  assert(field(s, DescriptorOp::VkBind, DescriptorStats::Exclusive) == 20);
  assert(field(s, DescriptorOp::PoolRecycle, DescriptorStats::ThreadSumOuter, 1) == 10);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Sets) == 2);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::WriteElements) == 3);
  // Sum disjoint prep exclusives = 40+15+5+20, not 80+20+5+20.
}

static void exclusionAndRecursion() {
  clockValues({1, 10, 20, 30, 40, 45, 50, 60, 100});
  DescriptorStats stats(true, nullptr, clockSource(), false);
  {
    DescriptorScope outer(stats.enabled(), DescriptorOp::Prep);
    { DescriptorScope same(stats.enabled(), DescriptorOp::Prep); } //20..30
    {
      DescriptorScope excluded(stats.enabled(), DescriptorOp::SpecDataExcluded); //40..60
      { DescriptorScope vk(stats.enabled(), DescriptorOp::VkUpdate); } //45..50
    }
  }
  auto s = capture(stats);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::ThreadSumOuter) == 90);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Inclusive) == 100);
  assert(field(s, DescriptorOp::SpecDataExcluded, DescriptorStats::Inclusive, 2) == 20);
  assert(field(s, DescriptorOp::VkUpdate, DescriptorStats::Calls, 2) == 1);
}

static void invalidClocks() {
  uint64_t value = 77;
  assert(!DescriptorClock::monotonicTicks(-1, 0, value) && value == 77);
  assert(!DescriptorClock::monotonicTicks(0, -1, value));
  assert(!DescriptorClock::monotonicTicks(0, 1000000000, value));
  assert(!DescriptorClock::monotonicTicks(INT64_MAX, 0, value));
  assert(DescriptorClock::monotonicTicks(1, 2, value) && value == 1000000002);
  for (auto seq : {std::vector<int64_t>{1, -1, 3}, {1, 4, 3}}) {
    ticks = seq; cursor = 0;
    DescriptorStats stats(true, nullptr, clockSource(), false);
    { DescriptorScope scope(stats.enabled(), DescriptorOp::Prep); }
    auto s = capture(stats);
    assert(field(s, DescriptorOp::Prep, DescriptorStats::ClockErrors) == 1);
    assert(field(s, DescriptorOp::Prep, DescriptorStats::TimedCalls) == 0);
  }
  clockValues({1, 10, 20, -1, 40});
  DescriptorStats parent(true, nullptr, clockSource(), false);
  {
    DescriptorScope prep(parent.enabled(), DescriptorOp::Prep);
    { DescriptorScope child(parent.enabled(), DescriptorOp::VkBind); }
  }
  auto s = capture(parent);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::ClockErrors) == 1);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::TimedCalls) == 0);
  clockValues({1, 10, 10});
  DescriptorStats quantized(true, nullptr, clockSource(), false);
  { DescriptorScope scope(quantized.enabled(), DescriptorOp::Prep); scope.emptyDirtyMask(); }
  s = capture(quantized);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::TimedCalls) == 1);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Inclusive) == 0);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::EmptyDirtyMask) == 1);
  DescriptorStats disabledClock(true, nullptr, clockSource(0), false);
  { DescriptorScope scope(disabledClock.enabled(), DescriptorOp::Prep); }
  s = capture(disabledClock);
  assert(!s.clockOk && field(s, DescriptorOp::Prep, DescriptorStats::ClockErrors) == 1);
}

static void lifetimeAndIdentity() {
  clockValues({1, 10, 20, 30, 40, 50, 60});
  DescriptorStats stats(true, nullptr, clockSource(), false);
  auto early = [&] { DescriptorScope scope(stats.enabled(), DescriptorOp::Prep); return; };
  early();
  try { DescriptorScope scope(stats.enabled(), DescriptorOp::Prep); throw std::runtime_error("test"); }
  catch (const std::runtime_error&) { }
  {
    DescriptorScope active(stats.enabled(), DescriptorOp::Prep);
    auto s = capture(stats);
    assert(!s.quiescent && field(s, DescriptorOp::Prep, DescriptorStats::Calls) == 3);
    assert(field(s, DescriptorOp::Prep, DescriptorStats::Completed) == 2);
    clockValues({1100});
  }
  auto s = capture(stats);
  assert(s.quiescent && field(s, DescriptorOp::Prep, DescriptorStats::Failures) == 1);
  assert(s.id == 2 && field(s, DescriptorOp::Prep, DescriptorStats::Completed) == 3);
  clockValues({1, 2, 3, 4, 5, 6});
  DescriptorStats other(true, nullptr, clockSource(), false);
  {
    DescriptorScope outer(stats.enabled(), DescriptorOp::Prep);
    { DescriptorScope mixed(other.enabled(), DescriptorOp::VkBind); }
  }
  s = capture(stats);
  auto o = capture(other);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::NestErrors) == 1);
  assert(field(o, DescriptorOp::VkBind, DescriptorStats::NestErrors) == 1);
  assert(field(o, DescriptorOp::VkBind, DescriptorStats::TimedCalls) == 0);
}

static void saturationAndDisabled() {
  clockValues({1, 10, 20});
  DescriptorStats stats(true, nullptr, clockSource(), false);
  { DescriptorScope scope(stats.enabled(), DescriptorOp::Prep); scope.sets(UINT64_MAX); scope.sets(1); }
  auto s = capture(stats);
  assert(s.overflow && field(s, DescriptorOp::Prep, DescriptorStats::Sets) == UINT64_MAX);
  reads = 0; lines.clear();
  { DescriptorStats off(false, emit, clockSource());
    for (int i = 0; i < 100; i++) { DescriptorScope scope(off.enabled(), DescriptorOp::Prep); assert(!scope); }
    off.submission(); off.report(true); off.capture();
  }
  assert(reads == 0 && lines.empty());
}

static void threads() {
  clockValues({1});
  DescriptorStats a(true, nullptr, clockSource(), false);
  clockValues({2});
  DescriptorStats b(true, nullptr, clockSource(), false);
  auto worker = [&] {
    for (unsigned i = 0; i < 1000; i++) {
      clockValues({10, 20, 30, 50, 60, 70});
      {
        DescriptorScope prep(a.enabled(), DescriptorOp::Prep);
        { DescriptorScope vk(a.enabled(), DescriptorOp::VkBind); }
      }
      { DescriptorScope standalone(b.enabled(), DescriptorOp::PoolAlloc); }
    }
  };
  std::thread t1(worker), t2(worker); t1.join(); t2.join();
  auto s = capture(a), o = capture(b);
  assert(s.quiescent && o.quiescent && !s.overflow && !o.overflow);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Calls) == 2000);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::ThreadSumOuter) == 80000);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Exclusive) == 60000);
  assert(field(s, DescriptorOp::VkBind, DescriptorStats::Exclusive) == 20000);
  assert(field(o, DescriptorOp::PoolAlloc, DescriptorStats::ThreadSumOuter, 1) == 20000);
  assert(field(o, DescriptorOp::Prep, DescriptorStats::Calls) == 0);
}

static void concurrentCaptureAndDepth() {
  clockValues({1});
  DescriptorStats stats(true, nullptr, clockSource(), false);
  std::promise<void> entered, release;
  auto released = release.get_future();
  std::thread worker([&] {
    clockValues({10, 100});
    DescriptorScope prep(stats.enabled(), DescriptorOp::Prep);
    entered.set_value();
    released.wait();
  });
  entered.get_future().wait();
  auto s = capture(stats);
  assert(!s.quiescent && s.enteredBefore == 1 && s.completedAfter == 0);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Calls) == 1);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Completed) == 0);
  release.set_value(); worker.join();
  s = capture(stats);
  assert(s.quiescent && field(s, DescriptorOp::Prep, DescriptorStats::Inclusive) == 90);
  // Depth beyond the declared fixed accounting limit must invalidate, not merge.
  ticks.assign(80, 10); cursor = 0;
  auto recurse = [&](auto&& self, unsigned n) -> void {
    DescriptorScope prep(stats.enabled(), DescriptorOp::Prep);
    if (n) self(self, n - 1);
  };
  recurse(recurse, 33);
  s = capture(stats);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::NestErrors) > 0);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::ClockErrors) == 34);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::TimedCalls) == 1);
}

static void overflowingElapsedAndBoundaries() {
  // Raw ticks themselves need no conversion/multiplication. Accumulated elapsed
  // must saturate rather than wrap even for a malicious/failing injected clock.
  static thread_local unsigned call;
  call = 0;
  DescriptorClock huge{[](uint64_t& v) noexcept {
    unsigned c = call++;
    v = c == 2 || c == 4 ? UINT64_MAX - 1 : 0;
    return true;
  }, 1, "huge_fake"};
  DescriptorStats stats(true, nullptr, huge, false);
  { DescriptorScope prep(stats.enabled(), DescriptorOp::Prep); }
  { DescriptorScope prep(stats.enabled(), DescriptorOp::Prep); }
  auto s = stats.capture();
  assert(s.overflow && field(s, DescriptorOp::Prep, DescriptorStats::Inclusive) == UINT64_MAX);
  clockValues({1, 10, 20, 50, 40});
  DescriptorStats outside(true, nullptr, clockSource(), false);
  {
    DescriptorScope prep(outside.enabled(), DescriptorOp::Prep);
    { DescriptorScope child(outside.enabled(), DescriptorOp::VkBind); }
  }
  s = capture(outside);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::ClockErrors) == 1);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::TimedCalls) == 0);
  clockValues({1, 10, 20, 30, 40});
  DescriptorStats disabledNested(true, nullptr, clockSource(), false);
  DescriptorStats off(false, nullptr, clockSource());
  {
    DescriptorScope prep(disabledNested.enabled(), DescriptorOp::Prep);
    { DescriptorScope disabled(off.enabled(), DescriptorOp::VkUpdate); }
    { DescriptorScope bind(disabledNested.enabled(), DescriptorOp::VkBind); }
  }
  s = capture(disabledNested);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Inclusive) == 30);
  assert(field(s, DescriptorOp::Prep, DescriptorStats::Exclusive) == 20);
}

static void reports() {
  lines.clear(); clockValues({1, 100, 101, 102, 110, 200, 201, 202, -1, 203, 204, -1, 300, 301, 302});
  {
    DescriptorStats stats(true, emit, clockSource(), false);
    stats.submission(); // first
    stats.submission(); // throttled
    stats.submission(); //1Hz
    stats.submission(); // failure episode
    stats.submission(); // repeated failure suppressed
    stats.report(true);
    stats.abandon();
  }
  assert(lines.size() == 1 + DescriptorStats::RowCount * 4);
  assert(lines[1].find("snapshot=1") != std::string::npos);
  assert(lines.back().find("final=1") != std::string::npos);
  assert(lines.back().find("client_submission_requests=5") != std::string::npos);
  auto firstIdentity = lines[0].substr(0, lines[0].find(" schema="));
  clockValues({1});
  DescriptorStats other(true, emit, clockSource(), false);
  other.abandon();
  assert(lines.back().substr(0, lines.back().find(" schema=")) != firstIdentity);
  // Real platform calibration uses exactly the real enabled helper.
  lines.clear();
  {
    DescriptorStats real(true, emit);
    DescriptorScope prep(real.enabled(), DescriptorOp::Prep);
    prep.prepared(3);
    DescriptorScope bind(real.enabled(), DescriptorOp::VkBind);
    bind.sets(2);
  }
  assert(lines.size() == 1 + 16 + DescriptorStats::RowCount);
  for (unsigned i = 1; i <= 16; i++) {
    assert(lines[i].find("empty_ok=1") != std::string::npos);
    assert(lines[i].find("clock_reads=6") != std::string::npos);
  }
  for (const auto& line : lines) std::cout << line << '\n';
  lines.clear();
  DescriptorClock failed{[](uint64_t&) noexcept { return false; }, 100, "failed"};
  { DescriptorStats bad(true, emit, failed); }
  assert(lines.size() == 1 + 16 + DescriptorStats::RowCount);
  assert(lines[0].find("init_ok=0") != std::string::npos);
  for (unsigned i = 1; i <= 16; i++) {
    assert(lines[i].find("adjacent_ok=0") != std::string::npos);
    assert(lines[i].find("scope_ok=0") != std::string::npos);
    assert(lines[i].find("empty_ok=0") != std::string::npos);
  }
  assert(lines.back().find("clock_ok=0") != std::string::npos);
  // Reporting/log allocation failure cannot alter the operation/exception path.
  auto throws = +[](const std::string&) { throw std::runtime_error("logger"); };
  { DescriptorStats brokenLog(true, throws); brokenLog.submission(); }
}

int main() {
  exactNested(); exclusionAndRecursion(); invalidClocks(); lifetimeAndIdentity();
  saturationAndDisabled(); threads(); concurrentCaptureAndDepth(); overflowingElapsedAndBoundaries(); reports();
  std::cout << "descriptor-stats: all real-helper assertions passed\n";
}
