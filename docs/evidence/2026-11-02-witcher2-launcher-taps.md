# The Witcher 2's launcher: a tap on Launch game reaches the launcher

**Linear:** [PLA-479](https://linear.app/playportdev/issue/PLA-479),
[PLA-478](https://linear.app/playportdev/issue/PLA-478) (The Witcher 2, 20920).

## The fault

`Launcher.exe` first shows its splash `0x100ae`, a 363x363 layered window at desktop (597,166).
It is `Launcher/Neutral/splash.png`, 363x363 RGBA with alpha from 0 to 255, drawn with
`UpdateLayeredWindow`. It then shows its menu window `0x1005e` (576x725 at (494,0), also layered).
The guest-window layers stack in show order, so the menu was drawn over the splash. Wine kept the
splash above the menu, and its hit test counts every layered window's whole rectangle. Every tap
above desktop y 529 (the splash's bottom edge) went to the splash. `Launch game` (y ≈ 469) and
`Options` were dead; `Mods` (y 527–535) worked ([2026-10-29-witcher2-launch.md](2026-10-29-witcher2-launch.md)).

On Windows the splash cannot take those clicks. A run with the new constant-alpha logging shows
how the launcher sets it up:

```
[guest-window] hwnd=0x1005e constant alpha 0
[guest-window] hwnd=0x100ae constant alpha 0
[guest-window] hwnd=0x1005e constant alpha 15
…
[guest-window] hwnd=0x1005e constant alpha 255
```

The launcher fades the splash out to a constant alpha of 0 and fades the menu in. After `Launch
game` it does the reverse while the game loads. Windows neither shows a window at alpha 0 nor
gives it clicks, and it passes clicks through a layered window's transparent pixels.

## Change

- `patches/madeira-unix/0288`: `driver_ios.c` gives Winios each surface's 1bpp shape, which win32u
  already computes for layered windows' transparent pixels, color keys and window regions. It also
  passes whether the picture's alpha belongs to the window, each layered window's constant alpha
  (`SetLayeredWindowAttributes`, `UpdateLayeredWindow`), and, to the server, the window Winios
  found under a touch.
- `patches/madeira-winios/0011`: `winios_window_pointer` (the host's touch on the guest windows)
  posts to the topmost shown layer whose window covers the pixel. A pixel outside the window's
  shape, or a window at constant alpha 0, does not count. With no such window, the server
  hit-tests as before. A layered window is drawn with its premultiplied alpha and its constant
  alpha.
- `HostIO.windowTouch` calls `winios_window_pointer`.

## On the phone

Dev IPA `87b03c2f03a9e1219b5254bc6822cdf85b87335ebaa6819df031055f07d0b853` (branch
`dev/pla-479-guest-window-taps`, on `dev/pla-798-w2-phone`), iPhone18,4, iOS 27.2. Run
`$PLAYPORT_BUILD/ui-runs/20261102T1419-w2-launch-tap`
(`pp ui --action play:app-20920 --action wait:20 --action tap:0.5218:0.6514`, the drawn
`Launch game`):

```
[guest-window] press at (816,469) to hwnd=0x1005e
[guest-window] release at (816,469) to hwnd=0x1005e
[14:20:40.632] [wine_host] phase spawn:L"C:\\Games\\the witcher 2\\bin\\witcher2.exe"
```

The tap went to the menu window, and `witcher2.exe` started at once. The menu faded out, and the
splash faded in over the screen while the game loaded, as on Windows. The game passed its Steam check
(PLA-798) and reached its first frame at +53.46 s. Screenshot `action-02-wait_20.png`: the launcher's
art drawn with its transparent edges over black, the menu readable.

Hollow Knight passed the smoke check on the same IPA: first frame at +9.87 s
(`$PLAYPORT_BUILD/ui-runs/20261102T142137`).
