#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute exported, register-only FEX ARM blocks in an optional host simulator.

No FEX instruction semantics are implemented here. The checked native blocks
and independent x86 outcomes come from native_ir_test.cpp. Only the native
exit-linker literal is adapted; the real linker/dispatcher do not execute.
This is not a guest-memory port, shipped ARM64EC test or app entry point.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
MASK64 = (1 << 64) - 1


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_dependency():
    try:
        import unicorn
    except ImportError as error:
        raise RuntimeError("Install the optional hashed arm_simulator_requirements.txt inside .work; "
                           "expose its target directory with PYTHONPATH") from error
    require(unicorn.__version__ == "2.1.4", "requires simulator version 2.1.4")
    return unicorn


def execute_block(block, index):
    uc = check_dependency()
    from unicorn import arm64_const as arm
    require(block["version"] == 1, "unknown export version")
    original = bytes.fromhex(block["code"])
    entry, branch, thunk = (block[key] for key in ("entry", "branch", "thunk"))
    require(0 < entry < branch < thunk < len(original) <= 4096, "unbounded block")
    require(entry == 4 and branch % 4 == 0 and thunk % 8 == 0, "unexpected block alignment")
    require(thunk == ((branch + 4 + 7) & ~7) and thunk + 48 <= len(original), "unexpected thunk layout")
    require(0 < block["pc"] < block["next_pc"] <= 0xffffffff, "invalid guest exit")
    mapping, allowed = block["map"], block["allowed"]
    state_reg, slot = block["state_register"], block["header_slot"]
    require(len(mapping) == 8 and len(set(mapping)) == 8 and len(allowed) == 31, "bad register budget")
    require(all(0 < reg < 30 and allowed[reg] for reg in mapping), "invalid guest register map")
    require(0 < state_reg < 30 and not allowed[state_reg] and state_reg not in mapping, "invalid STATE")
    require(0 <= slot <= 4096 - 8 and slot % 8 == 0, "invalid CPU-state header slot")
    require(len(block["trials"]) == 128, "missing input trials")
    require(struct.unpack_from("<Q", original, thunk + 16)[0] == 0, "exit was already linked")
    require(struct.unpack_from("<Q", original, thunk + 24)[0] == block["next_pc"], "wrong guest exit record")
    require(struct.unpack_from("<q", original, thunk + 32)[0] == branch - thunk, "wrong caller offset")
    require(struct.unpack_from("<Q", original, thunk + 40)[0] != 0, "missing real linker")

    # Three disjoint high-address mappings. There is deliberately NO guest
    # memory, native linker, stack or dispatcher mapping in the simulator.
    code_base = 0x100000000 + index * 0x10000
    state_base, capture = 0x400000000, 0x500000000
    code = bytearray(original)
    struct.pack_into("<Q", code, thunk + 40, capture)
    changed = [i for i, (a, b) in enumerate(zip(original, code)) if a != b]
    require(all(thunk + 40 <= i < thunk + 48 for i in changed), "unexpected code adaptation")
    machine = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
    machine.mem_map(code_base, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
    machine.mem_write(code_base, bytes(code))
    machine.mem_map(state_base, 4096, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
    machine.mem_map(capture, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
    machine.mem_write(capture, struct.pack("<I", 0xd4200000))  # BRK guard, hook stops BEFORE it.
    xregs = [getattr(arm, f"UC_ARM64_REG_X{i}") for i in range(31)]
    expected_trace = [code_base + offset for offset in range(entry, branch + 4, 4)]
    expected_trace += [code_base + thunk, code_base + thunk + 8, code_base + thunk + 12, capture]
    trace, reads, writes, errors = [], [], [], []

    def instruction_hook(emulator, address, size, _):
        pos = len(trace)
        trace.append(address)
        if size != 4 or pos >= len(expected_trace) or address != expected_trace[pos]:
            errors.append(f"unexpected instruction path at {address:#x}")
            emulator.emu_stop()
        elif address == capture:
            emulator.emu_stop()

    def memory_hook(emulator, access, address, size, value, _):
        if access == uc.UC_MEM_READ:
            reads.append((address, size))
            valid = address == code_base + thunk + 40 and size == 8
        else:
            writes.append((address, size, value & MASK64))
            valid = address == state_base + slot and size == 8 and (value & MASK64) == code_base
        if not valid:
            errors.append(f"unexpected memory access at {address:#x}, width {size}")
            emulator.emu_stop()

    machine.hook_add(uc.UC_HOOK_CODE, instruction_hook)
    machine.hook_add(uc.UC_HOOK_MEM_READ | uc.UC_HOOK_MEM_WRITE, memory_hook)
    for trial_index, trial in enumerate(block["trials"]):
        require(all(len(trial[key]) == 8 and all(type(v) is int and 0 <= v <= 0xffffffff for v in trial[key])
                    for key in ("input", "expected")), "invalid oracle registers")
        trace.clear()
        reads.clear()
        writes.clear()
        errors.clear()
        # Poison temporaries and upper halves, rather than accepting implicit
        # simulator zeroes as register inputs. Compare only guest low 32 bits.
        initial = [((0x9e3779b97f4a7c15 * (i + 1 + trial_index * 31)) & MASK64) for i in range(31)]
        for guest_reg, host_reg in enumerate(mapping):
            initial[host_reg] = (initial[host_reg] & 0xffffffff00000000) | trial["input"][guest_reg]
        initial[state_reg] = state_base
        for reg, value in zip(xregs, initial):
            machine.reg_write(reg, value)
        stack = 0x600000000 + trial_index * 16  # Unmapped, must not be used.
        flags = (trial_index & 15) << 28
        machine.reg_write(arm.UC_ARM64_REG_SP, stack)
        machine.reg_write(arm.UC_ARM64_REG_NZCV, flags)
        state = bytearray([0xa5] * 4096)
        machine.mem_write(state_base, bytes(state))
        machine.emu_start(code_base + entry, capture + 4, count=len(expected_trace) + 1)
        label = f"block {index} trial {trial_index} guest {block['pc']:#x}"
        require(not errors and trace == expected_trace, f"{label}: path/capture mismatch {errors}")
        actual = [machine.reg_read(xregs[reg]) & 0xffffffff for reg in mapping]
        require(actual == trial["expected"], f"{label}: guest register mismatch: {actual} != {trial['expected']}")
        require(machine.reg_read(arm.UC_ARM64_REG_PC) == capture, f"{label}: no exit capture")
        require(machine.reg_read(xregs[0]) == capture, f"{label}: incorrect indirect target")
        require(machine.reg_read(xregs[30]) == code_base + thunk + 16, f"{label}: incorrect exit LR")
        require(reads == [(code_base + thunk + 40, 8)], f"{label}: incorrect literal read")
        require(writes == [(state_base + slot, 8, code_base)], f"{label}: incorrect header publication")
        struct.pack_into("<Q", state, slot, code_base)
        require(machine.mem_read(state_base, 4096) == state, f"{label}: CPU-state canary changed")
        require(machine.mem_read(code_base, len(code)) == code, f"{label}: emitted code changed")
        require(machine.reg_read(arm.UC_ARM64_REG_SP) == stack, f"{label}: SP changed")
        require(machine.reg_read(arm.UC_ARM64_REG_NZCV) == flags, f"{label}: NZCV changed")
        for reg in range(1, 30):
            if not allowed[reg]:
                require(machine.reg_read(xregs[reg]) == initial[reg], f"{label}: non-budget X{reg} changed")
    return len(block["trials"])


def negative_controls(block):
    """Corrupt private exports AFTER the real IR and offline machine checks."""
    uc = check_dependency()
    body = block["entry"] + 8
    literal = struct.unpack_from("<I", bytes.fromhex(block["code"]), body)[0]
    require((literal & 0xff800000) == 0x52800000, "control requires first MOVZ W register")
    controls = [
        ("MOV literal", body, literal ^ (1 << 5), "guest register mismatch"),
        ("MOV destination", body, literal ^ 1, "guest register mismatch"),
        ("unexpected load", body, 0xb9400004, "path/capture mismatch"),  # LDR W4, [X0]
        ("missing prologue store", block["entry"] + 4, 0xd503201f, "incorrect header publication"),
        ("self-branch", block["branch"], 0x14000000, "path/capture mismatch"),
        ("BR instead of BLR", block["thunk"] + 12, 0xd61f0000, "incorrect exit LR"),
        ("guest exit record", block["thunk"] + 24, block["next_pc"] ^ 1, "wrong guest exit record"),
    ]
    for label, offset, word, expected_error in controls:
        corrupt = copy.deepcopy(block)
        code = bytearray.fromhex(corrupt["code"])
        struct.pack_into("<I", code, offset, word)
        corrupt["code"] = code.hex()
        try:
            execute_block(corrupt, 0)
        except (RuntimeError, uc.UcError) as error:
            require(expected_error in str(error), f"control {label}: wrong rejection: {error}")
        else:
            raise RuntimeError(f"negative control accepted: {label}")
        print(f"PASS: rejected post-export {label} control", flush=True)
    corrupt = copy.deepcopy(block)
    corrupt["trials"][0]["expected"][0] ^= 1
    try:
        execute_block(corrupt, 0)
    except RuntimeError as error:
        require("guest register mismatch" in str(error), f"wrong oracle-control rejection: {error}")
    else:
        raise RuntimeError("negative control accepted: x86 oracle result")
    print("PASS: rejected x86 oracle-result control", flush=True)


def audit_file(path):
    uc = check_dependency()
    path = Path(path).resolve()
    require(path.is_relative_to(ROOT / ".work"), "exports must stay inside .work")
    library = Path(uc.__file__).parent / "lib/libunicorn.so.2"
    require(library.is_file(), "requires the pinned Linux wheel's native library")
    print(f"simulator {uc.__version__}; native library sha256 {hashlib.sha256(library.read_bytes()).hexdigest()}; "
          f"export sha256 {hashlib.sha256(path.read_bytes()).hexdigest()}", flush=True)
    blocks = [json.loads(line) for line in path.read_text().splitlines()]
    require(len(blocks) == 144, "requires all 144 emission prefixes")
    require({b["granule"] for b in blocks} == {0, 16384, 65536}, "missing host granules")
    require({b["pc"] for b in blocks} == {0x400ffe, 0x900ffe, 0xffff0ffe}, "missing guest PCs")
    for granule in (0, 16384, 65536):
        for pc in (0x400ffe, 0x900ffe, 0xffff0ffe):
            require(sum(b["granule"] == granule and b["pc"] == pc for b in blocks) == 16, "missing prefix cohort")
    trials = sum(execute_block(block, index) for index, block in enumerate(blocks))
    print(f"PASS: simulated ARM execution {len(blocks)} blocks/{trials} inputs; "
          "guest registers, prologue write, unlinked thunk and exit capture; NO native linker/dispatcher", flush=True)
    negative_controls(blocks[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path, help="blocks.jsonl produced by native_decode_audit.py --simulate")
    audit_file(parser.parse_args().export)


if __name__ == "__main__":
    main()
