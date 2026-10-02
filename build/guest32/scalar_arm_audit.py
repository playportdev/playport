#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute compiled scalar helper + real g32 checks, not FEX IR lowering.

The optional call_block is a separately emitted FEX call-ABI fixture.

Uses the optional hash-locked Unicorn installation. No data hook fabricates
results, maps a faulting access, or implements a g32 operation. OS VM setup is
excluded: the C fixture initializes metadata and the simulator maps sparse RW
backing above 4 GiB, including pages denied by guest permissions.
"""
import hashlib
from pathlib import Path
import struct
import subprocess

from arm_simulator_audit import ROOT, MASK64, check_dependency, require

OUTPUT = ROOT / ".work/guest32/scalar-arm"
BACKING, STACK, CAPTURE = 0x800000000, 0x600000000, 0x500000000
SOURCE = ROOT / "build/guest32"


def build(name, helper=None, memory=None, clobber=False):
    include = OUTPUT / "include"
    (include / "sys").mkdir(parents=True, exist_ok=True)
    # Only declarations for unreachable OS operations; no OS function bodies.
    # Clang's own freestanding stdint/stddef headers supply actual ARM64 types.
    headers = {
        "stdlib.h": "#include <stddef.h>\nvoid *calloc(size_t, size_t);\nvoid free(void *);\n",
        "string.h": "#include <stddef.h>\nvoid *memmove(void *, const void *, size_t);\n"
                    "void *memset(void *, int, size_t);\n",
        "unistd.h": "#define _SC_PAGESIZE 30\nlong sysconf(int);\n",
        "sys/mman.h": "#include <stddef.h>\n#define PROT_NONE 0\n#define PROT_READ 1\n"
                      "#define PROT_WRITE 2\n#define MAP_PRIVATE 2\n#define MAP_ANONYMOUS 32\n"
                      "#define MAP_FAILED ((void *)-1)\n#define MADV_DONTNEED 4\n"
                      "void *mmap(void *, size_t, int, int, int, long);\n"
                      "int munmap(void *, size_t);\nint mprotect(void *, size_t, int);\n"
                      "int madvise(void *, size_t, int);\n",
    }
    for path, text in headers.items():
        (include / path).write_text(text)
    fixture = SOURCE / "scalar_arm_fixture.c"
    if memory is not None:
        fixture = OUTPUT / f"{name}-fixture.c"
        fixture.write_text((SOURCE / "scalar_arm_fixture.c").read_text().replace(
            '#include "guest32.c"', f'#include "{memory.name}"'))
    objects = []
    for index, path in enumerate((fixture, helper or SOURCE / "scalar_access.c")):
        obj = OUTPUT / f"{name}-{index}.o"
        subprocess.run(["clang", "--target=aarch64-none-elf", "-std=c11", "-O2",
                        "-ffreestanding", "-fno-builtin", "-fno-stack-protector",
                        "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra", "-Werror",
                        "-I", str(include), "-I", str(SOURCE), "-c", str(path), "-o", str(obj)],
                       check=True, timeout=60)
        objects.append(obj)
    if clobber:
        obj = OUTPUT / f"{name}-clobber.o"
        subprocess.run(["clang", "--target=aarch64-none-elf", "-c",
                        str(SOURCE / "scalar_call_clobber.S"), "-o", str(obj)], check=True, timeout=60)
        objects.append(obj)
    elf = OUTPUT / f"{name}.elf"
    subprocess.run(["ld.lld", "-static", "--gc-sections", "--no-undefined",
                    "--image-base=0x1ffff0000", "-Ttext=0x200000000", "-e", "g32_scalar_access", "-u", "audit_initialize",
                    *(["-u", "audit_clobber"] if clobber else []),
                    *map(str, objects), "-o", str(elf)], check=True, timeout=60)
    return elf


def load_elf(machine, uc, path):
    data = path.read_bytes()
    require(data[:7] == b"\x7fELF\x02\x01\x01" and struct.unpack_from("<H", data, 18)[0] == 183,
            "requires little-endian ELF64 AArch64")
    offset = struct.unpack_from("<Q", data, 32)[0]
    entry_size, count = struct.unpack_from("<HH", data, 54)
    require(entry_size == 56 and count < 16, "ELF program headers")
    pages, contents, executable = {}, [], []
    for index in range(count):
        kind, flags, pos, address, _, size, extent, _ = struct.unpack_from("<IIQQQQQQ", data, offset + index * 56)
        require(kind != 2, "unexpected dynamic linking")
        if kind != 1:
            continue
        require(0 < extent < 0x1000000 and size <= extent and pos + size <= len(data)
                and 0x100000000 <= address < 0x300000000, "ELF segment bounds")
        protection = (uc.UC_PROT_READ if flags & 4 else 0) | (uc.UC_PROT_WRITE if flags & 2 else 0) | (uc.UC_PROT_EXEC if flags & 1 else 0)
        for page in range(address & ~4095, (address + extent + 4095) & ~4095, 4096):
            pages[page] = pages.get(page, 0) | protection
        contents.append((address, data[pos:pos + size]))
        if flags & 1:
            executable.append((address, address + size))
    # Coalesce pages, especially the 5 MiB BSS metadata segment.
    runs = []
    for page, protection in sorted(pages.items()):
        require(protection != 7, "ELF writable executable page")
        if runs and runs[-1][1] == page and runs[-1][2] == protection:
            runs[-1] = (runs[-1][0], page + 4096, protection)
        else:
            runs.append((page, page + 4096, protection))
    for start, end, protection in runs:
        machine.mem_map(start, end - start, protection)
    for address, content in contents:
        machine.mem_write(address, content)
    symbols = {}
    text = subprocess.check_output(["llvm-nm", "--defined-only", str(path)], text=True)
    for line in text.splitlines():
        address, _, name = line.split()
        symbols[name] = int(address, 16)
    require(all(name in symbols for name in ("audit_space", "audit_initialize", "audit_states", "audit_owners", "g32_scalar_access", "memmove")), "missing real helper symbols")
    require(not set(symbols) & {"g32_create", "g32_commit", "mmap", "mprotect", "calloc"}, "OS operations retained")
    return symbols, runs, executable


def cases(native_addresses):
    # All 64 committed permission pairs, plus decommitted neighbors.
    pairs = [(8 + left, 8 + right) for left in range(8) for right in range(8)]
    pairs += [(0, 11), (11, 0), (0, 0)]
    for granule in (4096, 16384, 65536):
        for left, right in pairs:
            for address in (0x10000, 0x10001, 0x10ffd, 0x10ffe, 0x10fff):
                for width in (1, 2, 4):
                    for store in (False, True):
                        yield granule, left, right, address, width | (0x100 if store else 0), False, False
        for address in (0, 0xffff, 0xffffefff, 0xfffffffc, 0xfffffffd, 0xfffffffe,
                        0xffffffff, 0x100000000, 0x100010000, BACKING + 0x10000, *native_addresses):
            for width in (1, 2, 4):
                for store in (False, True):
                    yield granule, 11, 11, address, width | (0x100 if store else 0), False, False
        for operation in (0, 3, 8, 0x10101, 0xffffffff):
            yield granule, 11, 11, 0x10000, operation, False, False
        for poisoned, null in ((True, False), (False, True)):
            for operation in (4, 0x104):
                yield granule, 11, 11, 0x10000, operation, poisoned, null


def audit(path, call_block=None):
    uc = check_dependency()
    from unicorn import arm64_const as arm
    machine = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
    symbols, segments, executable = load_elf(machine, uc, path)
    code, caller_state, descriptor = 0x900000000, 0x400000000, 0x700000000
    if call_block is not None:
        emitted = bytes.fromhex(call_block["code"])
        require(0 < len(emitted) < 4096 and len(emitted) % 4 == 0, "caller emission bounds")
        machine.mem_map(code, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
        machine.mem_write(code, emitted)
        executable.append((code, code + len(emitted)))
        machine.mem_map(caller_state, (call_block["state_size"] + 4095) & ~4095,
                        uc.UC_PROT_READ | uc.UC_PROT_WRITE)
        machine.mem_map(descriptor, 4096, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
        require(call_block["eax"] == 4
                and set(call_block["gprs"]) == {*range(4, 18), *range(19, 25), 26, 27, 29, 30}
                and set(call_block["fprs"]) == set(range(2, 32)), "native 32-bit FEX register budget")
        allowed_spills = {byte for offset, width in call_block["spills"] for byte in range(offset, offset + width)}
        require(all(0 <= byte < call_block["state_size"] for byte in allowed_spills), "native spill bounds")
    backing_ranges = [(BACKING + 0x10000, BACKING + 0x12000),
                      (BACKING + 0xffffe000, BACKING + 0x100000000)]
    for start, end in backing_ranges:
        machine.mem_map(start, end - start, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
    machine.mem_map(STACK, 0x10000, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
    machine.mem_map(CAPTURE, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
    machine.mem_write(CAPTURE, struct.pack("<I", 0xd4200000))
    xregs = [getattr(arm, f"UC_ARM64_REG_X{i}") for i in range(31)]
    vregs = [getattr(arm, f"UC_ARM64_REG_Q{i}") for i in range(32)]
    active, captured = False, False
    helper_calls = 0
    accesses, errors = [], []
    trace = set()

    def in_range(address, size, ranges):
        return any(start <= address and address + size <= end for start, end in ranges)

    def instruction(emulator, address, size, _):
        nonlocal captured, helper_calls
        if address == CAPTURE:
            captured = True
            emulator.emu_stop()
        elif size != 4 or not in_range(address, size, executable):
            errors.append("instruction escaped compiled code")
            emulator.emu_stop()
        elif active:
            trace.add(address)
            if address == symbols["g32_scalar_access"]:
                helper_calls += 1
            if call_block is not None and address == symbols["g32_scalar_access"]:
                require(emulator.reg_read(arm.UC_ARM64_REG_SP) % 16 == 0, "unaligned helper SP")
                require([emulator.reg_read(xregs[i]) for i in range(4)] == arguments,
                        "emitted helper arguments mismatch")

    def memory(emulator, access, address, size, value, _):
        if not active:
            return
        write = access == uc.UC_MEM_WRITE
        if in_range(address, size, backing_ranges):
            accesses.append((write, address, size, value if write else None))
        elif in_range(address, size, [(STACK, STACK + 0x10000)]):
            if call_block is not None and not in_range(address, size, [(STACK + 0x7000, STACK + 0x8000)]):
                errors.append("caller escaped bounded stack frame")
                emulator.emu_stop()
        elif call_block is not None and in_range(address, size, [(caller_state, caller_state + call_block["state_size"])]):
            if write and not in_range(address - caller_state, size,
                                      [(offset, offset + width) for offset, width in call_block["spills"]]):
                errors.append("caller wrote outside native spill slots")
                emulator.emu_stop()
        elif call_block is not None and in_range(address, size, [(descriptor, descriptor + 48)]):
            if write and not in_range(address, size, [(descriptor + 24, descriptor + 48)]):
                errors.append("caller wrote native arguments")
                emulator.emu_stop()
        elif not write and in_range(address, size, [(start, end) for start, end, _ in segments]):
            pass
        else:
            errors.append("forbidden native/metadata access")
            emulator.emu_stop()

    def invalid(_emulator, _access, _address, _size, _value, _):
        errors.append("unmapped memory access")
        return False

    machine.hook_add(uc.UC_HOOK_CODE, instruction)
    machine.hook_add(uc.UC_HOOK_MEM_READ | uc.UC_HOOK_MEM_WRITE, memory)
    machine.hook_add(uc.UC_HOOK_MEM_INVALID, invalid)

    def run(entry):
        nonlocal captured
        captured = False
        if call_block is None or not active:
            machine.reg_write(xregs[30], CAPTURE)
        machine.reg_write(arm.UC_ARM64_REG_SP, STACK + 0x8000)
        try:
            machine.emu_start(entry, CAPTURE + 4, count=4096)
        except uc.UcError as error:
            raise RuntimeError(f"compiled ARM fault: {errors}: {error}") from error
        require(captured and not errors, f"no clean return: {errors}")

    count = 0
    volatile_changes = {"success": set(), "rejection": set()}
    flag_changes = {"success": False, "rejection": False}
    native_addresses = (symbols["audit_space"], symbols["audit_states"],
                        symbols["g32_scalar_access"], STACK, CAPTURE)
    if call_block is not None:
        native_addresses += (code, caller_state, descriptor)
    for count, (granule, left, right, address, operation, poisoned, null) in enumerate(cases(native_addresses), 1):
        active = False
        errors.clear()
        for register, value in zip(xregs, (BACKING, granule, left, right, int(poisoned))):
            machine.reg_write(register, value)
        run(symbols["audit_initialize"])
        buffers = [bytearray((i * 73 + count * 19) & 255 for i in range(8192)) for _ in backing_ranges]
        for (start, _), buffer in zip(backing_ranges, buffers):
            machine.mem_write(start, bytes(buffer))
        value = (count * 0x9e3779b9) & 0xffffffff
        expected, status = value, 0
        width, store = operation & ~0x100, bool(operation & 0x100)
        if width not in (1, 2, 4) or address > 0xffffffff:
            status = 1
        elif poisoned or null:
            status = 6
        elif address < 0x10000 or address + width > 0x100000000:
            status = 1
        else:
            permission = 2 if store else 1
            for page in range(address // 4096, (address + width - 1) // 4096 + 1):
                state = left if page in (16, 0xffffe) else right if page in (17, 0xfffff) else 0
                if state & (8 | permission) != (8 | permission):
                    status = 5
            if status == 0:
                index = 0 if address < 0x12000 else 1
                offset = BACKING + address - backing_ranges[index][0]
                mask = (1 << (8 * width)) - 1
                if store:
                    buffers[index][offset:offset + width] = (value & mask).to_bytes(width, "little")
                else:
                    expected = (value & ~mask) | int.from_bytes(buffers[index][offset:offset + width], "little")
        initial = [(0x9e3779b97f4a7c15 * (i + count * 31)) & MASK64 for i in range(31)]
        vectors = [((v << 64) | (v ^ MASK64)) for v in initial] + [1]
        arguments = [0 if null else symbols["audit_space"], address, operation, value]
        if call_block is not None:
            for i in (4, 5, 6, 7, 8, 9, 10, 11, 26, 27):
                initial[i] &= 0xffffffff
            initial[call_block["eax"]] = value
            initial[28] = caller_state
            machine.mem_write(caller_state, bytes([0x5a]) * call_block["state_size"])
            machine.mem_write(descriptor, struct.pack("<QQIIQQQ", *arguments, 0, 0, 0))
            machine.mem_write(STACK, bytes([0xc3]) * 0x10000)
        for register, v in zip(xregs, initial):
            machine.reg_write(register, v)
        for register, v in zip(vregs, vectors):
            machine.reg_write(register, v)
        if call_block is None:
            for register, v in zip(xregs, arguments):
                machine.reg_write(register, v)
        flags = (count & 15) << 28
        machine.reg_write(arm.UC_ARM64_REG_NZCV, flags)
        accesses.clear()
        helper_calls = 0
        active = True
        run(code if call_block is not None else symbols["g32_scalar_access"])
        require(helper_calls == 1, "compiled helper entry census")
        if call_block is None:
            require(machine.reg_read(xregs[0]) == (status << 32) | expected, "packed status/value mismatch")
            require(all(machine.reg_read(xregs[i]) == initial[i] for i in range(19, 30)), "callee-saved GPR mismatch")
            require(all(machine.reg_read(vregs[i]) & MASK64 == vectors[i] & MASK64 for i in range(8, 16)), "callee-saved SIMD mismatch")
        else:
            result, fault_pc, continued = struct.unpack("<QQQ", machine.mem_read(descriptor + 24, 24))
            require(result == (status << 32) | expected, "caller packed result mismatch")
            require((fault_pc, continued) == ((0x401234, 0) if status else (0, 1)),
                    "caller rejection/continuation/guest-PC mismatch")
            wanted = initial.copy()
            if not status:
                wanted[call_block["eax"]] = expected
            require(all(machine.reg_read(xregs[i]) == wanted[i]
                        for i in {*call_block["gprs"], 25, 28}), "live FEX GPR mismatch")
            require(all(machine.reg_read(vregs[i]) == vectors[i] for i in call_block["fprs"]),
                    "live FEX SIMD mismatch")
            require(machine.reg_read(arm.UC_ARM64_REG_NZCV) == flags, "live FEX NZCV mismatch")
            require(machine.mem_read(code, len(emitted)) == emitted, "caller code canary mismatch")
            require(all(byte == 0x5a for i, byte in enumerate(machine.mem_read(caller_state, call_block["state_size"]))
                        if i not in allowed_spills), "native CPU-state canary mismatch")
            require(machine.mem_read(STACK, 0x7000) == bytes([0xc3]) * 0x7000
                    and machine.mem_read(STACK + 0x8000, 0x8000) == bytes([0xc3]) * 0x8000,
                    "caller stack canary mismatch")
            require(machine.mem_read(descriptor, 24) == struct.pack("<QQII", *arguments), "native argument canary mismatch")
        require(machine.reg_read(arm.UC_ARM64_REG_SP) == STACK + 0x8000, "SP mismatch")
        outcome = "rejection" if status else "success"
        volatile_changes[outcome].update(i for i in range(4, 19) if machine.reg_read(xregs[i]) != initial[i])
        flag_changes[outcome] |= machine.reg_read(arm.UC_ARM64_REG_NZCV) != flags
        if status:
            require(not accesses, "rejected access touched backing")
        else:
            require(accesses and all(write == store for write, *_ in accesses), "backing access direction")
            touched = [byte for _, start, size, _ in accesses for byte in range(start, start + size)]
            require(sorted(touched) == list(range(BACKING + address, BACKING + address + width)), "full-width backing census")
        for (start, _), buffer in zip(backing_ranges, buffers):
            require(machine.mem_read(start, 8192) == buffer, "backing byte canary mismatch")
    require(count == (6381 if call_block is not None else 6327), "compiled helper coverage census")
    require(symbols["memmove"] in trace and symbols["g32_scalar_access"] in trace, "real compiled copy/helper never executed")
    observed = {key: sorted(value) for key, value in volatile_changes.items()}
    print(f"observed volatile GPR changes {observed}; NZCV changes {flag_changes}", flush=True)
    return count


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    uc = check_dependency()
    library = Path(uc.__file__).parent / "lib/libunicorn.so.2"
    print(f"simulator {uc.__version__}; sha256 {hashlib.sha256(library.read_bytes()).hexdigest()}", flush=True)
    print(subprocess.check_output(["clang", "--version"], text=True).splitlines()[0], flush=True)
    for name in ("scalar_access.c", "scalar_access.h", "guest32.c", "guest32.h", "scalar_arm_fixture.c"):
        print(f"sha256 {hashlib.sha256((SOURCE / name).read_bytes()).hexdigest()} {name}", flush=True)
    elf = build("optimized")
    print(f"ELF sha256 {hashlib.sha256(elf.read_bytes()).hexdigest()}", flush=True)
    count = audit(elf)
    print(f"PASS: compiled ARM64 scalar helper {count} cases; real checks/copy, sparse high backing, "
          "transactional denial, AAPCS64 callee-saved registers; NOT FEX call lowering", flush=True)
    controls = [
        ("native-truncation", "scalar_access.c", " || address > UINT32_MAX", "", "packed status/value mismatch"),
        ("store-width", "scalar_access.c", "g32_write(space, (uint32_t)address, bytes, width)",
         "g32_write(space, (uint32_t)address, bytes, 1)", "full-width backing census"),
        ("partial-register", "scalar_access.c", "if (status == G32_OK) {",
         "if (status == G32_OK) { value = 0;", "packed status/value mismatch"),
        ("status-packing", "scalar_access.c", "(uint64_t)status << 32", "(uint64_t)status << 16", "packed status/value mismatch"),
        ("first-page-only", "guest32.c", "p <= end", "p <= end && p == address / G32_PAGE", "packed status/value mismatch"),
        ("permission-bypass", "guest32.c", "(s->state[p] & (COMMITTED | permissions)) != (COMMITTED | permissions)",
         "!(s->state[p] & COMMITTED)", "packed status/value mismatch"),
        ("rejected-prefix-write", "guest32.c",
         "g32_result r = g32_translate(s, address, size, permissions, &host);\n    if (r != G32_OK) return r;",
         "g32_result r = g32_translate(s, address, size, permissions, &host);\n"
         "    if (r != G32_OK) {\n"
         "        if (permissions == G32_WRITE) s->base[address] = *(unsigned char *)buffer;\n"
         "        return r;\n    }", "rejected access touched backing"),
    ]
    for name, filename, old, new, rejection in controls:
        text = (SOURCE / filename).read_text()
        require(text.count(old) == 1, f"{name}: non-unique mutation")
        mutant = OUTPUT / f"{name}.c"
        mutant.write_text(text.replace(old, new))
        elf = build(name, **({"helper": mutant} if filename == "scalar_access.c" else {"memory": mutant}))
        try:
            audit(elf)
        except RuntimeError as error:
            require(rejection in str(error), f"{name}: wrong rejection: {error}")
        else:
            raise RuntimeError(f"accepted ARM helper corruption {name}")
        print(f"PASS: rejected ARM helper {name}", flush=True)


if __name__ == "__main__":
    main()
