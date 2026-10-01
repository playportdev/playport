# 0040: Playport's lines in the vkd3d-proton, gbe and idevice series take upstream's licence

**Status:** accepted, 2026-09-30, by the copyright holder, the Playport authors.

## Context

The licence of Playport's own lines in `patches/vkd3d-proton`, `patches/gbe` and
`patches/idevice` was not stated ([LICENSING.md](../LICENSING.md#open-items)). The
Wine and Mesa series are already offered under their upstream's licence.

## Decision

Playport offers its lines in each of these series under the licence of the tree
it patches:

| Series | Licence |
| --- | --- |
| `patches/vkd3d-proton` | LGPL-2.1-or-later, as vkd3d-proton |
| `patches/gbe` | LGPL-3.0, as gbe_fork |
| `patches/idevice` | MIT, as idevice |

## Consequences

- Each patched tree stays under one licence, and each patch can be offered
  upstream as it is (the idevice patch to jkcoxson/idevice).
- The series' `Offered-upstream:` trailers need no change of licence to be sent.
- A patch that copies code from elsewhere keeps that code's own terms.
