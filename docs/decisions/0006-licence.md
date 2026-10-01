# 0006: Licence

**Status:** accepted, 2026-09-24

## Decision

Playport is licensed under GPL-3.0-or-later. Its copyright holders, the
Playport authors, adopted the Madeira Converter Exception, version 1, for Playport's
own code on 2026-09-24 (`LICENSE-EXCEPTION.md`). Contributions are accepted
under the same terms. Details: [LICENSING.md](../LICENSING.md).

## Why

- **GPL-3.0-or-later** matches Madeira, so the whole combination stays "or
  later". Every other component (Wine's LGPL-2.1-or-later, the MIT and 0BSD
  upstreams, the statically linked LGPL, FreeType and LLVM code) is compatible
  with it. GPL-3.0-only would gain nothing.
- **The exception now, not later.** It permits combining Playport with
  Apple's Metal Shader Converter library and Apple's system frameworks. It
  costs nothing today, because Playport has one author. Adding it later would
  need the consent of every contributor by then. It keeps open a Direct3D 12
  path through Madeira's native runtime, which uses that converter.

## Consequences

- Playport still does not build or ship the converter or Madeira's native
  D3D12 runtime. Adopting that path needs its own decision and a reading of
  Apple's converter agreement.
- The exception covers only code Playport's holder owns; it does not change
  the licences of Madeira, its forks, Wine or third-party material.
- The obligations for every IPA given to anyone are unchanged by the
  exception: Corresponding Source, LGPL relinking, Installation Information and
  complete notices ([DISTRIBUTION.md](../DISTRIBUTION.md)).
- `.githooks/pre-push` refuses any public push while the exception file is a
  draft, and CI checks that it is adopted.
