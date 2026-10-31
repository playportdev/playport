# 0175: The anti-cheat refusal covers anti-cheat that cannot run or rejects Wine; others get a ban-risk notice

**Status:** proposed, 2026-10-30, by the owner while planning World of Warcraft
([PLA-508](https://linear.app/playportdev/issue/PLA-508)). Accepted after the host spike
([PLA-509](https://linear.app/playportdev/issue/PLA-509)) shows WoW's Warden accepting a Wine
session. When accepted, it narrows the launcher plan's refusal of "Battle.net titles" as
anti-cheat titles ([launchers plan](../plans/2026-10-12-launchers.md), risks), and keeps every
refusal of [0059](0059-epic-exchange-code.md).

## Decision

- **Refused, as today:** kernel anti-cheat, EasyAntiCheat and BattlEye, and any anti-cheat known to
  reject Wine.
- **Allowed:** user-mode anti-cheat its publisher tolerates under Wine. World of Warcraft's Warden
  is the first.
- **Ban-risk notice:** before the first Play of an allowed title, Playport says the publisher does
  not support Playport and an account action is possible. The person acknowledges it once per
  title; it stays visible on the title page.
- **Never patched:** Playport does not modify such a game's files or memory, and spoofs nothing
  beyond what Wine does.

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
