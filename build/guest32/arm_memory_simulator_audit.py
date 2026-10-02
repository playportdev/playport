#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Audit raw scalar FEX ARM emission; NOT a checked guest-memory port.

Guest effective addresses receive disposable simulator mappings, even where
real g32 denies access. This observes unchecked emission, not a helper ABI or
fault delivery. Native CPU-state and linker accesses have separate high ranges.
Only the exit-linker literal is adapted. No FEX opcode is interpreted here.
"""
import copy
import hashlib
import json
from pathlib import Path
import struct

from arm_simulator_audit import ROOT, MASK64, check_dependency, require


def oracle(block, trial):
    regs, fs = trial["input"], trial["fs"]
    require(len(regs) == 8 and all(type(v) is int and 0 <= v <= 0xffffffff for v in regs), "oracle input")
    form, width = block["form"], block["width"]
    require(form in range(6) and width in (1, 2, 4), "oracle scalar form")
    address = (regs[3], regs[3] - 16, regs[3] + regs[6] * 4 - 16,
               (regs[3] + regs[6] - 16) & 0xffff, regs[3] + fs, 0x200ffe)[form] & 0xffffffff
    mask = (1 << (width * 8)) - 1
    value = (0x37f if block["control_word"] else regs[0] if block["store"] else 0x89abcdef) & mask
    expected = list(regs)
    if not block["store"]:
        expected[0] = (expected[0] & ~mask) | value
    require(trial["address"] == address and trial["value"] == value, "oracle access export")
    require(trial["expected"] == expected, "oracle register export")
    return address, value, expected


def execute_block(block, index, poison_static_upper=False):
    uc = check_dependency()
    from unicorn import arm64_const as arm
    require(block["version"] == 1, "unknown scalar export version")
    original = bytes.fromhex(block["code"])
    entry, branch, thunk = (block[key] for key in ("entry", "branch", "thunk"))
    require(entry == 4 and entry + 8 < branch < thunk < len(original) <= 4096, "bounded scalar block")
    require(branch % 4 == 0 and thunk == ((branch + 4 + 7) & ~7) and thunk + 48 <= len(original), "scalar thunk layout")
    require(0 < block["pc"] < block["next_pc"] <= 0xffffffff, "scalar guest exit")
    require(struct.unpack_from("<Q", original, thunk + 16)[0] == 0, "exit was already linked")
    require(struct.unpack_from("<Q", original, thunk + 24)[0] == block["next_pc"], "wrong guest exit record")
    require(struct.unpack_from("<q", original, thunk + 32)[0] == branch - thunk, "wrong caller offset")
    require(struct.unpack_from("<Q", original, thunk + 40)[0] != 0, "missing real linker")
    mapping, state_reg = block["map"], block["state_register"]
    require(len(mapping) == 8 and len(set(mapping)) == 8 and all(0 < r < 30 for r in mapping), "scalar register map")
    require(0 < state_reg < 30 and state_reg not in mapping, "scalar STATE register")
    slot, fs_slot, fcw_slot = (block[k] for k in ("header_slot", "fs_slot", "fcw_slot"))
    require(0 <= slot <= 4088 and slot % 8 == 0 and 0 <= fs_slot <= 4092 and 0 <= fcw_slot <= 4094, "native slots")
    require(len(block["trials"]) == 128, "scalar input census")
    code_base = 0x200000000 + index * 0x10000
    state_base, capture = 0x400000000, 0x500000000
    code = bytearray(original)
    struct.pack_into("<Q", code, thunk + 40, capture)
    require(all(thunk + 40 <= i < thunk + 48 for i, (a, b) in enumerate(zip(original, code)) if a != b), "code adaptation")
    machine = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
    machine.mem_map(code_base, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
    machine.mem_write(code_base, bytes(code))
    machine.mem_map(state_base, 4096, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
    machine.mem_map(capture, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
    machine.mem_write(capture, struct.pack("<I", 0xd4200000))
    xregs = [getattr(arm, f"UC_ARM64_REG_X{i}") for i in range(31)]
    expected_trace = [code_base + offset for offset in range(entry, branch + 4, 4)]
    expected_trace += [code_base + thunk, code_base + thunk + 8, code_base + thunk + 12, capture]
    trace, accesses, errors = [], [], []
    expected_accesses = []
    guest_instruction = None

    def instruction_hook(emulator, address, size, _):
        pos = len(trace)
        trace.append(address)
        if size != 4 or pos >= len(expected_trace) or address != expected_trace[pos]:
            errors.append("unexpected instruction path")
            emulator.emu_stop()
        elif address == capture:
            emulator.emu_stop()

    def memory_hook(emulator, access, address, size, value, _):
        nonlocal guest_instruction
        write = access == uc.UC_MEM_WRITE
        observed = (write, address, size, value & ((1 << (size * 8)) - 1) if write else None)
        pos = len(accesses)
        accesses.append(observed)
        if pos >= len(expected_accesses) or observed != expected_accesses[pos]:
            errors.append("guest/native access mismatch")
            emulator.emu_stop()
        elif address <= 0xffffffff:
            guest_instruction = emulator.reg_read(arm.UC_ARM64_REG_PC) - code_base

    def invalid_memory_hook(_emulator, _access, _address, _size, _value, _):
        # LDAR/STLR on an unmapped wrong base can fault before normal hooks.
        # Reject it explicitly; never add a mapping to rescue corrupted code.
        errors.append("guest/native access mismatch: unmapped data")
        return False

    machine.hook_add(uc.UC_HOOK_CODE, instruction_hook)
    machine.hook_add(uc.UC_HOOK_MEM_READ | uc.UC_HOOK_MEM_WRITE, memory_hook)
    machine.hook_add(uc.UC_HOOK_MEM_READ_UNMAPPED | uc.UC_HOOK_MEM_WRITE_UNMAPPED, invalid_memory_hook)
    for trial_index, trial in enumerate(block["trials"]):
        address, value, expected = oracle(block, trial)
        width = block["width"]
        guest_base = address & ~4095
        # Map both pages, including the page ABOVE 4 GiB at a wrapping-width
        # boundary. This is deliberately raw emission, NOT permission checking.
        machine.mem_map(guest_base, 8192, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
        guest = bytearray((i * 73 + 19) & 255 for i in range(8192))
        offset = address - guest_base
        if not block["store"]:
            guest[offset:offset + width] = value.to_bytes(width, "little")
        machine.mem_write(guest_base, bytes(guest))
        trace.clear()
        accesses.clear()
        errors.clear()
        initial = [((0x9e3779b97f4a7c15 * (i + 1 + trial_index * 31)) & MASK64) for i in range(31)]
        # Runtime 32-bit static guest GPRs are zero-extended. Poison temporary
        # registers, not an architectural invariant the raw emitter relies on.
        for guest_reg, host_reg in enumerate(mapping):
            initial[host_reg] = trial["input"][guest_reg]
        if poison_static_upper:
            initial[mapping[3]] |= 0x100000000
        initial[state_reg] = state_base
        for reg, v in zip(xregs, initial):
            machine.reg_write(reg, v)
        stack = 0x600000000 + trial_index * 16
        machine.reg_write(arm.UC_ARM64_REG_SP, stack)
        flags = (trial_index & 15) << 28
        machine.reg_write(arm.UC_ARM64_REG_NZCV, flags)
        state = bytearray([0xa5] * 4096)
        struct.pack_into("<I", state, fs_slot, trial["fs"])
        struct.pack_into("<H", state, fcw_slot, 0x37f)
        machine.mem_write(state_base, bytes(state))
        expected_accesses = [(True, state_base + slot, 8, code_base)]
        if block["form"] == 4:
            expected_accesses.append((False, state_base + fs_slot, 4, None))
        if block["control_word"]:
            expected_accesses.append((False, state_base + fcw_slot, 2, None))
        expected_accesses += [(block["store"], address, width, value if block["store"] else None),
                              (False, code_base + thunk + 40, 8, None)]
        try:
            machine.emu_start(code_base + entry, capture + 4, count=len(expected_trace) + 1)
        except uc.UcError as error:
            raise RuntimeError(f"scalar execution failure: {errors}: {error}") from error
        label = f"scalar block {index} trial {trial_index} form {block['form']}"
        require(not errors, f"{label}: {errors}")
        require(trace == expected_trace, f"{label}: path/capture mismatch")
        require(accesses == expected_accesses, f"{label}: guest/native access census")
        actual = [machine.reg_read(xregs[r]) & 0xffffffff for r in mapping]
        require(actual == expected, f"{label}: guest register mismatch")
        require(all(machine.reg_read(xregs[r]) <= 0xffffffff for r in mapping), f"{label}: guest upper bits")
        require(machine.reg_read(arm.UC_ARM64_REG_PC) == capture and machine.reg_read(xregs[0]) == capture, "no scalar exit capture")
        require(machine.reg_read(xregs[30]) == code_base + thunk + 16, "incorrect exit LR")
        struct.pack_into("<Q", state, slot, code_base)
        require(machine.mem_read(state_base, 4096) == state, "native CPU-state canary changed")
        if block["store"]:
            guest[offset:offset + width] = value.to_bytes(width, "little")
        require(machine.mem_read(guest_base, 8192) == guest, "guest byte canary changed")
        require(machine.mem_read(code_base, len(code)) == code, "emitted code changed")
        require(machine.reg_read(arm.UC_ARM64_REG_SP) == stack, "SP changed")
        require(machine.reg_read(arm.UC_ARM64_REG_NZCV) == flags, "NZCV changed")
        require(machine.reg_read(xregs[state_reg]) == state_base, "STATE changed")
        machine.mem_unmap(guest_base, 8192)
    require(guest_instruction is not None, "no guest memory instruction observed")
    return guest_instruction


def negative_controls(block, guest_instruction):
    original = bytes.fromhex(block["code"])
    word = struct.unpack_from("<I", original, guest_instruction)[0]
    controls = [("memory base register", guest_instruction, word ^ (1 << 5), "guest/native access mismatch"),
                ("memory width", guest_instruction, word ^ (1 << 30), "guest/native access mismatch"),
                ("memory data register", guest_instruction, word ^ 1,
                 "guest/native access mismatch" if block["store"] else "guest register mismatch"),
                ("missing native publication", block["entry"] + 4, 0xd503201f, "guest/native access mismatch"),
                ("self branch", block["branch"], 0x14000000, "unexpected instruction path"),
                ("BR instead of BLR", block["thunk"] + 12, 0xd61f0000, "incorrect exit LR"),
                ("exit record", block["thunk"] + 24, block["next_pc"] ^ 1, "wrong guest exit record")]
    if block["form"] == 4 or block["control_word"]:
        offset = block["entry"] + 8
        context_load = struct.unpack_from("<I", original, offset)[0]
        controls.append(("native context offset", offset, context_load + (1 << 10), "guest/native access mismatch"))
    for name, offset, replacement, expected_error in controls:
        corrupt = copy.deepcopy(block)
        code = bytearray(original)
        struct.pack_into("<I", code, offset, replacement)
        corrupt["code"] = code.hex()
        try:
            execute_block(corrupt, 0)
        except RuntimeError as error:
            require(expected_error in str(error), f"{name}: wrong rejection: {error}")
        else:
            raise RuntimeError(f"accepted corrupted scalar {name}")
        print(f"PASS: rejected scalar {name} control", flush=True)
    if block["form"] == 0:
        try:
            execute_block(block, 0, poison_static_upper=True)
        except RuntimeError as error:
            require("guest/native access mismatch" in str(error), f"wrong upper-bit invariant rejection: {error}")
        else:
            raise RuntimeError("raw base operand unexpectedly discarded poisoned static upper bits")
        print("PASS: demonstrated raw base-address zero-extension precondition", flush=True)
    for field, expected_error in (("address", "oracle access export"), ("expected", "oracle register export")):
        corrupt = copy.deepcopy(block)
        if field == "expected":
            corrupt["trials"][0][field][0] ^= 1
        else:
            corrupt["trials"][0][field] ^= 1
        try:
            execute_block(corrupt, 0)
        except RuntimeError as error:
            require(expected_error in str(error), f"{field}: wrong oracle rejection: {error}")
        else:
            raise RuntimeError(f"accepted corrupted scalar oracle {field}")
        print(f"PASS: rejected scalar oracle {field} control", flush=True)


def audit_file(path):
    uc = check_dependency()
    path = Path(path).resolve()
    require(path.is_relative_to(ROOT / ".work"), "scalar exports must stay in .work")
    library = Path(uc.__file__).parent / "lib/libunicorn.so.2"
    print(f"simulator {uc.__version__}; native library sha256 {hashlib.sha256(library.read_bytes()).hexdigest()}; "
          f"export sha256 {hashlib.sha256(path.read_bytes()).hexdigest()}", flush=True)
    blocks = [json.loads(line) for line in path.read_text().splitlines()]
    require(len(blocks) == 153, "scalar block census")
    signatures = {(form, 4, store, False) for form in range(6) for store in (False, True)}
    signatures |= {(0, width, store, False) for width in (1, 2) for store in (False, True)}
    signatures.add((0, 2, True, True))
    for granule in (0, 16384, 65536):
        for pc in (0x400ffe, 0x900ffe, 0xffff0ffe):
            cohort = [b for b in blocks if b["granule"] == granule and b["pc"] == pc]
            require(len(cohort) == 17 and {(b["form"], b["width"], b["store"], b["control_word"]) for b in cohort} == signatures,
                    "scalar coverage census")
    observed = [execute_block(block, index) for index, block in enumerate(blocks)]
    print("PASS: raw scalar ARM emission 153 blocks/19584 inputs; guest/native accesses, widths, values, "
          "partial registers and byte canaries; NO checked-memory lowering", flush=True)
    negative_controls(blocks[0], observed[0])
    # Store and native-context variants must reject address/width mutations too.
    for index in (1, 8, 16):
        negative_controls(blocks[index], observed[index])
    print("PASS: 38 post-export corruption controls; 3 static-address zero-extension preconditions", flush=True)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path)
    audit_file(parser.parse_args().export)
