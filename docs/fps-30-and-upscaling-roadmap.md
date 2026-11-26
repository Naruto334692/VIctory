# 30 FPS performance and upscaling implementation plan

## Target and measurement rules

The first target is a **sustained 30 rendered frames per second** in a repeatable world scene. This means a 33.33 ms frame budget; the acceptance gate should use p95 present-to-present time at or below 33.33 ms, not just a one-second average. Keep p99, average FPS, CPU preparation, GPU wait/submission, copy-back, texture upload, draw count, pipeline misses and dropped draws in the report.

Frame Generation is reported separately from rendered FPS. Generated frames do not make a 10 FPS base renderer responsive like a true 30 FPS renderer, and they do not repair CPU-side stalls, missing draws or broken resources.

## Confirmed architectural bottleneck

The file \`crates/victory-gpu/src/host.rs\` currently waits for a fence after every \`ExecuteCommandLists\` call (\`WaitForSingleObject(..., INFINITE)\`). The source comment at the top of the file explicitly says that every submission is waited for and that CPU/GPU overlap is deferred until per-submission fences are implemented.

This serializes CPU preparation and GPU execution. It is the highest-priority architectural candidate, but it cannot be removed by simply deleting the wait: title-memory snapshots, shader write-back, deferred resource ownership, command-list reuse and bottom-of-pipe signals currently rely on completion before returning.

### Safe implementation sequence

1. **Measure per submission first.** Preserve separate CPU preparation, GPU fence wait, copy-back and present interval metrics. Add per-list timings and identify the slowest command groups in a reproducible capture.
2. **Introduce a fence-retirement queue.** Each submitted batch must own every command list, upload allocation, descriptor/resource owner and read/write-back record until its fence completes. Retire only completed batches.
3. **Use a bounded frames-in-flight ring.** Start conservatively (two submissions); apply back-pressure when the ring is full. Do not let title-visible fence values signal completion before copy-back is complete.
4. **Preserve ordering for shared title memory.** If a later submission reads memory written by an earlier submission, the snapshot and copy-back dependencies must remain ordered. Keep a synchronous fallback for paths that cannot yet be tracked.
5. **Validate device loss.** On removed/reset/hung devices, stop submitting to the old device and report DRED. Do not retry an ExecuteCommandLists call against a failed device.
6. **Benchmark before and after.** Use identical scene, resolution, settings, driver and warm-up. Report average, p95/p99, CPU, GPU and copy-back separately. Do not use WARP for performance conclusions.

## Additional optimization candidates

| Area | Evidence to collect | Safe next action |
|---|---|---|
| CPU preparation | preparing, title-memory copies, texture refresh/hash time | Avoid redundant copies only when content/version tracking proves the source is unchanged |
| GPU execution | Fence wait per list, slow command groups, GPU timestamps | Optimize the actual longest commands; don't guess from total FPS |
| Copy-back | copying back milliseconds/MB and marked ranges | Keep dirty-range and per-submission deduplication; reduce bytes only with correct shader write tracking |
| Pipeline creation | cache hits/misses, making, dropped pipelines | Warm the shader cache before the scene; never draw with a missing pipeline as if successful |
| Texture pressure | texture MB, alias copies, depth-twin copies | Reuse resources only when format, dimensions, flags, lifetime and state match |
| Presentation | source texture dimensions, copy/present interval | Avoid redundant resize/copy work only after proving the source and back-buffer semantics |
| Render scale | actual game-owned render-target dimensions | Add dynamic resolution only after a real render-frame hook can safely control the game's render targets |

## Upscaler status and version naming (checked 2026-11-25)

### AMD

- **FSR 3**: temporal upscaling and frame generation are separate features. The current VIctory FidelityFX bridge supports the title's upscaler API only; it explicitly refuses other FidelityFX effects, including frame generation.
- **FSR 4 / FSR Upscaling 4.1**: AMD currently labels its ML temporal upscaler “FSR Upscaling 4.1” (formerly FSR 4). AMD documents compatibility for ML upscaling on Radeon RX 6000, RX 7000 and RX 9000 series; feature enablement still depends on title integration/compatible FSR 3.1+ path and driver support.
- **FSR Redstone**: AMD's suite name for ML upscaling, frame generation, ray regeneration and radiance caching. These are separate features with different inputs and hardware support.
- **FSR 5**: no public AMD FSR 5 SDK/API is identified in the official documentation checked for this stage. Do not invent a version, DLL name or feature flag. Re-check official AMD release notes before implementation.

Current bridge configuration remains:
\`\`\`powershell
$env:VICTORY_FIDELITYFX_DIR = 'D:\\victory-data\\fidelityfx'
\`\`\`
The folder must contain the compatible PC SDK DLL \`amd_fidelityfx_upscaler_dx12.dll\`. The bridge queries supported provider versions for the host GPU; it does not yet expose a VIctory-controlled Quality/Balanced/Performance menu or force the title's render scale.

### NVIDIA

- **DLSS 2**: Super Resolution requires temporal inputs (at minimum color, depth, motion vectors, jitter and correct dimensions/state).
- **DLSS 3**: adds Frame Generation; it is not a generic switch and needs valid motion data, presentation integration and supported hardware.
- **DLSS 4 / 4.5**: includes Super Resolution model updates and Multi Frame Generation / Dynamic Multi Frame Generation on supported RTX 50-series hardware.
- **DLSS 5**: NVIDIA describes 3D-Guided Neural Rendering, a separate neural-rendering stage using frame color and motion vectors, with current availability limited to supported titles and GeForce RTX 50-series GPUs.
- **VIctory status**: no DLSS version is integrated or active yet. Streamline/NGX is not loaded, and the runtime does not expose a reliable generic frame hook with all required inputs. A DLL load or “DLSS” setting alone is not an implementation.

The NVIDIA Streamline integration must verify signed interposer components, query per-feature hardware/runtime support, pass valid tagged resources/constants, and disable frame generation during menus, loading, pause and resize. Keep each feature's capability status independent.

## Backend-neutral settings (only after the frame hook exists)

- Upscaler: Auto / Native / AMD FSR / NVIDIA DLSS.
- Quality: Native AA / Quality / Balanced / Performance / Ultra Performance, filtered by the provider's actual capabilities.
- Output: 1920x1080 / 2560x1440 / 3840x2160.
- Dynamic resolution target: 30 FPS first; later 60 FPS if the hardware and scene can sustain it.
- Show provider, SDK version, adapter, active render/output dimensions, frame-generation state and fallback reason.

Do not enable FSR and DLSS simultaneously on one frame. Auto must select only a provider that initialized successfully and can dispatch with valid resources. If it cannot, use the title's native path and report why.

## Acceptance matrix

- CI: formatting/lints and workspace tests.
- Synthetic D3D12 tests: fence ordering, resource retirement, command-list lifetime, copy-back ordering, descriptor lifetime, resize and device removal.
- Hardware: AMD RX 6000+ for FSR Upscaling 4.1 path; NVIDIA RTX 40/50 as applicable for DLSS feature-specific tests; a non-RTX fallback path.
- Scenes: title menu, static world, heavy dynamic scene, memory pressure, scene transition, pause/menu, resize, driver/device removal.
- Performance pass: p95 present interval <= 33.33 ms for a sustained repeatable gameplay scene, with no missing rendering, unbounded memory growth, device errors or severe input-latency regression.

No physical AMD/NVIDIA hardware benchmark is claimed by CI. The title's world rendering remains incomplete, so the 30 FPS target is not yet achieved or guaranteed.
