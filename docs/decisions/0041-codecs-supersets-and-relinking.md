# 0041: Codec patents, whole-superset notices and the relinking route

**Status:** accepted, 2026-09-30, by the copyright holder as reviewer (as in
[0039](0039-owners-licensing-review.md)). The owner carries the risk; this is not
a lawyer's opinion.

## Decision

- **Madeira.** No request is sent to Madeira's author. 0039's readings stand:
  its un-headered `build/*-unix` files under GPL-3.0-or-later, its Wine commits
  under its published licence. The drafted request stays in the ownership audit
  as a record only.
- **Codec patents.** GStreamer's static prelink keeps FFmpeg's (libav) H.264, AAC
  and MPEG-1/2 decoders as today. The owner accepts the patent risk of shipping
  them; no licence is obtained and none is claimed.
- **Notice audits.** The whole-superset notices are enough for release. The open
  linked-member and applicability audits (Wine's bundled libraries, the mingw-w64
  CRT, Khronos and Mesa headers, the Rust standard library's binary derivation)
  close as not required: every collected text is carried, so none can be missing.
  OpenLDAP's Public License 2.8 is taken as GPL-compatible (the FSF lists the
  OpenLDAP licence as compatible with the GNU GPL).
- **Relinking.** Recipients relink the LGPL components by rebuilding from the
  release's Corresponding Source with its tested build instructions (`pp build`
  rebuilds every tree from its pin and series). No per-component relink test of
  Wine, DXMT, the crypto libraries or GStreamer is required before a release.

## Consequences

- The release plan's linked-member audit items and the per-component relink test
  are closed by this decision. The build-from-source route itself must still be
  tested from the source bundle (the plan's "let a recipient build" item).
- A later change is a new decision record.
