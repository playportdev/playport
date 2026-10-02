// SPDX-License-Identifier: GPL-3.0-or-later
// Calls real native FEX code; no guest instructions or app runtime involved.
#include "Interface/Context/Context.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/CPUBackend.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/IR/PassManager.h"
#include "Common/JitSymbols.h"
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/LogManager.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/mman.h>

static std::string Report;
static void Log(LogMan::DebugLevels, const char* message) { Report = message; }

int main() {
  // A real ContextImpl retains its virtual CompileBlock method at link time.
  // This catches allocator-provider leaks hidden by the reset-only link test.
  FEXCore::Config::Initialize();
  FEXCore::Config::Load();
  FEXCore::Config::Set(FEXCore::Config::ConfigOption::CONFIG_IS64BIT_MODE, "0");
  {
    FEXCore::HostFeatures features {};
    FEXCore::Context::ContextImpl context {features};
  }
  puts("PASS: real native ContextImpl construction/destruction and virtual-method link");

  // Exercise the actual disabled-allocator hooks, including the repaired call.
  auto* allocation = FEXCore::Allocator::malloc(64);
  assert(allocation);
  memset(allocation, 0xa5, 64);
  assert(FEXCore::Allocator::malloc_usable_size(allocation) >= 64);
  FEXCore::Allocator::free(allocation);
  allocation = FEXCore::Allocator::calloc(64, 1);
  assert(allocation);
  for (size_t i = 0; i < 64; ++i) {
    assert(static_cast<unsigned char*>(allocation)[i] == 0);
  }
  FEXCore::Allocator::free(allocation);

  using TS = FEXCore::Core::InternalThreadState;
  TS storage {.CTX = nullptr};
  auto* thread = &storage;
  LogMan::Msg::InstallHandler(Log);
  FEXCore::Core::ResetCallRetStack(nullptr, "core");
  FEXCore::Core::ResetCallRetStack(thread, "core");
  assert(Report.empty());
  void* base = mmap(nullptr, TS::CALLRET_STACK_SIZE, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  assert(base != MAP_FAILED);
  thread->CallRetStackBase = base;
  for (int i = 0; i < 1024; ++i) {
    // Dirty both ends before EVERY reset, not just the first reset.
    static_cast<unsigned char*>(base)[0] = 0xa5;
    static_cast<unsigned char*>(base)[TS::CALLRET_STACK_SIZE - 1] = 0x5a;
    if (i == 0) { memset(base, 0xa5, TS::CALLRET_STACK_SIZE); }
    FEXCore::Core::ResetCallRetStack(thread, i % 2 ? "cpubackend" : "core");
    assert(static_cast<unsigned char*>(base)[0] == 0);
    assert(static_cast<unsigned char*>(base)[TS::CALLRET_STACK_SIZE - 1] == 0);
    if (i == 0) {
      for (size_t offset = 0; offset < TS::CALLRET_STACK_SIZE; ++offset) {
        assert(static_cast<unsigned char*>(base)[offset] == 0);
      }
    }
  }
  auto* bytes = static_cast<unsigned char*>(base);
  for (size_t i = 0; i < TS::CALLRET_STACK_SIZE; ++i) { assert(bytes[i] == 0); }
  assert(Report.find("resets=1024 bytes=16384MB per_reset=16384KB") != std::string::npos);
  assert(Report.find("by_site core=512 cpubackend=512 jit-rollover=0") != std::string::npos);
  assert(Report.find("reset_us=") == std::string::npos);
  assert(Report.find("max_us=") == std::string::npos);
  puts(Report.c_str());
  assert(munmap(base, TS::CALLRET_STACK_SIZE) == 0);
  puts("PASS: real native allocator hooks and full predictor reset/census");
}
