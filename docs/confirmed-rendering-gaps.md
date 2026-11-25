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

### Current diagnostics

With the `victory-gpu/diagnostics` feature enabled, the per-frame copy-statistics line includes:
- `detile failures`: subresources whose detile operation failed and whose staging upload was withheld;
- `texture skips: no layout`: texture staging rejected because no console texture layout was available;
- `XOR swizzle`: texture staging rejected because the layout uses an unsupported XOR mode;
- `uncommitted memory`: a sampled texture's title-memory range was not committed/readable;
- `missing data planes`: additional console texture data planes (for example stencil) represented by the format layout but not uploaded by the current plane-0 path.

The texture path also logs at most 64 distinct descriptor signatures for rejected or incomplete uploads. Each warning includes the raw console resource description, host format and dimensions, mip/array/sample metadata, and the known console-plane offsets, stencil flags, formats and swizzle values. This limit is global for the process lifetime, not a per-frame log quota. The counter and warning identify an unsupported path; they do not prove that the affected texture caused a visible defect.

A unit test in `victory-formats` now verifies that console formats 118-120 expose distinct depth and stencil layout planes with valid offsets. This tests the layout metadata only; GPU plane-aware upload and physical rendering remain unimplemented. Capture the same scene and correlate descriptor warnings with frame captures.

### Required follow-up

1. Capture the same broken world scene and collect the bounded descriptor warnings and per-frame texture counters.
2. Correlate the reported console planes, formats and swizzles with host D3D12 descriptors and frame captures.
3. Implement plane-aware layout and upload only after matching console plane layout to host D3D12 subresource indices and footprints.
4. Add GPU-path tests for one-plane color, depth-only, depth/stencil, mip chains, arrays, 3D textures and unsupported combinations.
5. Implement XOR address calculation only with the required pipe/bank configuration; do not guess an XOR mapping.
6. Verify on a physical GPU with captures of the same scene before and after the change.

## 2. Detile failure propagation and retry

Implemented on the current PR branch:
- `Staging::detile` returns `bool`; a failed mip/slice conversion returns `false`.
- The caller withholds the staging upload when any subresource fails, so a partially populated staging allocation is not published as a complete texture.
- For write-watched title memory, failed refreshes re-queue the tracked range so a retry does not depend on a new title write.
- For ordinary committed memory, the content hash is advanced only after successful detiling, preserving retry behavior.
- A write-watch regression test verifies that a failed consumer can re-queue pages it already took.
- The per-frame diagnostics line counts detile failures.

This closes the earlier silent early-return/retry gap in the inspected code. It does not prove that every detile layout is supported or that the game-world defects are fixed.

## 3. Pipeline warm-up and load stalls

Sources: `crates/victory-gpu/src/pipeline/make.rs` and `crates/victory-gpu/src/pipeline/library.rs`.

- Pipeline creation/loading can be moved to workers.
- The pipeline worker path uses a per-frame wait budget; a draw may still wait for a pipeline if it is not ready.
- The library documentation records that a driver may compile a cache miss during pipeline-library load, taking seconds for some pipelines.
- Adapter/driver incompatibility or a damaged library is rejected and an empty library is created.

Required measurements: pipeline cache bytes and load duration, hit/miss/reject counts, queue depth, worker count, time spent waiting on a pipeline in the title thread, and first-use pipeline creation time. Separate cold-cache and warm-cache runs.

## 4. Priority order

1. Capture the same broken world scene and correlate texture rejection counters with the actual texture descriptors.
2. Add descriptor-level diagnostics and determine whether missing depth/stencil planes or unsupported XOR layouts affect visible assets.
3. Implement and test plane-aware depth/stencil uploads using verified console-to-host plane mappings.
4. Implement XOR swizzle only with correct hardware configuration and verified address vectors.
5. Measure cold/warm pipeline behavior and world-load stages; optimize only after correctness is established.

## 5. Acceptance criteria

- No silently skipped texture class in the tested scene: each is uploaded correctly or logged with a precise unsupported reason.
- A failed mip conversion cannot be copied to the host as a complete texture, and dirty tracking permits retry.
- Depth/stencil plane tests pass on synthetic resources and the affected in-game scene is visibly corrected on a physical GPU.
- Cold and warm world-load timings are measured independently.
- No FPS target is declared achieved until a repeatable playable world scene is benchmarked on named physical hardware.
