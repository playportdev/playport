# 0042: The source bundle is complete; the archive-fed trials are removed

**Status:** accepted, 2026-10-01, by the copyright holder as reviewer (as in
[0039](0039-owners-licensing-review.md)). The owner carries the risk; this is not
a lawyer's opinion.

## Decision

- **What the licences ask.** An IPA release owes its notices, the Corresponding
  Source of every GPL, LGPL and MPL part it ships, the scripts that build it, and a
  way to relink the LGPL parts (0041: rebuild from that source). They do not ask for
  proof that a build is reproducible, or that it runs offline from the archives alone.
- **The three `missing` entries close; `build/source-bundle.json`'s list is empty:**
  - *GStreamer.* The LGPL sources (GStreamer, GLib, FFmpeg and the rest of the
    1.28.7 recipes' archives) and Cerbero are packed. The rest of the release is
    permissive: MoltenVK (Apache-2.0; the app now carries its licence at v1.2.9, the
    Vulkan SDK 1.3.283.0's MoltenVK) and the Rust standard library and crates in
    `libgstaws` (MIT/Apache-2.0, whose notices the app carries). A permissive part
    owes its notice, not its source. Proving that the binary release was built from
    the packed archives is not required.
  - *StikJIT's embedded idevice* is MIT: its notice is carried; its source is not
    owed. StikJIT's own MPL-2.0 source is packed.
  - *A recipient build from the archives alone.* The recipient's route is the
    public repository at the release's tag (the bundle's Playport archive is the
    same commit) and `pp build --clean`, which checks out each pin; the bundle holds
    every one of those sources, so they stay available whatever happens upstream.
    General-purpose tools (llvm-mingw, Rust, premake, Apple's SDK) are not part of it.
- **The archive-fed component trials are removed:** the `--source-bundle` and
  `--prepared-source` routes in the stages, `build/*-source.py`, `pp source --prepare`,
  their tests and evidence. No build used them. Git history keeps them.

## Consequences

- `pp source` labels a release's bundle complete. `pp release` still refuses a
  bundle whose status contradicts its list.
- The release plan's section 4 items on GStreamer, StikJIT and the recipient build
  close. Replaces 0041's "the build-from-source route must still be tested from
  the source bundle".
- A later change is a new decision record.
