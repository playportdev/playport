// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded post-RA FXCH provenance oracle, not an x87 interpreter or runtime.
#pragma once

#ifdef FEX_AUDIT_ALLOCATE
static void inspect_native_swap(const IRListView& ir, uint32_t pc, uint8_t top, uint8_t ftw) {
  require(ir.PostRA() && ir.GetHeader()->OriginalRIP == pc && ir.GetHeader()->NumHostInstructions == 1, "native IR header");
  enum class Kind { Data, NativePointer, VectorToken };
  struct Value {
    uint64_t Bits;
    Kind Type = Kind::Data;
  };
  FEXCore::Core::CPUState state {};
  const auto native = reinterpret_cast<uintptr_t>(&state);
  require(native > UINT32_MAX, "native storage must stay high");
  constexpr auto top_offset = offsetof(FEXCore::Core::CPUState, flags) + FEXCore::X86State::X87FLAG_TOP_LOC;
  constexpr auto c1_offset = offsetof(FEXCore::Core::CPUState, flags) + FEXCore::X86State::X87FLAG_C1_LOC;
  constexpr auto ftw_offset = offsetof(FEXCore::Core::CPUState, AbridgedFTW);
  constexpr auto mm_offset = offsetof(FEXCore::Core::CPUState, mm);
  std::array<uint64_t, 8> slots;
  for (unsigned i = 0; i < slots.size(); ++i) {
    // Unique identity for each 128-bit slot, NOT its floating-point value.
    slots[i] = 0xa000 + i;
  }
  const auto original = slots;
  uint8_t c1 = 1, actual_ftw = ftw;
  std::array<Value, 256> physical {};
  std::array<bool, 256> initialized {};
  std::vector<Value> values(ir.GetSSACount());
  std::vector<bool> valid(ir.GetSSACount());
  for (unsigned reg = 0; reg < 8; ++reg) {
    auto index = PhysicalRegister(RegClass::GPRFixed, reg).Raw;
    physical[index] = {0x200000};
    initialized[index] = true;
  }
  auto physical_index = [&](PhysicalRegister reg) {
    require(ActiveBudget && (ActiveBudget->accepts(reg) || ActiveBudget->accepts_vector(reg)), "native physical register budget");
    return reg.Raw;
  };
  auto read = [&](OrderedNodeWrapper ref) {
    require(!ref.IsInvalid(), "native invalid operand");
    if (ref.IsImmediate()) {
      auto index = physical_index(PhysicalRegister(ref));
      require(initialized[index], "native uninitialized register");
      return physical[index];
    }
    auto id = ir.GetID(ir.GetNode(ref)).Value;
    require(id < values.size() && valid[id], "native uninitialized SSA");
    return values[id];
  };
  auto data = [&](OrderedNodeWrapper ref) {
    auto value = read(ref);
    require(value.Type == Kind::Data, "native arithmetic provenance");
    return value.Bits;
  };
  unsigned forms = 0, loads = 0, stores = 0, context_loads = 0, context_stores = 0;
  unsigned blocks = 0, begins = 0, ends = 0, markers = 0, exits = 0;
  for (auto [node, header] : ir.GetAllCode()) {
    auto id = ir.GetID(node).Value;
    auto set = [&](Value value) {
      require(id < values.size() && !valid[id], "native SSA destination");
      values[id] = value;
      valid[id] = true;
    };
    switch (header->Op) {
    case OP_CODEBLOCK: ++blocks; break;
    case OP_BEGINBLOCK: ++begins; break;
    case OP_ENDBLOCK: ++ends; break;
    case OP_GUESTOPCODE:
      require(ir.GetOp<IROp_GuestOpcode>(node)->GuestEntryOffset == 0, "native guest marker");
      ++markers;
      break;
    case OP_CONSTANT:
      require(header->Size == OpSize::i64Bit, "native constant width");
      set({uint64_t(ir.GetOp<IROp_Constant>(node)->Constant)});
      break;
    case OP_INLINECONSTANT:
      require(header->Size == OpSize::i64Bit, "native inline width");
      set({uint64_t(ir.GetOp<IROp_InlineConstant>(node)->Constant)});
      break;
    case OP_LOADCONTEXT: {
      auto* op = ir.GetOp<IROp_LoadContext>(node);
      require(op->Class == RegClass::GPR && header->Size == OpSize::i8Bit && (op->Offset == top_offset || op->Offset == ftw_offset), "nativ"
                                                                                                                                     "e "
                                                                                                                                     "stack"
                                                                                                                                     " cont"
                                                                                                                                     "ext");
      set({op->Offset == top_offset ? top : actual_ftw});
      ++context_loads;
      break;
    }
    case OP_STORECONTEXT: {
      auto* op = ir.GetOp<IROp_StoreContext>(node);
      require(op->Class == RegClass::GPR && header->Size == OpSize::i8Bit && (op->Offset == c1_offset || op->Offset == ftw_offset), "native"
                                                                                                                                    " stack"
                                                                                                                                    " conte"
                                                                                                                                    "xt");
      auto value = data(op->Value);
      if (op->Offset == c1_offset) {
        require(value == 0, "native condition-bit value");
        c1 = value;
      } else {
        require(uint8_t(value) == uint8_t(ftw | (1U << top) | (1U << ((top + 1) & 7))), "native tag value");
        actual_ftw = value;
      }
      ++context_stores;
      break;
    }
    case OP_ADD: {
      auto* op = ir.GetOp<IROp_Add>(node);
      require(header->Size == OpSize::i32Bit, "native arithmetic width");
      set({uint32_t(data(op->Src1) + data(op->Src2))});
      break;
    }
    case OP_SUB: {
      auto* op = ir.GetOp<IROp_Sub>(node);
      require(header->Size == OpSize::i32Bit, "native arithmetic width");
      set({uint32_t(data(op->Src1) - data(op->Src2))});
      break;
    }
    case OP_AND: {
      auto* op = ir.GetOp<IROp_And>(node);
      require(header->Size == OpSize::i32Bit, "native arithmetic width");
      set({uint32_t(data(op->Src1) & data(op->Src2))});
      break;
    }
    case OP_OR: {
      auto* op = ir.GetOp<IROp_Or>(node);
      require(header->Size == OpSize::i32Bit, "native arithmetic width");
      set({uint32_t(data(op->Src1) | data(op->Src2))});
      break;
    }
    case OP_LSHR: {
      auto* op = ir.GetOp<IROp_Lshr>(node);
      require(header->Size == OpSize::i32Bit, "native arithmetic width");
      auto shift = data(op->Src2);
      require(shift < 32, "native shift range");
      set({uint32_t(data(op->Src1)) >> shift});
      break;
    }
    case OP_FORMCONTEXTADDRESS: {
      auto* op = ir.GetOp<IROp_FormContextAddress>(node);
      require(header->Size == OpSize::i64Bit && op->Stride == 16 && data(op->Index) < 8, "native pointer construction");
      // This is the sole pointer constructor. Loaded TOP is data, not a pointer.
      set({native + data(op->Index) * 16, Kind::NativePointer});
      ++forms;
      break;
    }
    case OP_LOADMEM:
    case OP_STOREMEM: {
      const bool store = header->Op == OP_STOREMEM;
      OrderedNodeWrapper addr, offset, source;
      if (store) {
        auto* op = ir.GetOp<IROp_StoreMem>(node);
        require(op->Class == RegClass::FPR && op->OffsetType == MemOffsetType::SXTX && op->OffsetScale == 1 && op->Align == OpSize::i128Bit,
                "native memory addressing");
        addr = op->Addr;
        offset = op->Offset;
        source = op->Value;
      } else {
        auto* op = ir.GetOp<IROp_LoadMem>(node);
        require(op->Class == RegClass::FPR && op->OffsetType == MemOffsetType::SXTX && op->OffsetScale == 1 && op->Align == OpSize::i128Bit,
                "native memory addressing");
        addr = op->Addr;
        offset = op->Offset;
      }
      require(header->Size == OpSize::i128Bit, "native stack memory width");
      auto pointer = read(addr);
      require(pointer.Type == Kind::NativePointer && pointer.Bits > UINT32_MAX, "native pointer provenance");
      unsigned ordinal = store ? stores : loads;
      require(ordinal < 2, "native memory count");
      const unsigned slot = (top + ordinal) & 7;
      require(data(offset) == mm_offset && pointer.Bits + data(offset) == native + mm_offset + slot * 16, "native stack effective address");
      if (store) {
        auto value = read(source);
        require(value.Type == Kind::VectorToken && value.Bits == original[(top + 1 - ordinal) & 7], "native swap value");
        slots[slot] = value.Bits;
        ++stores;
      } else {
        set({slots[slot], Kind::VectorToken});
        ++loads;
      }
      break;
    }
    case OP_INLINEENTRYPOINTOFFSET: {
      auto* op = ir.GetOp<IROp_InlineEntrypointOffset>(node);
      require(header->Size == OpSize::i32Bit && op->Offset == 2, "native guest exit offset");
      set({uint64_t(pc) + 2});
      break;
    }
    case OP_EXITFUNCTION: {
      auto* op = ir.GetOp<IROp_ExitFunction>(node);
      require(header->Size == OpSize::i32Bit && data(op->NewRIP) == uint64_t(pc) + 2 && op->Hint == BranchHint::None &&
                op->CallReturnAddress.IsInvalid() && op->CallReturnBlock.IsInvalid() && !op->PatchSiteAddress && !op->PatchSiteSize,
              "native guest exit");
      ++exits;
      break;
    }
    default: throw std::runtime_error("unclassified native IR operation");
    }
    if (valid[id] && GetHasDest(header->Op)) {
      auto reg = PhysicalRegister(node);
      auto index = physical_index(reg);
      require((values[id].Type == Kind::VectorToken) == (reg.AsRegClass() == RegClass::FPR), "native destination class");
      physical[index] = values[id];
      if (header->Size == OpSize::i32Bit) {
        physical[index].Bits = uint32_t(physical[index].Bits);
      }
      initialized[index] = true;
    }
  }
  auto expected = original;
  std::swap(expected[top], expected[(top + 1) & 7]);
  require(slots == expected && c1 == 0 && actual_ftw == uint8_t(ftw | (1U << top) | (1U << ((top + 1) & 7))), "native swap result");
  require(forms == 2 && loads == 2 && stores == 2 && context_loads == 2 && context_stores == 2 && blocks == 1 && begins == 1 && ends == 1 &&
            markers == 1 && exits == 1,
          "native IR census");
}
#endif
