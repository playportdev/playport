# 0074: Per-title compatibility defaults

**Status:** accepted, 2026-10-08, by the owner (through the supervisor of the PLA-108
session); [PLA-108](https://linear.app/playportdev/issue/PLA-108), and the mechanism
Proton-style per-game compatibility settings ([PLA-83](https://linear.app/playportdev/issue/PLA-83))
can use. Adds a level to [0073](0073-screen-aspect-ratio.md)'s launch settings.
Amended by [0091](0091-compat-default-keys-merge.md) (Runtime keys and Graphics options merge
with the person's own by key) and [0171](0171-on-screen-controls-input-mapping-and-gyro.md) (an
entry may set `controls`, the game's starting on-screen layout, with or without `settings`).

## Context

When a setting is known to make a game work (Super Meat Boy draws nothing on a screen wider
than 16:9 and renders at 1280x720, [evidence](../evidence/2026-10-08-super-meat-boy.md)),
every player had to find and set it on the game's page.

## Decision

- **One shipped table**, `app/PlayportKit/Titles/compat-defaults.json` (at the app root as
  `Titles/`, in the dev and release apps): by catalogue id (case-sensitive: `epic-Buffalo`),
  each entry a `settings` object in the `--settings` JSON form (any launch setting; it
  starts with the aspect ratio) and a short player-facing `reason`. PlayportKit `CompatDefaults`
  reads it and refuses an unknown key, a setting `LaunchSettings` would not read back as
  written, a screen a launch would not take, a missing reason and an issue id or tracker
  address (`PLA-…`, `linear.app`); PlayportKit's tests read the committed file.
- **Nothing project-internal ships in it.** Where an entry comes from (issue, runs, IPA)
  is in the decision and evidence records, not in the table.
- **Precedence** for each launch setting: the person's own choice on the game's page, then
  the title's compatibility default, then Settings, then Playport's built-in default. Y on a
  game page's row (reset) goes back to the compatibility default, not to Settings'.
- **On the game's page**, a row whose effective value is a compatibility default shows
  "ⓘ For this game · value", and a row at the top of Graphics, "ⓘ Set for this game's
  compatibility", gives the reason; it is a ring stop for a controller and on the page for
  touch.
- **First entry:** Super Meat Boy (Epic `Buffalo`), aspect ratio 16:9. The resolution is
  left to the person's or Settings' choice (Playport's 720p, 1280x720, unless changed): the
  game needs the shape, not a size.
