# FEX's per-thread band cost: a 4 MiB call-return stack and 1 MiB rpmalloc spans

[PLA-408](https://linear.app/playportdev/issue/PLA-408),
[decision 0121](../decisions/0121-a-4-mib-call-return-stack-and-1-mib-spans.md).

## Before

The baseline is run `20261019T105650` (IPA `4232943d…`, host log `pull/s1-host.log`). It is RDR2's
Steam play with the signed-in Rockstar Games Launcher
([record](2026-10-19-rockstar-physicaldrive.md)). The band filled at 197 threads: 718 spans
(11.2 GiB), 197 call-return stacks of 16 MiB and two guard pages, 197 L1 caches, and 1,238 MB of
other views. That is about 83 MB a thread.

The thread census at the peak counts the `[srv-own] new_thread`, `[band] ThreadInit` and
`[thr-name]` lines. Its rpmalloc bytes per thread, by process:

| process | threads | rpmalloc per thread |
| --- | --- | --- |
| `Launcher.exe` | 54 | 41 MB |
| CEF browser (`SocialClubHelper.exe`) | 49 | 54 MB |
| CEF renderers | 16–20 | 49–83 MB |
| services | 13 | 32 MB |

Every ThreadInit mapped a small and a medium span (`spans mapped small=1 medium=1`). By the
`[band]` lines' running counts, a process with 48 live threads had mapped 53 small, 100 medium
and 11 large spans. One with 17 live threads had mapped 21 small, 44 medium and 29 large spans,
and each large span was 16 MiB.

## The change

- **Call-return stack.** `patches/fex` 0055 brings back 0113's 4 MiB stack (removed 2026-10-17),
  ported onto the current tree with `git am -3` and no conflict. It also makes the
  `[bogus-state]` window line use the named constants.
- **Spans.** `patches/rpmalloc` 0006 sets 1 MiB spans with the medium and large pages the span,
  and cuts the large classes above 896 KiB. Decision 0121 gives the reasoning, with line
  citations in `rpmalloc.c`.
- **Census.** `patches/madeira-unix` 0164 knows the 1 MiB span and the 4 MiB stack.

A model of rpmalloc's class table and `get_size_class` (Python, from the patched source)
confirmed the following:
- the iOS table has 104 classes (73 small, 24 medium, 7 large);
- every class fits at least one block in its page;
- every size up to 2 MiB maps to the smallest class that holds it, or to the huge path above
  917,504 bytes.

The built FEX modules no longer carry the old `rpmalloc-span16` marker, so they were rebuilt
with the new constants.
