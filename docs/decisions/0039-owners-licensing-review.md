# 0039: The owner's licensing and release review

**Status:** accepted, 2026-09-30, by the copyright holder, the Playport authors, acting
as the reviewer. These are the owner's decisions on the questions the release
plan left to "qualified review". The owner carries their risk; they are not a
lawyer's opinion.

## Decision

**Notices (the app's selection, `build/app-notices.json`, now `release-reviewed`):**

- **LLVM runtime.** The llvm-mingw runtime code compiled into the PE DLLs needs no
  attribution under Apache-2.0 WITH LLVM-exception (sections 4(a), 4(b) and 4(d)
  are waived for portions embedded by compiling). The app carries LLVM's root
  licence and credit files; the source bundle carries the whole collected set.
- **FreeType** is taken under the FreeType License (FTL), with its credit line.
- **Three Rust crates without licence files** (ns-keyed-archive, plist-macro,
  plist_ffi): the app carries notices Playport writes from their own metadata
  (`build/notices-extra/*-NOTICE-from-metadata`): the MIT licence their Cargo.toml
  names (ns-keyed-archive's `MIT OR Apache-2.0` taken as MIT) and
  "Copyright (c) Jackson Coxson" from their `authors` field, labelled as written
  by Playport. No request is sent upstream.
- **StikJIT and GStreamer** ship with best-effort notices from matching versions,
  labelled so on the licences page, until they are built from pinned sources.
- **mingw-w64's Cephes FIXME** is answered by Moshier's own grants.
- **Supersets carried whole** (Wine `libs/`, Khronos, Mesa headers, Rust sources,
  mingw-w64 sources) stay whole: over-inclusion cannot miss a notice.
- **Madeira.** Its un-headered `build/*-unix` files are taken under the stricter
  of its two statements, GPL-3.0-or-later, and its Wine commits under its
  published licence. No request is sent upstream.

**Release:**

- **Apple's terms.** The owner accepts the risk of building with Apple's SDK on
  Linux and of publishing an ad hoc signed IPA that users re-sign with their own
  Apple ID. Nothing Apple owns is redistributed: the SDK stays off GitHub, out of
  the source bundle and out of CI.
- **History.** Replaced by [0043](0043-published-as-the-playport-authors.md): one squashed
  commit in a new repository, so no history is rewritten.
- **Donations.** No donation page yet: 0.1.0 has no `FUNDING.yml` and its notes
  name no donation link.

## Consequences

- `pp verify --distribution` can pass once the app carries this selection. The
  other release gates (a verified release build, the source bundle, the phone
  checks) still apply.
- A later change to any of these is a new decision record.
