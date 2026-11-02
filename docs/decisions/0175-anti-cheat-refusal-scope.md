# 0175: The anti-cheat refusal covers anti-cheat that cannot run or rejects Wine; others get a ban-risk notice

**Status:** proposed, 2026-10-30, by the owner while planning World of Warcraft
([PLA-508](https://linear.app/playportdev/issue/PLA-508)). Accepted after the host spike
([PLA-509](https://linear.app/playportdev/issue/PLA-509)) shows WoW's Warden accepting a Wine
session. When accepted, it narrows the launcher plan's refusal of "Battle.net titles" as
anti-cheat titles ([launchers plan](https://linear.app/playportdev/issue/PLA-616), risks), and keeps every
refusal of [0059](0059-epic-exchange-code.md).

**Amended again 2026-11-01 by [0177](0177-wow-plays-its-x64-client-through-fex.md):** the runtime changes none of the game's code or data in memory (WoW plays its x64 client through FEX), so the 0176 amendment below no longer describes what runs; the notice no longer says the runtime rewrites the game's instructions.

**Amended 2026-11-01 by [0176](0176-native-arm64-images-live-in-the-jit-pool.md):** "never
patched" holds for the game's files only. In memory, the runtime rewrites the game's image to run
it on iOS, and Warden may see that ([below](#amendment-2026-11-01-the-runtime-rewrites-the-image-in-memory)).

## Decision

- **Refused, as today:** kernel anti-cheat, EasyAntiCheat and BattlEye, and any anti-cheat known to
  reject Wine.
- **Allowed:** user-mode anti-cheat its publisher tolerates under Wine. World of Warcraft's Warden
  is the first.
- **Ban-risk notice:** before the first Play of an allowed title, Playport says the publisher does
  not support Playport and an account action is possible. The person acknowledges it once per
  title; it stays visible on the title page.
- **No file changed, nothing spoofed:** Playport does not modify such a game's files, and spoofs
  nothing beyond what Wine does. In memory, only the runtime's own translation of the image for
  iOS (amended 2026-11-01, below).

## Why

- Warden is code the server sends to the running game, in user mode. Blizzard does not ban Wine
  play for itself; its 2025 crackdown names software that modifies the client or bypasses its
  security.
- The earlier wording lumped every Battle.net title in with kernel anti-cheat, which Playport
  cannot run at all. The code only ever detected EasyAntiCheat and BattlEye, and only for Epic.

## Costs

- A title running under translation (FEX, the JIT pool's rewritten image copies) may look different
  to its anti-cheat than desktop Wine does. Playport cannot rule out a ban; the notice is the
  answer.
- Each allowed anti-cheat is judged per title, from evidence, not detected.

## Amendment 2026-11-01: the runtime rewrites the image in memory

**Accepted by the supervisor under the owner's delegation, 2026-11-01
([PLA-514](https://linear.app/playportdev/issue/PLA-514)), with
[0176](0176-native-arm64-images-live-in-the-jit-pool.md).**

- **The change.** The original bullet said Playport modifies neither the game's files nor its
  memory. A native ARM64 client cannot run on iOS unchanged: iOS clears x18, which Windows code
  reads as its TEB, and code runs only from the JIT pool. So, by 0176 and madeira-unix 0262–0264,
  the image the game runs is the pool copy: every instruction that reads x18 is patched to a
  trampoline (WoW Classic Era: 196,547 sites), the header's `ImageBase` is the copy's address,
  every relocation is applied, the game's own section views are remapped onto the copy, and code
  it decrypts is x18-patched at `FlushInstructionCache`.
- **What still holds.** No file in the install is changed. The memory changes are the runtime's
  generic translation for any native ARM64 child, not aimed at the game or its anti-cheat; nothing
  is spoofed beyond what Wine does.
- **The risk.** Warden, or the client's own integrity checks, can see the rewritten code and the
  moved image, and Blizzard may act on it. The ban-risk notice says so: "Playport changes none of
  the game's files; to run on iPhone it rewrites some of the game's instructions in memory, which
  Blizzard may detect."
