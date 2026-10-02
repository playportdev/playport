# Back restores the screen that opened a destination

## Change

`AppNavigation.openGame` used to force Library and discard Home or Settings
as the origin. Setup also discarded the game path, and page Back guessed Home.
PlayportKit `AppRoutes` now keeps screen snapshots and origin focus; the SwiftUI
adapter uses those for every screen transition and native game-path dismissal.
Options/achievements and licence pages still unwind before their parent screen.
The game footer names its actual return destination. GameDetailView no longer
restores focus independently in `onDisappear`, which could overwrite the router.
Settings › Setup check's Steam link also remembers its originating section/row.
Sidebar choices remain section selection, not extra history entries.

Reviewed Home hero/recent/find/search/download links, Library games, Storage
games, top-bar/controller page changes, Settings, setup (including pre-Play),
sign-in, licences, and retry/cloud paths that reopen a title. Reopening the
visible title keeps its existing origin and panels. Keyboard/picker, cloud,
launch-failure and JIT sheets cover their caller without changing the route;
the restart after a running game remains unchanged (decision 0029).

## Build and host checks

- `./pp test`: passed, including 12 new `AppRoutesTests`; PlayportKit: 122 tests,
  no failures. Tests cover all three game origins, Storage over every root page,
  nested panels/settings/setup/sign-in/licences, section links, focus restoration,
  duplicate opens, page history, and native game-path dismissal.
- `./pp check` and `./pp check --variant release`: both compiled.
- `./pp install`: dev IPA verified (71 checks) and upgraded in place.
- IPA SHA256: `e6789f26f2f4b20ef3a8b4755324fdd98c92a78b38acc57b505a3c86e49d888a`.

## Phone runs

All runs used the installed IPA above, the UI driver's controller presses, and
`--shot-each-action`. Screenshots remain in their gitignored run directories.

| Run under `.work/ui-runs/` | Observed returns |
| --- | --- |
| `routing-home-storage` | Home hero → game → Home; Home X → options → game → Home. Home hero focus restored. The first Storage attempt selected its informational free-space row; the next run exercised the game link. |
| `routing-storage-library` | Home → Settings › Storage → game → options → game → Storage, focus on the same game row → sections → Home. Library game → Library tile; Downloads → Library → Home; Home recent Hollow Knight → game → same Home tile. |
| `routing-setup-signin-licences` | Settings › Setup check → checklist → sign-in preview → checklist → the checklist row in Setup check → sections → Home. Licences list → About's licences row → sections → Home. |
| `routing-nested` | Home → Hollow Knight options → Settings › Storage → sign-in preview → Storage → the same game/options setting → game → Home. Setup's first-run preview returns to its preview row, not the checklist row. Setup → Steam account → original Setup row. Wine licence component → its row in the list → About's licences row → sections → Home. |

Each run ended `ok`; logs show the expected page, section, panel and focus after
Back. Screenshots confirm the Home and Storage returns and that the game footer
says Home or Settings as appropriate. No game was launched, no credentials were
changed, and no install/uninstall action was performed. Native swipe dismissal
was host-tested through the same close-game transition, not gestured on the phone.
