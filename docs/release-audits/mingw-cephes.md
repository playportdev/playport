# The Cephes code in llvm-mingw's mingw-w64 CRT

Host-only audit, 2026-09-30. It answers the "FIXME: Cephes math lib" paragraph of
mingw-w64's `COPYING.MinGW-w64-runtime.txt` for the CRT our PE files link. It is
engineering evidence for the reviewer, not legal clearance.

## Sources

- mingw-w64 `57b595039040eaa15bece85b7cc71d952281b269` (`build/mingw-notices.lock.json`):
  `COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt` (blob `776d5f10`),
  `mingw-w64-crt/Makefile.am` (blob `61c2b3d1`),
  `mingw-w64-crt/lib-common/api-ms-win-crt-math-l1-1-0.def.in` (blob `e54194bf`).
- llvm-mingw `0eca5ac9`'s `build-mingw-w64.sh`, sha256 equal to the lock's
  `42a14441…`: `DEFAULT_MSVCRT` is `ucrt`. The local arm64ec rebuild of the aarch64
  CRT passes `--with-default-msvcrt=ucrt` too ([BUILDING.md](../BUILDING.md)).
- FEX `9fbdc00b` (the `pins.lock` `fex` pin): `External/cephes/LICENSE` (blob
  `3cfe13ae`), which `build/notices-assemble.sh` already collects as
  `cephes-LICENSE.txt` for `xtajit64.dll`.
- SciPy `v1.10.0` `LICENSES_bundled.txt` (sha256 `f0d540cc…`) and scipy/xsf `main`
  `LICENSES_bundled.txt` (sha256 `cbfadc24…`), as precedent only.

This container's proxy refuses lists.debian.org, netlib.org and moshier.net, so the
debian-legal message and the netlib readme were read only as FEX's licence file
quotes them.

## The Cephes-derived files

Every file below carries mingw-w64's public-domain header while its code is Cephes
(it includes `cephes_mconf.h`, "Cephes Math Library Release 2.2", or names
"Copyright 1984, 1987, 1989 [1995] by Stephen L. Moshier" in a comment).

| Files | Built into | Reaches a UCRT link |
| --- | --- | --- |
| `lgamma.c`, `lgammaf.c`, `lgammal.c`, `coshl.c`, `sinhl.c`, `tanhl.c`, `hypotl.c` | `libmingwex.a`, every architecture (`src_libmingwex`) | yes; UCRT's `lgamma`, `lgammaf`, `lgammal` are imported as `DATA` only, so the libmingwex versions are the ones linked |
| `cbrt.c`, `cbrtf.c`, `tgamma.c`, `tgammaf.c` | msvcrt import libraries only (`src_msvcrt_common`) | no; UCRT links these from `ucrtbase.dll` |
| `cbrtl.c`, `erfl.c`, `tgammal.c` | msvcrt libraries on ARM (`src_msvcrt_common_add_arm`) and `libmingwex` on x86 only (`src_libmingwex_x86`) | x86 only (the i686 and x86_64 CRTs) |

Whether a given PE file calls any of these functions was not measured: that needs
the workstation's link inputs. It does not change what the app carries, because the
notice goes with the whole mingw-w64 component.

## The permission

- The netlib readme, as FEX quotes it: the software "is copyrighted by the author.
  What you see here may be used freely but it comes with no support or guarantee."
- Moshier's e-mail of 25 October 2013 to the torch-cephes author, quoted in full in
  FEX's file: "BSD license is fine, modification is OK."
- SciPy distributes its Cephes copy "under 3-clause BSD license with permission from
  the author", citing the 2004 debian-legal message mingw-w64's FIXME also cites.

Each grant names a recipient project, but none limits itself to one, and the netlib
readme's is general. The reading taken here: mingw-w64's copies are usable on the
same terms, and carrying FEX's `cephes-LICENSE.txt` beside the mingw-w64 runtime
notice supplies Moshier's copyright and the grant's text. `build/app-notices.json`
now includes that file in the mingw-w64 component too (the file is already in the
app for FEX; it is not carried twice). The owner, as reviewer, accepted this
reading on 2026-09-30 ([decision 0039](../decisions/0039-owners-licensing-review.md)).

## Still open

- mingw-w64 upstream still has the FIXME; a patch there replacing it with the
  permission's citation would settle it for everyone (not offered from here).
