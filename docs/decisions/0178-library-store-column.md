# 0178: The Library's stores are a column of marks at its left

**Status:** accepted, 2026-11-02, by the owner (design A of three, eight questions answered;
[PLA-728](https://linear.app/playportdev/issue/PLA-728)). Amends
[0045](0045-library-store-copies.md): its Installed filter becomes a toggle, and every store is
always shown.

## Decision

- **A column at the Library's left:** All, a rule, then every store (Steam, GOG, Epic Games,
  Battle.net) as its mark, no label. The chosen store's name and game count are the heading above
  the grid; nothing else names the stores. A store without a mark shows its letter.
- **Every store is always in the column.** One not connected (Steam, GOG or Epic signed out) is
  dimmed; its page asks for its account and opens Settings › Accounts. Battle.net needs no sign-in.
- **Installed only** replaces the Installed filter: a toggle that narrows All or any store,
  always shown at the heading's right after the sort, styled as it ("Installed only: Off"; a tap flips it) and in the ⧉ Filter & sort list,
  which is the controller's way to it (it is not in the ring).
- **Controller.** The column's buttons join the ring. ◀ from the grid's first column enters the
  column at the chosen store; ▲▼ there switch the grid as soon as the ring lands, as LB/RB switch
  pages; ▶, A or B go back to the first tile. LT/RT step along the column from anywhere in the
  Library, wrapping round: the triggers become menu buttons (`NavButton.lt`/`rt`, pressed past half
  travel, let go below 0.3).
- **The marks** are Simple Icons' path data (CC0-1.0), drawn from SVG path data in the app
  (PlayportKit `StoreMark`, `SVGPath`); each mark is its owner's trademark, used only to name its
  store.

## Why

Six chips no longer fit a phone's row: Battle.net sat past the screen's edge, so a player who never
scrolled the row never saw World of Warcraft ([PLA-727](https://linear.app/playportdev/issue/PLA-727)),
and Xbox ([PLA-485](https://linear.app/playportdev/issue/PLA-485)) adds a seventh. A column holds
seven at the phone's height and, unlike the chips, is reached by the controller's ring.

## Costs

- The column takes about 60 pt from the grid: tiles are narrower.
- Only the chosen store's count shows; another's is one press away.
- An eighth store would need the column to scroll.
- Switching on focus redraws the grid at every step through the column.
