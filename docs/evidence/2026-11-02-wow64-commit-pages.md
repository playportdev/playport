# i386 unpacker stubs: a WoW64 commit returned a 16 KiB-rounded base

**Linear:** [PLA-31](https://linear.app/playportdev/issue/PLA-31) (The Binding of Isaac: Rebirth,
[GitHub #101](https://github.com/playportdev/playport/issues/101)),
[PLA-478](https://linear.app/playportdev/issue/PLA-478) (The Witcher 2).

## The failures

Both titles are i386 and end with `c0000005` before their first line, a byte read in the
reserved upper half of the WoW64 window:

- The Witcher 2 `witcher2.exe`, the owner's Steam copy: the 2026-10-29 runs
  ([2026-10-29-witcher2-launch.md](2026-10-29-witcher2-launch.md)) and the 2026-10-30 run on dev
  IPA `5b38a50b857856f0c9f75f7badfe8682911a2764c7023712f377b6401f77d27e`
  (`$PLAYPORT_BUILD/ui-runs/20261030T122712-w2-p476l7/pull2/s1-host.log`, quoted below):
  `eip 02926f76`, `ecx 81625776`.
- The Binding of Isaac: Rebirth `isaac-ng.exe` (a tester's 0.4.x and 0.5.0 reports on GitHub
  #101): `eip 0063fc70`, a byte read at `0xfc2e6701` (0.4.x) and `0xfcae6701` (0.5.0), identical
  across launches and with or without Mesa's `opengl32.dll`.

Just before each fault the guest reserves its payload's `ImageBase` 0x10000000 with
`SizeOfImage` (`0x90000` for The Witcher 2, `0x68000` for Isaac):

```
[wow64-vm] … host=0x71cfff0000 guest=0x10000000 bytes=0x90000 reserve=1 commit=0 null=0 …
D 88 Add SMC interval: 71CFFF0000 - 71D0080000
D 88 Add SMC interval: 71CFFF0000 - 71D004C000
0088:err:wow:Wow64SystemServiceEx Playport: i386 system call 0018 (args ffffffff 031aef1c 00000000 031aef18) failed c0000018 [65]
```

## The stub

`witcher2.exe`'s entry point is in `.bind`, an unpacker: it decrypts a DLL into a heap buffer
(`[ebp-4]`), reserves `ImageBase`, commits `SizeOfImage` and copies the headers to it, then for
each section commits `base + VirtualAddress` for `SizeOfRawData` and copies the section from
`[ebp-4] + PointerToRawData` **to the address the commit returned** (`0x2926ef8`–`0x2926f7a`).
Under desktop Wine 11.20 (`winedbg` breakpoints at `0x2926c28` and `0x2926f16`, scratch prefix
`$PLAYPORT_BUILD/w2-diag/hostrun`) the payload's section table is:

| section | VirtualAddress | SizeOfRawData | PointerToRawData |
| --- | --- | --- | --- |
| `.text` | `0x1000` | `0x5a600` | `0x400` |
| `.rdata` | `0x5c000` | `0x17800` | `0x5aa00` |
| `.data` | `0x74000` | `0x5a00` | `0x72200` |
| `.reloc` | `0x7e000` | `0xe800` | `0x77c00` |

On the phone, `.text`'s commit at `0x10001000` came back as `0x10000000`: the owner-local WoW64
allocator rounded the range out to the 16 KiB host page and returned that base (the third SMC
interval above, `0x10000000`–`0x1005c000`). The stub copied `.text` over its own headers and read
the next section header from the code: the bytes at payload `0x400 + 0x21c` and `0x400 + 0x224`
are `0xec8b5500` and `0x7d8b5756` (read in the same desktop run). That "VirtualAddress" made the
next commit fail (`c0000018`, above), and `[ebp-4]` `0x3d70020` + `0x7d8b5756` is exactly the
faulting `0x81625776`.

Windows returns the 4 KiB page holding the requested address. Isaac's fault follows the same
reserve at 0x10000000 within milliseconds, at an `eip` 0x980 after its entry point: the same stub
family. Isaac is not owned here, so its payload was not read.

## Change

`patches/madeira-unix/0287`: a commit in an owner's window covers and reports whole Wine (4 KiB)
pages; each host page keeps the union of its Wine pages' protections
(`ios_wow64_apply_protection`), as NtProtectVirtualMemory and decommit already did. Reserve is
unchanged. `build/wow64/vm_test.c` commits `.text`'s shape (`base + 0x1000`, `0x2600`) and checks
the returned `base + 0x1000`, `0x3000` and that the header page stays uncommitted; it failed on
that assertion before the patch.

## On the phone

Dev IPA `39e2b0eefb508b7e4f45b140783782709700db598cb571fdc044b2be26839ef2` (the Xbox integration
checkout with this patch), iPhone18,4, iOS 27.2, The Witcher 2 (20920) from Steam; run
`$PLAYPORT_BUILD/ui-runs/20261102T1345-w2-commitfix` (`pp ui --pad --play app-20920`, then
`pp pad send "600 A"` on the launcher, log in `pull2/`).

`witcher2.exe` reserves 0x10000000 as before, every section commit succeeds (no `c0000018`), and
there is no read in the window's upper half: the payload DLL runs (guest code at `0x1005b382`).
It goes on to Playport's Steam client and stops at a check that client does not answer:

```
steamclient: ISteamAppTicket slot 0 GetAppOwnershipTicketData: not served, answers 0
0088:err:dialog:MessageBoxIndirectW [msgbox] style 0x10 caption L"Steam Error" text L"Application load error 6:0000065432"
```

The process then exits 0. That is the next blocker for The Witcher 2, separate from this change.
Before the payload's Steam check it writes once to its own header page, which the stub left
read-only. That raises a guest `c0000005` the payload handles itself; the process carries on to the
check. Hollow Knight passed the smoke check on the same IPA (first frame at +10.03 s,
`$PLAYPORT_BUILD/ui-runs/20261102T133652`). Isaac was not run: it is not owned here.
