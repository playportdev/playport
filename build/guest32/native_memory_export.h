// SPDX-License-Identifier: GPL-3.0-or-later
// Private raw scalar emission export; no checked-memory lowering is installed.
#pragma once

static void export_memory_code(const FEXCore::Context::ContextImpl& context, const FEXCore::CPU::CPUBackend::CompiledCode& code,
                               const FEXCore::Core::DebugData& debug, uint32_t pc, const Case& test,
                               const std::vector<std::pair<Registers, uint32_t>>& inputs, const RegisterBudget& budget) {
  using Backend = FEXCore::CPU::CPUBackend;
  require(code.BlockBegin && code.Size && code.Size <= 4096 && code.Size % 16 == 0, "bounded scalar block");
  auto load = [&]<typename T>(size_t offset) {
    require(offset <= code.Size && sizeof(T) <= code.Size - offset, "bounded code read");
    T result;
    std::memcpy(&result, code.BlockBegin + offset, sizeof(T));
    return result;
  };
  const auto header = load.operator()<Backend::JITCodeHeader>(0);
  const auto tail = load.operator()<Backend::JITCodeTail>(header.OffsetToBlockTail);
  const size_t entry = sizeof(header);
  require(code.EntryPoints.size() == 1 && code.EntryPoints.at(pc) == code.BlockBegin + entry, "scalar entry point");
  const bool valid_tail = tail.Size == code.Size && tail.RIP == pc && tail.GuestSize == test.Bytes.size() && tail.SingleInst && !tail.SpinLockFutex;
  require(valid_tail, "scalar tail");
  require(debug.HostCodeSize == code.Size && debug.Subblocks.size() == 1 && debug.GuestOpcodes.size() == 2 && tail.NumberOfRIPEntries == 2,
          "scalar debug count");
  require(debug.Subblocks[0].HostCodeOffset == entry && debug.GuestOpcodes[0].HostEntryOffset == ptrdiff_t(entry) &&
            debug.GuestOpcodes[1].HostEntryOffset == ptrdiff_t(entry + 8) && !debug.GuestOpcodes[0].GuestEntryOffset &&
            !debug.GuestOpcodes[1].GuestEntryOffset,
          "scalar debug markers");
  const size_t end = entry + debug.Subblocks[0].HostCodeSize;
  require(end >= entry + 12 && end <= header.OffsetToBlockTail && end % 4 == 0, "scalar body range");
  const size_t branch = end - 4, thunk = (end + 7) & ~size_t {7};
  const size_t slot = offsetof(FEXCore::Core::CPUState, InlineJITBlockHeader);
  require(load.operator()<uint32_t>(entry) == 0x10ffffe0 &&
            load.operator()<uint32_t>(entry + 4) == (0xf9000000U | (slot / 8 << 10) | (FEXCore::CPU::STATE.Idx() << 5)),
          "scalar native prologue");
  const bool valid_branch =
    header.OffsetToBlockTail == thunk + 48 && load.operator()<uint32_t>(branch) == (0x14000000U | ((thunk - branch) / 4));
  require(valid_branch, "scalar exit branch");
  require(load.operator()<uint32_t>(thunk) == 0x14000002 && load.operator()<uint32_t>(thunk + 4) == 0xd61f0000 &&
            load.operator()<uint32_t>(thunk + 8) == 0x58000100 && load.operator()<uint32_t>(thunk + 12) == 0xd63f0000 &&
            load.operator()<uint64_t>(thunk + 16) == 0 && load.operator()<uint64_t>(thunk + 24) == uint64_t(pc) + test.Bytes.size() &&
            load.operator()<int64_t>(thunk + 32) == int64_t(branch) - int64_t(thunk) &&
            load.operator()<uint64_t>(thunk + 40) == context.Dispatcher->GetExitFunctionLinkerAddress() &&
            context.Dispatcher->GetExitFunctionLinkerAddress(),
          "scalar unlinked exit thunk");
  require(ExportFile && inputs.size() == 128, "scalar export inputs");
  std::fprintf(ExportFile,
               "{\"version\":1,\"granule\":%zu,\"pc\":%u,\"next_pc\":%llu,\"entry\":%zu,\"branch\":%zu,\"thunk\":%zu,"
               "\"state_register\":%u,\"header_slot\":%zu,\"fs_slot\":%zu,\"fcw_slot\":%zu,\"form\":%u,\"width\":%u,"
               "\"store\":%s,\"control_word\":%s,\"map\":[",
               ExportGranule, pc, static_cast<unsigned long long>(uint64_t(pc) + test.Bytes.size()), entry, branch, thunk,
               FEXCore::CPU::STATE.Idx(), slot, offsetof(FEXCore::Core::CPUState, fs_cached), offsetof(FEXCore::Core::CPUState, FCW),
               unsigned(test.Form), test.Width, test.Store ? "true" : "false", test.ControlWord ? "true" : "false");
  const auto map = budget.guest_map();
  for (size_t i = 0; i < map.size(); ++i) {
    std::fprintf(ExportFile, "%s%u", i ? "," : "", map[i]);
  }
  std::fputs("],\"code\":\"", ExportFile);
  for (size_t i = 0; i < code.Size; ++i) {
    std::fprintf(ExportFile, "%02x", static_cast<unsigned char>(code.BlockBegin[i]));
  }
  std::fputs("\",\"trials\":[", ExportFile);
  for (size_t trial = 0; trial < inputs.size(); ++trial) {
    const auto& [input, fs] = inputs[trial];
    auto expected = input;
    const uint32_t mask = test.Width == 4 ? UINT32_MAX : (1U << (test.Width * 8)) - 1;
    if (!test.Store) {
      expected[0] = (input[0] & ~mask) | (0x89abcdef & mask);
    }
    std::fprintf(ExportFile, "%s{\"address\":%u,\"fs\":%u,\"value\":%u,\"input\":[", trial ? "," : "", expected_address(test, input, fs), fs,
                 (test.ControlWord ? 0x037f :
                  test.Store       ? input[0] :
                                     0x89abcdef) &
                   mask);
    for (size_t i = 0; i < input.size(); ++i) {
      std::fprintf(ExportFile, "%s%u", i ? "," : "", input[i]);
    }
    std::fputs("],\"expected\":[", ExportFile);
    for (size_t i = 0; i < expected.size(); ++i) {
      std::fprintf(ExportFile, "%s%u", i ? "," : "", expected[i]);
    }
    std::fputs("]}", ExportFile);
  }
  std::fputs("]}\n", ExportFile);
  require(!std::ferror(ExportFile), "scalar export write");
}
