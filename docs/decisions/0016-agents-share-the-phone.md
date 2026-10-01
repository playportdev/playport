# 0016: Agents share the phone, each in its own worktree

**Status:** accepted, 2026-09-26. Supersedes two costs of
[0012](0012-the-ui-is-the-only-entry-point.md): "one build at a time, in one
checkout", and launch settings that "stay saved as a player's would until
cleared" when a driver saves them. Everything else in 0012 stands: the UI is
still the only entry point.

**Changed by [0028](0028-one-checkout.md)**: per-agent checkouts and build
areas are gone; work happens in one checkout. The phone's lock, sessions and
the rest of this record stand.

## Decision

Several agents may work at once, each in its own git worktree
(`pp worktree add BRANCH`, under the main checkout's `.work/worktrees/`) with
its own build area. They share the machine's inputs and caches, and the one
phone:

- one device lock, holder record and install record for every worktree, in
  the main checkout's `.work` (`$PLAYPORT_DEVICE_DIR`);
- one hold of the lock is a session; `pp phone lock -- CMD` makes a sequence
  (install, plays, a pad) one session that no other agent can split;
- the drivers (`pp ui`, `pp perf`) refuse to drive an IPA that another
  checkout installed, unless told to (`--any-build`, `--expect-ipa`);
- the shared netmuxd is restarted only under the lock, only when its unit
  serves this checkout's socket, and at most once per 5 minutes;
- what a driven run changes in the app's settings (`set:`, `hud:`,
  `--settings`) lasts for its session: the dev app records the values it
  replaced and puts them back at its first launch outside the session
  (`Dev/DriverUndo.swift`), unless the run asks to keep them
  (`--keep-settings`).

## Why

The lock already kept two commands from driving the phone at once, but not
two agents from using it at once. It lived in each checkout's build area, so
worktrees did not share it. It covered one command, so one agent's install
could land between another's install and its play, and that play then tested
the wrong build without a sign. Settings persist in the one app container, so
one agent's Metal HUD or environment variables rode along in the next
agent's runs.

Every driver restarted netmuxd whenever it listed no phone. One agent with a
wrong socket or an asleep phone then dropped every other agent's connection
in the middle of their sessions, and did it again on every retry.

The app keeps the undo because only the UI may change its settings (0012):
the workstation cannot write the container's preferences. The dev app can
put them back through the same stores the UI uses.

## What it costs

- A worktree's first build takes 10 to 15 minutes and about 12 GB: the run
  trees record their build directories and cannot be shared or moved.
- Worktrees share `.work/cache` through a link. Its entries are keyed by
  version, but two builds that fetch or build the same new entry at the same
  moment can collide.
- A driven setting now disappears after its session. A person who wants a
  setting to stay sets it on the phone, or a run passes `--keep-settings`.
- A person who changes a key on the phone during an agent's session, after
  the agent changed the same key, loses that change at the next session.
- A release install over the dev app keeps whatever the last session left:
  the release app has no undo.
- The install record is the workstation's word for what the phone has; the
  phone does not report which IPA it runs. Only `pp install` keeps the record
  right.
- Installed titles, the Wine prefix and the Steam session stay shared: an
  agent's `install:` or `uninstall:` is every agent's.
