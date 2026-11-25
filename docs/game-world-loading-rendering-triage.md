# Game-world loading and rendering triage

Status: investigation plan based on the current VIctory source tree. This is not a claim that the game is playable or that any rendering defect has been fixed.

## Confirmed runtime status

- The title starts and reaches its menu; observed menu rate is about 30 FPS.
- The world loads slowly and currently has visible rendering defects.
- No repeatable playable-world benchmark has been established. Menu FPS is not a world-performance result.
- The latest branch commit at this checkpoint passed GitHub CI, but CI does not validate GTA VI world rendering on a physical GPU.

## Architecture path to inspect

1. User-owned game files are read by the title-specific/game-data path.
2. `victory-pipeline` provides deterministic content-addressed conversion. Its cache key includes converter id, converter version, and input bytes; writes are staged and renamed atomically.
3. `victory-gpu::shader_cache` caches translated shader results. Its build fingerprint includes shader translator source hash, cache-entry encoding, and loop limit; cache hits/misses are counted.
4. `victory-loader` prepares and maps the native x86-64 title image and resolves imports.
5. `victory-hle` implements imported console APIs and routes graphics calls to `victory-gpu`.
6. `victory-gpu` translates command streams/resources and submits host D3D12 work.

The diagram is a useful high-level model, but the exact runtime call path for each asset class and title API must be traced before assigning a root cause.

## Triage order

### A. Establish a reproducible world-load trace

Capture one cold launch and one warm launch of the same game build and save location. Record monotonic timestamps and byte/count totals for:
- game container/file discovery and reads;
- conversion work, cache hit/miss, cache entry read/decode failures;
- shader translation and host pipeline creation;
- texture/buffer creation and upload bytes;
- command-list preparation, queue submission, fence-blocked time, copy-back;
- first world frame submitted and first successfully presented world frame.

Keep cold-cache and warm-cache results separate. Do not clear the user's cache automatically; use a separate test cache directory.

### B. Separate slow loading from bad rendering

For each visible defect, capture a reproducible scene, camera position, resolution, GPU/driver, and frame. Classify it as:
- missing geometry/draw;
- wrong shader or pipeline state;
- wrong texture, mip, format, plane, or subresource;
- descriptor/resource lifetime or stale GPU address;
- resource-state/barrier or queue-order issue;
- depth/stencil, blending, lighting, or shadow issue;
- presentation/scaling issue.

A slow first appearance with correct later frames suggests a different class of problem from a persistent incorrect image. Do not assume either without captures.

### C. Inspect cache correctness without treating cache as the presumed cause

- Verify that repeated identical inputs produce byte-identical converted outputs and a warm-cache hit.
- Verify that converter-version and shader-translator fingerprint changes invalidate old entries.
- Test truncated, malformed, and stale cache entries; a bad shader entry must be rejected and retranslated, never silently accepted.
- Test two concurrent processes writing the same key and interrupted staging files.
- Report cache hit/miss counts, bytes read/written, conversion duration, decode failures, and cache directory size.
- Preserve the existing user's cache; perform destructive cache experiments only against an isolated test directory.

### D. Rendering correctness before throughput

Prioritize validation of:
1. resource dimensions, formats, sample counts, mip counts, array slices and subresource footprints;
2. depth/stencil plane handling and texture upload/copy paths;
3. descriptor heap and resource ownership through fence completion;
4. root signatures, descriptor tables, root GPU virtual-address ranges and bindless access;
5. resource transitions, UAV barriers, queue/fence ordering and copy-back journals;
6. shader translation output and pipeline compatibility.

Use small synthetic D3D12 tests for each invariant, then validate with a physical GPU and a captured game scene. WARP is suitable for API/resource correctness tests, not performance conclusions.

## Performance gates

- First target a stable, correctly rendered world frame; do not optimize a broken image path by skipping work.
- Measure CPU preparation, fence-blocked time, copy-back, shader/pipeline misses, asset I/O and GPU timings separately where available.
- Keep p95/p99 present intervals distinct from GPU execution time.
- A 30 FPS world target requires repeatable p95 present-to-present intervals at or below 33.33 ms in the same playable scene and resolution on documented physical hardware.
- Frame generation must be reported separately from base rendered FPS and cannot substitute for correct rendering or low input latency.

## Safety and evidence

On device removed/reset/hung, stop submitting to the old device and capture DRED/HRESULT diagnostics. Do not retry old command lists on a removed device, disable TDR, or modify TDR registry settings. Do not claim a fix from a unit test alone when the defect requires an in-game physical-GPU reproduction.
