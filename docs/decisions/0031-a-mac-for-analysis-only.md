# 0031: A Mac may be used to analyse, never to build or install

**Status:** proposed, 2026-09-29. Not accepted. Until it is,
[0002](0002-linux-only-build.md) holds unchanged and no Mac is used.

## Decision (proposed)

A Mac borrowed for a session, Apple silicon with macOS 27 and Xcode 27, may
analyse what Playport does on the phone, with Apple's tools:
- Instruments;
- Xcode's Metal debugger;
- `gpucapture`, `gpudebug` and `metalperftrace`.

It records traces and replays captures of the installed app. It does not:
- build, sign, verify or install anything (0002 stands);
- launch the app (decision 0012: the app's Play button launches, driven or
  by hand);
- enter the pipeline or `pp`.

Nothing it produces is a build input. Its results come back as evidence notes
and as patches made on the workstation.

What to do there is in [GPU-DEBUGGING.md](../GPU-DEBUGGING.md#on-a-mac).

## Why

The workstation and the phone cannot give three things
([evidence](../evidence/2026-09-29-metal-tools-without-a-mac.md)):
- **The limiter of a pass:** the phone's GPU counter service rejected every
  configuration tried.
- **A CPU, GPU and compiler timeline for hitches.**
- **The results between draws, for finding the draw that renders wrong:**
  a capture holds only the resources as they were when the frame began, and
  nothing here replays it.

The D3D12 and DXVK path (0014, 0015) has no capture trigger of its own.
Apple's tools capture any Metal process that allows it, and Playport does
once Settings' GPU capture is on.

## Costs

- **Time on a Mac we do not own:** sessions must be planned (GPU-DEBUGGING.md's
  preparation list).
- **Risk to the app's data:** Xcode's Run, Install and Uninstall replace the
  app or delete its container. The rule is to attach and replay only.
- **Unconfirmed:** whether Apple's tools can attach to Playport after the JIT
  helper's debugger turn.
- **Evidence nobody can rerun here:** results from Apple's tools cannot be
  reproduced on the workstation. Their evidence notes say so, and a change
  they motivate is still checked by a Hollow Knight play.
