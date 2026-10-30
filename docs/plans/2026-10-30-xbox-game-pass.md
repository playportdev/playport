# Xbox: Game Pass and Microsoft Store PC games in Playport

**Linear:** [PLA-483](https://linear.app/playportdev/issue/PLA-483) (this plan),
[PLA-485](https://linear.app/playportdev/issue/PLA-485) (the spec: user stories, module
decisions, test seams). Related: [PLA-254](https://linear.app/playportdev/issue/PLA-254)
(publisher launchers; Game Pass titles Microsoft delivers through Battle.net or EA stay
there).

**Status:** decided by the owner on 2026-10-30 (a grilling session; each answer is on
PLA-483). Not started: no build, no phone run, no workstation run.
**Branch:** `dev/pla-483-plan-xbox-game-pass`, from `main` at `70384b2`, in the side
worktree `.work/worktrees/gamepass` (decision 0069).
**Decisions:** [0166](../decisions/0166-the-xbox-store.md) and
[0167](../decisions/0167-xbox-guest-tickets.md), both proposed with this plan.
**Words:** [GLOSSARY.md](../../GLOSSARY.md) (Xbox, copy, Product ID, licence, content key,
synthetic device, offline device, cloud save, unsynced save, save conflict).

## Goal

Xbox becomes a fourth store. A player signs in to a Microsoft account. The library shows
the Xbox copies the account can license: purchases and the PC Game Pass catalogue. A copy
installs with its updates and DLC, and Play starts the game with an Xbox runtime that signs
in to Xbox Live and syncs cloud saves.

**Done when:**
- Hollow Knight: Voidheart Edition (Product ID `9MW9469V91LM`) plays on the phone to first
  frame +10 through the UI.
- Two more titles reach gameplay.
- One save goes phone → Windows or Xbox → phone.
- One licence lapse and one save conflict are exercised.
- A security review of the whole path is done.

Release stays a separate owner decision after that (0166).

## Prior art

- **Xodus** ([xodus-gaming/xodus](https://github.com/xodus-gaming/xodus), GPL-3.0):
  - Microsoft account sign-in through Windows' inline login page.
  - A synthetic Windows device.
  - Xbox tokens.
  - MSIXVC download, streaming extraction and decryption.
  - Licences and content keys.
  - Its `docs/` describe the device, CLEP and licensing flows.
- **Xodus Nexus** ([domsvoboda/xodus-nexus](https://github.com/domsvoboda/xodus-nexus),
  MIT launcher, v0.4.1 of 2026-10-28):
  - A patched Xodus backend.
  - The C++ `nexus-xgameruntime` (LGPL-2.1).
  - `nexus-wine` (Valve's `proton_11.0` plus 486 commits).
  - About 50 titles reported playable on Linux and the Steam Deck, Hollow Knight: Voidheart
    Edition among them.
  - ARM64 with FEX is experimental there.

Playport reimplements the host side in Swift and carries the runtime and the Wine changes
as pinned upstreams with Playport patch series. No Xodus or Nexus code is linked into the
app.

## Decided

| # | Choice |
|---|---|
| Scope | GDK titles in MSIXVC and MSIXVC2 (MSIXVC2 from Xodus PR #219 at a recorded commit). Owned copies plus the PC Game Pass catalogue; no Store browsing or buying. Base game, updates and DLC. No UWP/EAppx; Battle.net/EA deliveries stay in PLA-254 |
| Identity | `Store.xbox`, "Xbox", `xbox-<ProductId>`; a Game Pass title is a copy whose licence can lapse; the Steam and Xbox Hollow Knight are two copies (0045, 0057, 0166) |
| Host code | Swift `XboxClientKit` on ContentKit, written from Xodus's and Nexus's code and docs |
| Device | One random synthetic Windows device per app installation, in the Keychain (this device only), no phone identifiers; survives sign-out; replaced only by dev "Reset Xbox device" or Microsoft's rejection (0166) |
| Sign-in | 0058's sheet (Microsoft's page, no persistent data); a passkey prompt steers to Microsoft's other ways |
| At rest | Encrypted. A play decrypts the kept-encrypted files **in place**, the originals set aside and restored at exit; a per-play marker finishes the clean-up at the next app start after a crash. Content key and offline lease cached in the Keychain |
| Offline | The phone as the account's offline device: off by default, a setting with a confirmation naming the one-device limit |
| Guest | Nexus's split: short-lived account tickets and licence tokens cross over a keyed per-play loopback bridge; the runtime signs in to Xbox Live itself (0167) |
| Runtime | Pin the C++ `nexus-xgameruntime` as `xgameruntime` with `patches/xgameruntime`; a new stage builds an ARM64EC Wine builtin only |
| Wine | Nexus's and Xodus's whole Wine patch set ported up front into a new series `patches/wine-gdk`; no memory-file loader patch and no AF_UNIX |
| nghttp2 | A new pin, built as an ARM64EC PE DLL, with notices and source entries |
| Saves | The runtime syncs cloud saves from the start; a save conflict asks the player; an unreachable cloud plays on local saves and syncs next time |
| Lapse | Only a definitive refusal counts; notice, Play disabled, removal after 7 days unless the licence returns; held while the copy has unsynced saves |
| Presence | Playing status, achievements and invitations stay on, as the runtime does them |
| Variant | Dev app only until proven (Goal) and reviewed (0166) |
| Tracking | Compatibility issues `Name (Xbox <ProductId>)`, plus `games.json` |

## Phases

Each phase ends with its checks passing and a commit (AGENTS.md); a phase's open work goes
to a linked issue, not prose.

### 0. Ground truth on the workstation

Run Xodus Nexus v0.4.1, unmodified, under sway (HOST-DEBUGGING.md), with the test account.
Install and play Hollow Knight: Voidheart Edition. The workstation takes one of the
account's 10 Microsoft Store devices and is **not** made the offline device.

Record in `docs/evidence/2026-…-xbox-ground-truth.md`, with no tokens or account
identifiers:
- the pilot's package format (MSIXVC or MSIXVC2);
- which files are kept encrypted;
- the bridge requests the runtime made;
- the Xbox Live hosts it contacted.

**Gate:** the pilot reaches gameplay under Nexus. If not, choose another pilot from Nexus's
playable list before phase 1.

### 1. Open facts (spikes, on the branch)

- **Passkeys in WKWebView.** Do passkeys work for `login.live.com` in a sideloaded app's
  WKWebView? Assumed not. Spike on the phone in the dev app's sign-in sheet; the answer
  shapes the steer-away text only.
- **A second Wine series.** Does the build take a second patch series on the Wine tree?
  Read `build/pipeline` and the series check, and extend it if not.
- **Licensing.** Do GPL-3.0 Xodus, written into GPL-3.0-or-later Swift, and LGPL-2.1
  `xgameruntime` sit with the converter exception? LICENSING.md's open DXMT question is the
  precedent. Write the answer into LICENSING.md before code lands.

### 2a. Runtime track (side worktree, 0117)

1. Pins and patches:
   - pin `xgameruntime` (nexus-xgameruntime at a recorded commit) and `nghttp2` (1.70.0, as
     Nexus);
   - new stage(s) building ARM64EC PE DLLs with llvm-mingw, `-D_WIN32_WINNT=0x0A00` as
     Nexus does;
   - staging into the runtime;
   - notices, source bundle, artifacts records.
2. `patches/wine-gdk`: port the set with `Class:`, `Evidence:` and `Offered-upstream:`
   trailers:
   - windows.web JSON (14 commits);
   - WinHTTP HTTP/2, response options, decompression, GDK options, private diagnostics;
   - the GDK patchset (text input, data transfer, `advapi32` credentials);
   - appstate registration;
   - the Mono path bounds fix;
   - any kernelbase package-identity change phase 0 shows.
3. Desktop proof: our Wine with our `xgameruntime` starts the pilot against **Nexus's own
   backend** over its TCP bridge (`XODUS_BRIDGE_PORT`/`KEY`).

**Gate:** the pilot reaches its menu with Xbox sign-in on the desktop; evidence written.

### 2b. Client track (side worktree, 0117)

`XboxClientKit` with Swift package tests, through seams 1 and 2 of the spec:
- recorded, redacted responses;
- real package fixtures;
- the bridge handler and one socket test.

It is built in this order:
1. Session and synthetic device.
2. Catalogue and library.
3. Licences and content keys.
4. MSIXVC, then MSIXVC2 parsing and decryption.
5. Stream-extract install and resume.
6. Updates and DLC.
7. Offline device.
8. The bridge service.

The `Redactor` and `pp secrets` learn every Microsoft, Xbox and licence token form first.

**Gate:** `pp test` green, `pp secrets` clean.

### 3. Integration and the phone pilot (main checkout)

1. Both tracks rebase into the main checkout.
2. The app work:
   - the `xbox` store in the library, game page and Downloads;
   - Settings › Accounts › Xbox and its offline setting;
   - dev "Reset Xbox device";
   - the in-place launch with crash clean-up;
   - the dev-only gate in `pp verify --variant release`;
   - new `pp ui` semantic paths.
3. `pp install`, then `pp ui` sign-in, install and Play of the pilot to first frame +10.
4. The Hollow Knight (Steam) smoke gate.

**Gate:** the pilot's first frame through the UI; evidence with the IPA's sha256; the
Compatibility issue filed.

### 4. Completeness and two more titles

- An update and a DLC installed.
- A cloud save round trip with Windows or Xbox.
- A save conflict chosen in the UI.
- A play with the cloud unreachable, synced at the next play.
- A licence lapse driven to its notice, the grace period and the hold on unsynced saves.
- The offline device setting and an offline play.
- Two more titles from Nexus's playable list, to gameplay; each gets its Compatibility
  issue.

### 5. Security review, then the owner

A security review of the sign-in, device, Keychain, bridge, decryption and logs. Findings
become issues, and 0167's guest-side storage is measured. Then the owner decides on release
in a new record.

## Risks

- **Microsoft's terms and the account.** Presenting a synthetic Windows device and
  decrypting store DRM may break Microsoft's terms; the test account could be restricted.
  This is why Xbox is dev-only (0166).
- **Moving targets.** Microsoft can change the inline login page, device registration or
  licensing at any time; Xodus and Nexus are weeks old and their patch stacks move daily.
  Pins and recorded commits bound what we depend on.
- **ARM64EC.** Nexus has not shipped an arm64 runtime; ARM64EC builds of `xgameruntime` and
  `nghttp2` are first done here.
- **Wine base.** Nexus's Wine sits on Valve's `proton_11.0`, ours on WineHQ with picked
  Valve commits; the whole-set port may need dependencies Nexus inherits from Proton.
- **Memory.** Large GDK titles meet the same limits as other big games: the memory plan
  (0105), the JIT pool and address-space reservations.
- **Decision numbers.** 0166 and 0167 were free on every local branch on 2026-10-30;
  renumber at merge if another branch takes them first.
