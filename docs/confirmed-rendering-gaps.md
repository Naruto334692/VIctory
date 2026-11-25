# Confirmed rendering-path gaps: texture upload and pipeline warm-up

Status: source audit on branch `integration/root-view-trace-with-bindless-uav`. These are confirmed implementation limitations, not a claim that each one has been reproduced as the cause of a particular GTA VI visual defect.

## 1. Texture upload coverage

Source: `crates/victory-gpu/src/texture.rs`.

The module-level contract explicitly says:
- plane 0 is uploaded for every mip and array slice;
- depth and stencil planes are not uploaded;
- XOR swizzle modes are not uploaded.

The `staging` path selects `t.planes[0].layout`. It then rejects a layout whose swizzle reports `xor()`, logging that texture contents in an XOR mode are not uploaded. The format/layout mapping in `crates/victory-gpu/src/resource.rs` maps console depth formats 118-120 to PC formats 45-47, but this mapping alone does not implement upload of every plane.

Potential visible consequences to investigate (not yet proven): missing/incorrect depth or stencil sampling, incomplete depth-dependent effects, and missing or incorrect textures for assets using XOR layouts.

### Required follow-up

1. Add counters by rejection reason: no console layout, unsupported swizzle, uncommitted title memory, detile failure, unsupported format, and missing plane.
2. Capture actual world texture descriptors and identify which formats/swizzles/plane counts are used by visible broken surfaces.
3. Implement plane-aware layout and upload only after matching console plane layout to host D3D12 subresource indices and footprints.
4. Add unit tests for one-plane color, depth-only, depth/stencil, mip chains, arrays, 3D textures and unsupported combinations.
5. Implement XOR address calculation only with the required pipe/bank configuration; do not guess an XOR mapping.
6. Verify on a physical GPU with captures of the same scene before and after the change.

## 2. Detile failure propagation

In `texture.rs`, `Staging::detile` logs a warning and returns when a mip/slice detile fails. Its current return type is `()`, so callers cannot distinguish complete conversion from an early exit. The upload recording path must be audited so that a partially filled staging allocation cannot be treated as a fully valid texture.

A safe fix needs an explicit conversion result and a retry policy. In particular, tracked dirty pages must not be irreversibly consumed if conversion fails; otherwise the next submission may see no new dirty pages and never retry the failed conversion. Add a regression test that fails a later mip after an earlier mip succeeds and proves no partial staging buffer is published as a complete texture.

## 3. Pipeline warm-up and load stalls

Sources: `crates/victory-gpu/src/pipeline/make.rs` and `crates/victory-gpu/src/pipeline/library.rs`.

- Pipeline creation/loading can be moved to workers.
- The pipeline worker path uses a per-frame wait budget; a draw may still wait for a pipeline if it is not ready.
- The library documentation records that a driver may compile a cache miss during pipeline-library load, taking seconds for some pipelines.
- Adapter/driver incompatibility or a damaged library is rejected and an empty library is created.

Required measurements: pipeline cache bytes and load duration, hit/miss/reject counts, queue depth, worker count, time spent waiting on a pipeline in the title thread, and first-use pipeline creation time. Separate cold-cache and warm-cache runs.

## 4. Priority order

1. Instrument rejection/failure counters and texture descriptor metadata without changing rendering behavior.
2. Reproduce the same broken world scene and correlate its missing/incorrect draws with texture/pipeline diagnostics.
3. Fix detile failure propagation so incomplete data cannot be published.
4. Implement and test plane-aware depth/stencil uploads.
5. Implement XOR swizzle only with correct hardware configuration and verified address vectors.
6. Optimize pipeline warm-up after correctness is established.

## 5. Acceptance criteria

- No silently skipped texture class in the tested scene: each is uploaded correctly or logged with a precise unsupported reason.
- A failed mip conversion cannot be copied to the host as a complete texture, and dirty tracking permits retry.
- Depth/stencil plane tests pass on synthetic resources and the affected in-game scene is visibly corrected on a physical GPU.
- Cold and warm world-load timings are measured independently.
- No FPS target is declared achieved until a repeatable playable world scene is benchmarked on named physical hardware.
