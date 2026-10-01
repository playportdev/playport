# Bundled licences and controller navigation

Scope: the licensing branch after rebasing onto main `5b6cfcb`, built in this
worktree's `.work/run`. Local validation only; no release upload or publication.

## Builds and runs

| IPA SHA256 | Source/run | Result |
| --- | --- | --- |
| `b24d73f4fe9f9229467a4e3cab86f1b56852ccace6353a55dca3135b70d55df5` | Clean `4fd87c2`, dev; `$PLAYPORT_BUILD/ui-runs/20261001T105741` and `20261001T105859` | 71 IPA checks passed; explicit `--notices app/Staged/Licenses --distribution` also passed. Licences list and Wine component rendered. Hollow Knight reached its first frame at 8.34 s and ran through first-frame+10 (512 MiB pool, no exhaustion). |
| `7895f0c1036c10ff863adf590889975374a10ee72fe755d21923348060c36e0d` | `4fd87c2` plus the UI fixes committed with this evidence, dev; `$PLAYPORT_BUILD/ui-runs/20261001T112550` | 71 IPA checks passed; six UI actions passed. Text starts on paragraph 0, Down reaches paragraph 1, B restores the file row, then the Wine component row, then About's Licences row. Screenshots show the restored ring onscreen. |

Installed in place each time; the container was kept. Screenshots stay in the
private run directories, not in this evidence directory.

## What the screenshots established

- Settings › About › Licences shows version 0.1.0, Playport copyright, GPL and
  exception links, the warranty disclaimer and the source-code section.
- Wine lists its licence files; opening LGPL-2.1 shows the actual text with
  its title and original copyright/permission paragraphs.
- Loading text originally left only the sidebar focusable, so the ring moved
  to Steam account and B closed Settings. A focusable loading paragraph fixes
  that gap.
- Returning to the list originally restored an offscreen focus without
  scrolling. Nested ScrollViewReader anchors did not identify the actual row.
  Licences now scroll from the ring's measured geometry and current offset;
  the screenshot shows Wine centered with its amber ring after B.

The selected bundle contains 630 files, 7,309,235 bytes, status
`release-reviewed`. The whole collection is still an inventory; this status
records the owner's selection review, not automatic legal clearance.

Host checks passed before device work: 464 Python tests (four skipped), all
six C tests including gamepad ThreadSanitizer, and the earlier full Swift
run including all six Licences tests. Runtime trees were rebuilt here; the
phone launch check uses that rebuilt runtime, not another checkout's IPA.

## Final clean builds at `4186c56`

| Variant | IPA SHA256 | Checks |
| --- | --- | --- |
| dev | `b2cfd59138f6225f3048aa5b2ab5ac99b1911ab6da3b4165862ed3ce92d60442` | 71 checks; explicit selected-bundle comparison and `--distribution` passed |
| release, unsigned | `dfd4339dff7c032533cfaa5b32fb35cf507711f6b6b9ff859fed0e198987da80` | 69 checks; explicit selected-bundle comparison and `--distribution --unsigned` passed, with no profile/team/signer traces and no driver code |

The clean dev was installed in place and repeated seven actions in
`$PLAYPORT_BUILD/ui-runs/20261001T113145`: licences list, Wine, LGPL text,
Down, then B through file list, component list and About. Screenshots confirm
Wine's restored ring is visible, and About's Licences row is ringed at the end.
Hollow Knight in `20261001T113325` reached its first frame at 9.38 s and ran
through first-frame+10; JIT acquire took 2.56 s, with no pool exhaustion.

Both output directories are under this worktree's `.work/out`, with clean
`superproject 4186c567b071573f04f0102db35127f7aeeb77fc` provenance. The release
IPA was **not** installed or re-signed. Full `pp test` passed after the fix:
464 Python tests (four skipped), six C tests and all Swift suites (27, 156,
105; one SteamClient sample skipped).

## Limits

The earlier second IPA intentionally included local UI changes; the final
clean builds above supersede it. No recipient source-bundle rebuild or
re-sign/install test has been done. The
source archive named on the page is the required release companion, not an
already published archive; the publication/distribution gates remain open.
