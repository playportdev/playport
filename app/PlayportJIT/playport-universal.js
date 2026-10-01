// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's universal JIT protocol script, run by StikJIT in the JIT helper
// extension (app/Sources/PlayportJIT/JITHelper.swift, docs/ARCHITECTURE.md,
// "Built-in JIT") as `.custom(URL)`. The app side is
// wine_host_jit_pool_acquire:
//
//   JIT26PrepareRegion(addr, len)   mov x16, #1 ; brk #0xf00d ; ret
//   JIT26Detach()                   mov x16, #0 ; brk #0xf00d ; ret
//
// On every brk #0xf00d stop: skip the brk; for a prepare, allocate the RX
// region when x0 is NULL (`_M<len>,rx`), have StikJIT write the blessing
// marker to every 16 KiB page of it, and return its address in x0; for the
// detach, detach.
//
// StikJIT evaluates this once, top to bottom, after it has put debugserver in
// no-ack mode. The host gives: get_pid(), send_command(packet) (the reply, ""
// on failure), prepare_memory_region(address, length) ("OK") and log(line).
// Every failure throws; StikJIT reports it to the helper, which reports it to
// the app.
"use strict";

const BRK = "a0013ed4";   // brk #0xf00d, little-endian
const PAGE = 0x4000n;     // 16 KiB
const MAX_STOPS = 256;
const MAX_SAFE = 2n ** 53n;

function fail(what) {
    throw new Error("playport-universal: " + what);
}

function command(packet) {
    const reply = send_command(packet);
    if (typeof reply !== "string" || reply === "") fail(packet + ": no reply from debugserver");
    return reply;
}

function expectOK(packet, what) {
    const reply = command(packet);
    if (reply !== "OK") fail(what + ": debugserver replied " + reply.slice(0, 64));
}

// A register or P-packet value: its 8 bytes, little-endian, as hex.
function leHex(value) {
    let out = "";
    for (let i = 0n; i < 8n; i++) out += ((value >> (8n * i)) & 0xffn).toString(16).padStart(2, "0");
    return out;
}

function fromLeHex(field) {
    let value = 0n;
    for (let i = 7; i >= 0; i--) value = (value << 8n) | BigInt(parseInt(field.substr(2 * i, 2), 16));
    return value;
}

function toNumber(value, what) {
    if (value >= MAX_SAFE) fail(what + " 0x" + value.toString(16) + " is not below 2^53");
    return Number(value);
}

// A stop reply: T<signal>, then `NN:<value>;` register fields and `key:value;`
// pairs. Apple's debugserver numbers the arm64 registers 00-1c x0-x28, 1d sp,
// 1e lr, 1f fp, 20 pc, 21 pstate.
function parseStop(reply) {
    if (reply[0] === "W" || reply[0] === "X") fail("the target exited: " + reply.slice(0, 64));
    if (reply[0] !== "T") fail("unexpected stop reply: " + reply.slice(0, 128));
    const thread = /thread:([0-9a-fA-F]+);/.exec(reply);
    if (!thread) fail("stop reply has no thread: " + reply.slice(0, 128));
    const regs = {};
    const field = /(?:^T[0-9a-fA-F]{2}|;)([0-9a-fA-F]{2}):([0-9a-fA-F]{16})(?=;)/g;
    for (let m; (m = field.exec(reply)) !== null;) regs[m[1].toLowerCase()] = fromLeHex(m[2]);
    for (const r of ["00", "01", "10", "20"]) {
        if (!(r in regs)) fail("stop reply has no register " + r + ": " + reply.slice(0, 128));
    }
    return { thread: BigInt("0x" + thread[1]).toString(16), x0: regs["00"], x1: regs["01"], x16: regs["10"], pc: regs["20"] };
}

const pid = get_pid();
const attach = command("vAttach;" + pid.toString(16));
if (attach[0] === "E") fail("vAttach to pid " + pid + " failed: " + attach.slice(0, 64));
log("attached to pid " + pid);

let prepares = 0;
for (let stop = 1; ; stop++) {
    if (stop > MAX_STOPS) fail("no detach after " + MAX_STOPS + " stops");
    const s = parseStop(command("c"));
    const insn = command("m" + s.pc.toString(16) + ",4");
    if (insn.toLowerCase() !== BRK) {
        fail("stop " + stop + " at pc 0x" + s.pc.toString(16) + " is not brk #0xf00d (" + insn.slice(0, 16) + ")");
    }
    expectOK("P20=" + leHex(s.pc + 4n) + ";thread:" + s.thread + ";", "skipping the brk");

    if (s.x16 === 1n) {
        let addr = s.x0;
        if (addr === 0n) {
            const reply = command("_M" + s.x1.toString(16) + ",rx");
            if (reply[0] === "E" || !/^[0-9a-fA-F]+$/.test(reply)) fail("allocating 0x" + s.x1.toString(16) + " bytes RX: " + reply.slice(0, 64));
            addr = BigInt("0x" + reply);
        }
        const length = s.x1 > PAGE ? s.x1 : PAGE;
        const done = prepare_memory_region(toNumber(addr, "region address"), toNumber(length, "region length"));
        if (done !== "OK") fail("preparing 0x" + addr.toString(16) + ": " + done);
        expectOK("P0=" + leHex(addr) + ";thread:" + s.thread + ";", "returning the region address");
        prepares++;
        log("prepared 0x" + addr.toString(16) + " (" + (length / PAGE).toString() + " pages)");
        continue;
    }
    if (s.x16 === 0n) {
        expectOK("D", "detach");
        log("detached after " + prepares + " prepare(s)");
        break;
    }
    fail("unknown call x16=0x" + s.x16.toString(16) + " at stop " + stop);
}
