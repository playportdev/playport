# 0110: Playport supplies its own build of the CEF version a client ships, loaded in its place

**Status:** accepted by the owner, 2026-10-16, with the plan's D1–D6 as recommended.
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[PLA-369](https://linear.app/playportdev/issue/PLA-369),
[plan](../plans/finished.md#own-low-address-space-cef).

Amended by [0150](0150-dev-single-process-social-club.md): the owner permits a
dev-only, exact-build-guarded in-memory Social Club page-bridge patch for
opt-in single-process mode; all other no-patching restrictions remain.

## Context

Social Club, the Rockstar Games Launcher's UI and RDR2's in-game overlay, embeds CEF
`143.0.14+gdd46a37+chromium-143.0.7499.193`. Rockstar built it themselves: the DLLs differ from the
stock build, while the data files are identical.

Each CEF process reserves two 32 GiB PartitionAlloc pools, each aligned to 32 GiB, plus two 16 GiB
regions. Renderers also reserve a third pool and a V8 sandbox placeholder of about 1.3 TiB
([swap test](../evidence/2026-10-16-cef-swap-test.md)). iOS gives the app one window ending at
`0x80_0000_0000`, with about 48 GiB usable, and has room for two such slots at most. On the phone,
every helper stops itself in `chrome_elf.dll` at init
([chunk 9](../evidence/2026-10-15-rockstar-stage0-phone.md)).

Nothing in Chromium's build arguments makes those pools small on Windows x64
(`research-pla369-cef-opensource.md` in the build area). Two ways out were ruled out:
- patching Rockstar's binaries in memory (the owner, 2026-10-16);
- a larger address space, which no signing route provides.

Under desktop Proton, the launcher accepted a stock CEF distribution of that exact version in place
of its own, and reached its sign-in page as it does with Rockstar's files.

## Decision

- **The build.** Playport builds the same CEF revision from its open-source sources, as a new
  pinned component with a patch series under `patches/cef/` and `patches/chromium/`. The build is
  configured for low address-space use:
  - one patch makes PartitionAlloc's `kPoolMaxSize` 1 GiB (or 2 GiB if 1 proves too small);
  - PartitionAlloc as malloc, BackupRefPtr and the external metadata region are off;
  - the V8 sandbox, V8 pointer compression and the cppgc caged heap are off.
- **How it is loaded.** It is loaded in place of a client's CEF only when the client's `libcef.dll`
  version resource matches the built version exactly. The client's files on disk are never changed;
  the substitution is made when the DLLs and data files are loaded.
  - Any other version is left alone, and a `[cef-swap]` line logs both cases.
  - Rockstar's own executables and DLLs (`socialclub.dll`, `SocialClubHelper.exe`, the game) are
    never patched, on disk or in memory.
  - This amends decision 0109's "Rockstar's files are never changed" only in that a library they
    load from their folder may come from Playport. The bytes Rockstar wrote stay as written.
- **Toolchain.** It is cross-compiled from this Linux workstation with clang-cl and lld-link, using
  the MSVC CRT and the Windows SDK as downloaded by xwin. The owner accepts Microsoft's licence for
  that download; agents do not. CEF's and Chromium's build scripts get the patches they need to
  target Windows from a Linux host.
- **Licences.** It ships with Chromium's generated credits and CEF's BSD licence. ffmpeg's LGPL
  source and relinking duties are met as for Wine ([LICENSING.md](../LICENSING.md)). It uses
  `ffmpeg_branding="Chromium"` and `proprietary_codecs=false`, and ships no Widevine CDM.

## Consequences

- **Security.** Social Club's web pages run in a Chromium with no V8 sandbox, and from a branch CEF
  no longer supports, so it gets no security fixes.
- **Updates.** Each Social Club update to a new CEF version means a new 4–8 h build and a fresh
  check. Until then, the version guard leaves the new CEF alone and the launcher fails as it does
  today.
- **Build area.** The build uses 150–200 GB of `.work` and hours per build. The IPA grows by the
  CEF payload (about 300 MB uncompressed for the DLLs and paks), unless the plan finds a smaller
  way to deliver it.
- **Unknowns.** Nobody tests this combination of build settings on Windows x64, so it may need
  more Chromium patches of Playport's own. Whether it fits the phone's window alongside Wine and
  FEX is known only from arithmetic until it runs there.
- **Other launchers.** A later CEF-based launcher can use the same mechanism with a build of its
  own CEF version, under a new record.
