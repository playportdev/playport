# Boot regression sweep: 27 titles that reached a first frame on this phone (PLA-444)

**Linear:** [PLA-444](https://linear.app/playportdev/issue/PLA-444) (the sweep and its queue);
each title's own Compatibility issue carries its result comment.
**Question:** every title whose own record shows a first frame or menu reached on this test
phone — does it still boot on the current dev IPA?
**Result:** 26 of 27 booted. The bar was `--until first-frame+10` for every title, on the page's
saved settings, with no settings changed and no raw taps. The one that did not is The Witcher 3,
and the reason is the build the app installs, not the runtime: PLA-450.

IPA: `.work/out/20261027-082216-0107f809/Playport-26.5-0107f809.ipa` (dev), sha256
`0107f8096ec1f1234e1cfa8812850c1faa198b34ffad2828b30b4f070ac3a38a`, install record `ce36a49`
(the checkout moved to `34dfddc` during the sweep, which the build records and `argv.txt` show;
the IPA under test never changed). Phone: iPhone18,4, iOS 27.0.1, `dev.playport.app`, profile
until 2026-11-03T07:21:52+01:00. Every run is under `.work/ui-runs/regression-2026-10-27/`, and
each title's own report is in its `reports/` directory. Screenshots stay in those run
directories: a game's artwork is not ours to publish.

## What this proves and what it does not

It proves the title still reaches its first presented frame, with its JIT pool, FEX band, limits
and memory plan healthy, no iOS crash report, and no person needed at the phone. It does **not**
prove gameplay, input, audio, save/load, online play or frame rate: every run stopped 10 s after
the first frame, and the compatibility statuses in `site/compatibility/games.json` are therefore
unchanged by this sweep — a status moves only from a run that shows the menu and the game.

## Results

| # | Title | Store / id | First frame (launch clock / after the game's own start) | Notes |
| --- | --- | --- | --- | --- |
| 01 | Hollow Knight | Steam `app-367520` | +10.88 s / — | redo after a self-cancelled first attempt |
| 02 | Portal 2 | Steam `app-620` | +8.37 s / — | small guest dialog at +27.96 s, after the bar; `controls: hidden (dialog)` |
| 03 | Among Us | Steam `app-945360` | +7.52 s / — | fresh 1.15 GB install |
| 04 | Castle Crashers Demo | Steam `app-207100` | +7.05 s / — | encrypted app ticket refused, ownership ticket armed; DX June 2010 redist already run |
| 05 | #DRIVE Rally | Steam `app-2494780` | +15.13 s / +9.6 s | fresh 2.39 GB install |
| 06 | Cat Mail Co. Demo | Steam `app-4622530` | +7.08 s / — | ownership ticket only |
| 07 | Assassin's Creed: Director's Cut | Steam `app-15100` | +7.79 s / +2.42 s | fresh 7.23 GB install; i386 through the i386 Steam path |
| 08 | En Garde! | Steam `app-1654660` | +9.58 s / +3.76 s | ran DXVK/KosmicKrisp, not the DXMT the record names |
| 09 | Soccer Online: Ball 3D | Steam `app-485610` | +7.53 s / +2.0 s | 419 MB, content already cached |
| 10 | Tomb Raider | Steam `app-203160` | +5.98 s / — | `-nolauncher`, so the record's launcher timings no longer apply; terms page has no semantic path |
| 11 | Valheim | Steam `app-892970` | +10.45 s / +4.68 s | fresh 4.54 GB install |
| 12 | MultiVersus | Steam `app-1818750` | +16.40 s / +4.84 s | 18.0 GB install; page has no launch arguments, plain Vulkan (`-dx12` untested); first frame is an epilepsy notice |
| 13 | Counter-Strike | Steam `app-10` | +8.25 s / +0.40 s | boots without `-gl`; reused app-70 Half-Life's GoldSrc content; first frame carried by a guest window |
| 14 | Super Meat Boy | Epic `epic-Buffalo` | +6.27 s / +0.83 s | fresh 495 MB install, no sign-in sheet |
| 15 | Death's Door | Epic `epic-65d73e3b…` | +7.47 s / +2.00 s | Unity args appended by Playport; no Epic sign-in sheet |
| 16 | Snakebird Complete | Epic `epic-8337d1f9…` | +7.37 s / +2.22 s | backend Vulkan where the record says DXMT; **PLA-446 reproduction** |
| 17 | House of Golf 2 | Epic `epic-48cfbcf2…` | +13.77 s / +8.17 s | 21.9 GB install in 400 s; UE prerequisite had already run on 2026-10-11 |
| 18 | Spelunky | GOG `gog-1207659257` | +6.18 s / +0.76 s | payload **adopted** from the container, not re-downloaded |
| 19 | Shogun Showdown | GOG `gog-1104084973` | +12.33 s / +6.91 s | payload adopted; **PLA-446 reproduction** |
| 20 | Duck Paradox | GOG `gog-1816031813` | +7.82 s / +2.71 s | real 0.94 GB GOG download in 10 s |
| 21 | Monster Train | GOG `gog-1304291300` | +7.28 s / +2.10 s | real 1.16 GB GOG download in 18 s at 83.5 MB/s; `build == newest` |
| 22 | Moonscars | GOG `gog-2106173825` | +8.54 s / +3.24 s | real 697 MB download in 11 s |
| 23 | Tomb Raider: Anniversary | GOG `gog-1202885143` | **+153.52 s** / +148.1 s | the guest's own `Rendering Setup` GDI dialogs ran ~141 s and closed themselves; 256 `Wow64SystemServiceEx … i386 system call 1336 … failed ffff0011` plus 20 `[alert-storm]` bursts; **PLA-446 reproduction** |
| 24 | NWN: Enhanced Edition | GOG `gog-1097893768` | +9.53 s / +4.42 s | real 6.54 GB download in 88 s; no guest window |
| 25 | BioShock (GOG) | GOG `gog-2022341186` | +69.61 s / +64.50 s | real 5.92 GB download in 86 s; `thermal: serious at launch` |
| 26 | Kingdom Come: Deliverance | Steam `app-379430` | +26.21 s / +17.01 s | 64.2 GB install in 1057 s; two vcredist 2015 prereqs re-ran and exited 0 (an earlier build left `0x666`); backend Vulkan where the record says DXMT; `thermal: serious at launch` |
| 27 | The Witcher 3 | Steam `app-292030` | **none — does not boot** | the app installed the 4.x Remastered payload (`bin\x64_dx12\witcher3.exe`, build 25773555, 68.8 GB, no `bin\x64` at all), which ends ~1 s after game start with `exit=0xc000001d`, `E 148 Invalid instruction in entry block` and `DISABLEAVX expected` — PLA-43's known AVX problem for 4.x, reproduced twice. PLA-43's **Best known** is the classic 1.32 branch, which `install:292030` cannot ask for (GOG takes `@BUILD`, Steam's `install:` does not): **PLA-450**. JIT, prerequisites (four vcredist, all exit 0), memory and pool were healthy; `thermal: serious at launch` |

## What the sweep found on the way

Filed as issues rather than fixed inside a title's run:

- **PLA-446** — an unhandled Mach exception on guest PC `ntdll.dll+0x1b05c` makes Playport dump the
  JIT pool's RW alias (always `939524096` bytes) into `Documents/prefix/Documents/title-cfg/<Title>/fex-jit-dump.bin`.
  Reproduced on Counter-Strike, Snakebird Complete, Shogun Showdown and Tomb Raider: Anniversary —
  four unrelated titles, one guest PC, one size — and it fires even before a D3D device exists. It
  never aborts the launch and never produces an iOS crash report, but it leaves 0.875 GiB per
  occurrence in the container with no `pp` command to delete it.
- **PLA-447** — the CEF/Chromium launcher heuristic fires on GoldSrc's `hl.exe` because `libcef.dll`
  sits beside it, and appends Chromium flags to the launch.
- **PLA-445** — `pp ui`'s 180 s JIT window is counted from the app's launch, so an `install:` in the
  same batch eats it and a real download fails the run `jit-timeout`. Worked around for the whole
  sweep by splitting install and play into two `pp ui` runs inside one `pp phone lock` session.
- **PLA-448** — the launch screen shows no hero art for a GOG title whose page was never opened: the
  launch sheet resolves art once, synchronously, and only Steam has an asynchronous top-up.
- **PLA-449** — `pp ui`'s system-alert probe drives the phone's accessibility focus through every
  on-screen element every 25 s of app silence (visible as a selection ring stepping over the app),
  and has never fired in 1827 run results.
- **PLA-450** — no Steam branch can be installed through the UI, so a record whose Best known build
  is a non-default branch (The Witcher 3's classic 1.32) cannot be re-verified.
- Not filed as issues, but recorded per title: `thermal: serious at launch` on House of Golf 2, BioShock
  and Kingdom Come: Deliverance (candidates for `pp perf`); backend discrepancies against the records
  on En Garde!, Snakebird Complete and Kingdom Come (Vulkan/DXVK where the record says DXMT).

## Space

Free space was the sweep's binding constraint, and installs were paid for by uninstalling titles
that had already been judged, never the Playport app and never a shared dependency such as
`app-70` Half-Life (Counter-Strike's GoldSrc content):

| Pass | Uninstalled | Free |
| --- | --- | --- |
| `space-1` | House of Golf 2 (21.9 GB), MultiVersus (18 GB) | 11.5 → 51.4 GB |
| `space-2` | Tomb Raider, En Garde!, Assassin's Creed, Valheim, TR Anniversary, NWN:EE, BioShock | 37.5 → 84.5 GB |
| `space-3` | Kingdom Come: Deliverance (64.2 GB), judged minutes earlier | 19.8 → 84.0 GB |

After the sweep 18 titles are installed (including The Witcher 3's 68.8 GB container) and 14.6 GB
is free. Nothing in the queue depends on The Witcher 3's folder, so it is the first candidate if
the phone needs a slot.

## Command shape

One `pp phone lock -- sh -c '…'` session per title, with the install and the play as separate
`pp ui` runs inside it (PLA-445), `--until first-frame+10`, `--shot`, and the page's saved
settings. Example:

```sh
./pp phone lock -- sh -c '
  ./pp ui --out .work/ui-runs/regression-2026-10-27/NN-<slug>-install \
           --action install:<id> --wait 5400 --shot
  ./pp ui --out .work/ui-runs/regression-2026-10-27/NN-<slug> \
           --action play:<title-id> --until first-frame+10 --wait 3600 --shot'
```
