# 0171: On-screen controls, input mapping and gyro aim

**Status:** accepted, 2026-10-30, from the owner's decisions recorded in the
[plan](https://linear.app/playportdev/issue/PLA-13)'s Run state (2026-10-13; phases 1–3 signed off on
the phone) and phases 4–5 as built on the host
([PLA-13](https://linear.app/playportdev/issue/PLA-13)). The record the plan calls "0075".
Amends [0034](0034-a-gamepad-first-ui.md) (Home is no longer the only way into the in-game menu)
and [0074](0074-per-title-compatibility-defaults.md) (an entry may set `controls`). The driver's
actions are under [0012](0012-the-ui-is-the-only-entry-point.md).

## Context

A player with no controller could not play: a touch was the left mouse button at that point,
and the in-game menu opened only on a controller's Home. A game that reads only a keyboard and
mouse could not be played with a controller.

## Decision

- **Automatic display.** The on-screen controls show while no extended controller is
  connected (the dev build's scripted pad counts) and hide as soon as one connects
  (Settings › Controls: Automatic, the default; Always; Never makes Off every game's starting
  layout). The first time they show on their own, a toast says why and teaches the
  three-finger tap. The controls' pad is player 1 from the runtime's start whenever no
  controller is connected, at rest while the layout is Off, so a game that looks for pads only
  at its start has it when the controls are turned on in-game.
- **A three-finger tap opens the in-game menu** anywhere on the game, with any layout, Off
  and with a controller connected too; its fingers are taken back from the controls. There is
  no Playport button: Off draws nothing. iOS's three-finger editing gestures are off over the
  game and the top and bottom edges' system gestures are deferred while a game runs. Home on a
  controller still opens it (0034).
- **Actions are the single model.** What an on-screen control, a controller map's input and
  the layout editor's inspector do is a HostIOKit `InputAction` (`pad:`, `key:`, `mouse:`,
  `playport:menu|keyboard`), and HostIOKit `InputMixer` is the one place every source (the
  controls, the touch keyboard, physical pads through their map, gyro aim) becomes the guest's
  pad slots, keys and pointer. Held keys and buttons stay in `Lifecycle`, so the menu, the
  background and focus loss release them for every source.
- **Layouts.** Three presets, Gamepad, Keyboard & mouse and Point & click, plus Off; a
  game's own copy of a preset, saved by the layout editor over the paused game or from Game
  options, is drawn whenever that preset is its layout. A layout file carries `version`; any
  other is refused and the preset used.
- **The starting layout** is the game's own, else Off under Never, else the title's
  compatibility default (`controls` in `Titles/compat-defaults.json`, an `OnScreenLayout`
  name; an entry may now have it without `settings`), else Settings' Starting layout, else
  Gamepad: 0074's order, a title's default before Settings'. A game that starts on Gamepad
  with Settings' Starting layout left at Suggested and asks for no XInput state in 20 s of
  play after its first frame is offered Keyboard & mouse once (a toast; accepting saves it as
  the game's own). Win32u counts the reads for the app (`patches/madeira-unix` 0247).
- **Touches outside the shown controls are ignored:** no cursor, no click (a stray touch
  flicked a mouse-look game's view). With no controls shown (Off, a controller connected) a
  touch is the left mouse button as before; Point & click's surface is the whole safe area.
  The one exception is the open touch keyboard: a touch above its panel reaches the game, so
  a text field can be clicked while typing.
- **Gyro aim is always on when its output is not Off** (Mouse or Right stick, per game): no
  button has to be held, and no layout has an Aim button. A pause button is optional.
- **The driver** (dev builds only, 0012) feeds the same models a person's input does:
  `touch:` puts fingers on controls by id (and the touch keyboard's `kb-` keys) through the
  view's own calls; `gyro:` plays angular-velocity steps where the sensors' samples enter
  gyro aim; `--controls` (the app's internal `controls:`) saves a game's controls as its
  in-game Controls panel does; `gesture:three-finger-tap`, `suggest:accept|dismiss`,
  `menu:keyboard`, `menu:layout` and `open:ID#layout` press what a person would. A release
  build has none of them.

## Why

The owner settled these on the phone in phases 1–2 (the plan's Run state): with the tap,
Off draws nothing and the menu stays in reach by touch; a touch off the controls flicked a
mouse-look game's view; gyro aim in mouse mode played Portal 2 with nothing held. One action
model gives the controls, the controller map and the editor one way of naming a key, one
picker (ActionPicker) and one release path.

## Costs

- A game may show pad prompts while the layout is Off (the controls' pad stays connected).
- The three-finger tap is the only way into the menu without a controller; a person who has
  not seen the toast has to find it.
- A game that reads no XInput state in its first 20 s of play (it reads its pad later, or
  not through XInput) is offered Keyboard & mouse; once per game, and Not now keeps Gamepad.
- Phases 4–5 (Keyboard & mouse, Point & click, the touch keyboard, the suggestion, the
  editor) are tested on the host only; their phone gates and the owner's sign-off are
  [PLA-538](https://linear.app/playportdev/issue/PLA-538).
