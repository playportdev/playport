# 0114: Our CEF and the Rockstar launcher's Open run fewer threads and processes

**Status:** accepted, 2026-10-17, chosen by the owner (trim Chromium's and the launcher's threads
and processes; FEX, the pool and rpmalloc unchanged). Follows
[0113](0113-a-4-mib-call-return-stack.md), which was not adopted. **Amends
[0111](0111-fewer-cef-processes-with-chromium-features.md)**: storage no longer stays out.
[PLA-384](https://linear.app/playportdev/issue/PLA-384),
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[plan](../plans/2026-10-16-cef-low-va-build.md),
[evidence](../evidence/2026-10-17-cef-trim.md).

## Context

The Rockstar Games Launcher's Open on the phone stops at one of two limits
([callret evidence](../evidence/2026-10-17-callret-stack.md)):

- **FEX's 16 GiB host band.** Run `20261017T191412` filled it at 205 threads. Each thread holds
  about 65 MB of it (its rpmalloc heap's spans and a 16 MiB call-return stack).
- **The 896 MiB JIT pool.** With smaller stacks (run `20261017T194000`), the pool ran out instead.
  Each process copies its builtins into the pool's head and asks for FEX code buffers in its tail.

Most of those threads and processes were Chromium's, in Social Club's CEF:

- The browser had 65 threads, 16 of them thread pool foreground workers.
- Each renderer had 20 or more.
- The storage service and a `chrome.mojom.ProcessorMetrics` utility ran as processes of their own.
  ProcessorMetrics exhausted the pool's head in both runs.
- Every process ran diagnostic threads: `HangWatcher`, `LoaderLockSampler` and, in the browser,
  `StackSamplingProfiler`.

The launcher itself added about 18 threads from its Direct3D device query: DXVK's compiler
threads (`dxvk-shader-*`), `dxvk-cs`, `dxvk-submit`, `dxvk-queue`, `dxvk-cache` and vkd3d-proton's
`vkd3d-disk`.

Social Club gives its children its own `--disable-features` (0111), so a switch passed to the
browser cannot turn these features off. A default compiled into our CEF can (0110, as
`patches/chromium` 0007 did for audio).

## Decision

**Our CEF** (`patches/chromium` 0008–0013). These are Windows compiled defaults, cited at their
pinned-tree lines:

| Patch | What changes | Source |
| --- | --- | --- |
| 0008 | The storage service runs in the browser process. Chrome's client gives no sandboxed storage directory, so the in-process path is taken. | `chrome/browser/chrome_content_browser_client.cc:7238`; `content/browser/storage_partition_impl.cc:239-276` |
| 0009 | The browser does not start the ProcessorMetrics utility after startup. | `chrome/browser/chrome_browser_main_win.cc:170-176`, `:695-702` |
| 0010 | Every process's thread pool has at most 4 foreground and 2 utility workers; the background pool already had 2. Before, the browser's floor was 16 and a renderer got the CPU count less one. | `base/task/thread_pool/thread_pool_impl.cc:56`, `:194-195`; `content/browser/startup_helper.cc:58-61`; `content/renderer/render_process_impl.cc:73-81` |
| 0011 | `EnableHangWatcher` is off. | `base/threading/hang_watcher.cc:242-249` |
| 0012 | The build has no loader lock sampling (`enable_loader_lock_sampling` is a gni value, not an argument). | `services/tracing/public/cpp/stack_sampling/loader_lock_sampling.gni:5`; `tracing_sampler_profiler.cc:609-615` |
| 0013 | The stack sampling profiler is off in a build without Chrome branding. Such a build counts as local, and local builds profiled every browser. | `chrome/common/profiler/thread_profiler_platform_configuration.cc:63-66`; `thread_profiler_configuration.cc:44-50` |

**The Rockstar launcher's Open** (`PublisherLauncher.rockstar.graphicsEnvironment`). Its Open
passes these over the Vulkan backend's environment:

- `dxvk.numCompilerThreads = 1`, joined to the backend's `DXVK_CONFIG` after `;`
  (`dxvk_options.cpp:8`, `dxvk_pipemanager.cpp:86-91`);
- `DXVK_SHADER_CACHE=0`, so DXVK starts no `dxvk-cache` writer (`dxvk_device.cpp:41`);
- `VKD3D_SHADER_CACHE_PATH=0`, so vkd3d-proton starts no `vkd3d-disk` thread
  (`device_workarounds.c:888-893`, `cache.c:3225`).

These ride the existing graphics-options path in the launch request; Launchers is a dev-only page.
A game's launch never takes them, and the owner does not type them.

**Not changed:**

- site isolation and the renderer process limit (0109);
- the `PerfettoTrace` thread: every process's tracing needs it
  (`services/tracing/public/cpp/perfetto/perfetto_traced_process.cc:226-238` CHECKs its task
  runner);
- Chromium's dedicated COM and blocking threads;
- DXVK's per-device `dxvk-cs`, `dxvk-submit` and `dxvk-queue` threads;
- FEX, the JIT pool's size and rpmalloc.

## Consequences

- **Desktop Proton, run `trim384-sway`.** The sign-in form shows from 30 s to 150 s, and Social
  Club reaches `FINISHED` at 2.5 s. Against PLA-381's run:
  - Chromium processes: 4, against 5. The storage and ProcessorMetrics utilities never start.
  - Browser threads: 57, against 68.
  - Renderer threads: 17, 18 and 21, against 30, 31 and 33.
  - CEF threads in total: 112, against 171.
  - CEF PSS: 1,729 MiB, against 2,028 MiB.

  The launcher's window controller went from `WaitForWindow` to `Active` 0.7 s later.
- **The browser does more.** It now runs the storage service as well.
- **Sampling is lost.** Fewer workers can slow a burst of background work, and the dropped
  diagnostics are hang reports and sampling, which nothing of ours reads.
- **Scope.** The DXVK and vkd3d-proton settings apply only to the launcher's own Direct3D device
  query. Games keep DXVK's own compiler thread count (decision 0024).
- **The phone, IPA `73dc65fc…`, Open `20261017T201653`.** Against `20261017T191412`:
  - The band peaked at 13,720 MB with 168 threads at most and refused nothing, against
    16,203 MB, 202 threads and one refusal.
  - The browser created 51 threads, against 65.
  - The launcher created 55, against 64. DXVK and vkd3d-proton ran one compiler thread and no
    cache threads.
  - The launcher reached `Active`, and Social Club's sign-in form was on screen from 60 s to the
    end. The page drew no text, a separate problem.
  - The JIT pool's head still ran out for children started later.

  The details are in the [evidence](../evidence/2026-10-17-cef-trim.md).
