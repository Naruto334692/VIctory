# Confirmed rendering-path gaps: texture upload and pipeline warm-up

Status: source audit on branch `integration/root-view-trace-with-bindless-uav`. These are confirmed implementation limitations, not a claim that each one has been reproduced as the cause of a particular GTA VI visual defect.

## 1. Texture upload coverage

Source: `crates/victory-gpu/src/texture.rs`.

The module-level contract explicitly says:
- plane 0 is uploaded for every mip and array slice;
- depth and stencil planes are not uploaded;
- XOR swizzle modes are not uploaded.

The `staging` path selects `t.planes[0].layout`. It then rejects a layout whose swizzle reports `xor()`, logging that texture contents in an XOR mode are not uploaded. The format/layout mapping in `crates/victory-gpu/src/resource.rs` maps console depth formats 118-120 to PC formats 45-47, but this mapping alone does not implement upload of every plane.

A further format audit found an important conversion constraint: console formats 118-120 store depth in a 16-bit plane and stencil in a separate 8-bit plane. The host D3D12 footprint model uses a 32-bit `R32_TYPELESS` depth plane and an 8-bit `R8_TYPELESS` stencil plane. Therefore, a future plane-aware implementation must convert depth values into the host representation; directly copying the console depth bytes into the D3D12 depth footprint would be incorrect. A new unit test locks down the console/host element-width mismatch for all three formats.

Potential visible consequences to investigate (not yet proven): missing/incorrect depth or stencil sampling, incomplete depth-dependent effects, and missing or incorrect textures for assets using XOR layouts.

### Current diagnostics

With the `victory-gpu/diagnostics` feature enabled, the per-frame copy-statistics line includes:
- `detile failures`: subresources whose detile operation failed and whose staging upload was withheld;
- `texture skips: no layout`: texture staging rejected because no console texture layout was available;
- `XOR swizzle`: texture staging rejected because the layout uses an unsupported XOR mode;
- `uncommitted memory`: a sampled texture's title-memory range was not committed/readable;
- `missing data planes`: additional console texture data planes (for example stencil) represented by the format layout but not uploaded by the current plane-0 path.

The texture path also logs at most 64 distinct descriptor signatures for rejected or incomplete uploads. Each warning includes the raw console resource description, host format and dimensions, mip/array/sample metadata, and the known console-plane offsets, stencil flags, element byte sizes and swizzle values. This limit is global for the process lifetime, not a per-frame log quota. The counter and warning identify an unsupported path; they do not prove that the affected texture caused a visible defect.

A unit test in `victory-formats` now verifies that console formats 118-120 expose distinct depth and stencil layout planes with valid offsets. This tests the layout metadata only; GPU plane-aware upload and physical rendering remain unimplemented. Capture the same scene and correlate descriptor warnings with frame captures.

### Required follow-up

1. Capture the same broken world scene and collect the bounded descriptor warnings and per-frame texture counters.
2. Correlate the reported console planes, formats and swizzles with host D3D12 descriptors and frame captures.
3. Implement plane-aware layout and upload only after matching console plane layout to host D3D12 subresource indices and footprints.
4. Add GPU-path tests for one-plane color, depth-only, depth/stencil, mip chains, arrays, 3D textures and unsupported combinations.
5. Implement XOR address calculation only with the required pipe/bank configuration; do not guess an XOR mapping.
6. Verify on a physical GPU with captures of the same scene before and after the change.

## 2. D16S8 depth equality and material-mask writes

Status: a source-level gap with independent upstream hardware evidence; it has **not yet been reproduced on this fork or the user's PC**.

The current branch maps console formats 118-120 (16-bit depth plus a separate 8-bit stencil plane) to host D24S8 formats 45-47. Its depth twin converts the 16-bit UAV plane into the host's 24-bit depth representation and keeps stencil in a separate writable plane. This makes the stored values transferable, but it does not make the host's depth-test precision identical to the console's D16 precision.

An upstream GTA VI report on an RTX 3060 Ti described a specific material-lighting path:
- `GenerateMaterialMasks` and `CS_MaterialTilesInitial` write a format-118 material-depth target through an R16 view of plane 0 and an R8 view of plane 1.
- The following tiled-lighting draw binds that resource as a DSV with depth comparison `EQUAL`, depth writes disabled, and stencil testing disabled.
- A D24 host can distinguish depths that the console quantizes to the same 16-bit value. The report's synthetic GPU test found quarter-of-a-D16-step depth offsets that failed `EQUAL` on D24S8 but passed after keeping the host depth at D16.

Reference implementation and test report: [lines9686-rgb/VIctory, depth-uav branch](https://github.com/lines9686-rgb/VIctory/tree/depth-uav). This is supporting evidence for a candidate cause, not proof that this exact pass is the cause of the current user's rendering failure.

### Existing branch implementation versus the missing D16 mode

The current branch is not starting from zero:
- `twin.rs` already creates separate R16 and R8 unordered-access twin textures for console formats 118-120.
- The R16 depth plane is converted to/from the host D24 plane by a compute pass; the R8 stencil plane is copied separately.
- UAV writes are therefore routed, but the actual depth-stencil resource and DSV used by rasterization remain D24S8. The conversion does **not** make depth-`EQUAL` behave like D16.

A complete experimental host-D16 implementation has since been committed to the fork's `main` history as upstream commit [`0b9a0f6`](https://github.com/Naruto334692/VIctory/commit/0b9a0f6898ddf1b36983d047b3d9126013dfb39b). The two histories have diverged from merge base `ffe310eb2098e52169f4c44db5ffdabf43a72622`: the reference commit is 99 commits from that base, while the integration branch contains 394 commits from it. This is not a simple 99-commit lag or a safe fast-forward/cherry-pick. The integration branch does not contain this implementation. The reference adds:
- an opt-in `VICTORY_LOCAL_D16_DEPTH=1` mode mapping formats 118-120 to D16 / R16 views;
- a separate R8 stencil resource, including stencil SRV/UAV remapping, clears, copies and state tracking;
- DSV flag handling and pipeline depth-format tracking/diagnostics;
- a warning for pipelines that attempt stencil testing/writes, because detached R8 stencil cannot participate in the hardware DSV stencil test;
- a hardware GPU test comparing D16 and D24 depth-`EQUAL` at exact and fractional D16-step offsets, with shader-readable and non-readable depth resources.

This reference is a much stronger basis than inventing a new conversion path. It is not yet integrated into this PR branch, and its test results do not prove the user's current world-rendering failure is caused by this path. Porting must account for the branch's newer descriptor lifetime, bindless, root-view and copy-back changes rather than replacing whole files with older reference snapshots.

### New comparison: exact test result and porting incompatibility

The reference commit's synthetic GPU test is more specific than the earlier summary:
- It writes 64 depth values through the title-style R16 UAV view and stencil through plane 1.
- It draws depth-EQUAL probes at both the exact D16 value and a value offset by 0.25 of one D16 step.
- It runs with the depth target shader-readable and non-shader-readable, then probes depth and stencil readback.
- The D16 path expects all 64 exact and fractional probes to pass; the D24S8 comparison expects all 64 fractional probes to miss. The commit message reports the probe passing on the author's GPU and WARP with no D3D12 debug-layer messages. This is evidence from the reference commit, not a test run performed on this integration branch or the user's PC.

The integration branch's data model is materially different from the reference:
- Here, Resource.host points to a shared Arc<HostTexture> obtained through shared_texture; multiple title resources can share one host texture for the same texture memory.
- Here, HostTexture owns a OnceLock<Option<crate::twin::Twin>>; the current implementation's depth/stencil UAV planes and their conversion/copy routing live in twin.rs.
- The reference's D16 patch adds per-host-texture stencil, stencil_alone, and clears ownership/state, and its twin implementation is in depth_twin.rs, not this branch's twin.rs.
- The integration branch also has later bindless, descriptor lifetime, root-view and copy-back code in descriptor/host.rs, host.rs, list.rs, and draw.rs. The reference patch changes all of those areas.

Therefore, the reference's nine-file patch is a behavioral specification and test design, not a directly applicable patch. A safe port must first define ownership of the detached stencil companion for shared texture memory (including aliases with compatible/incompatible descriptions), then thread its lifetime and per-list state through this branch's existing twin routing and descriptor retention. Until that is designed, do not toggle pc_format to D16: doing so alone would mismatch DSV/SRV formats, clears, stencil views, and pipeline DSVFormat, and could silently lose stencil or break aliases.

### Safe integration requirements

1. Compare the reference D16 commit's nine changed GPU files against this branch and port only the D16-specific changes.
2. Keep the mode opt-in; D24 remains the default until same-scene validation succeeds.
3. Preserve the existing R16/R8 UAV twin behavior when D16 mode is off.
4. Ensure host resource format, depth SRV format, DSV format, clear values, pipeline `DSVFormat`, and descriptor remapping all agree.
5. Keep stencil state coherent across UAV writes, shader reads, clears, copies, list transitions and resource lifetime.
6. Refuse or clearly diagnose draws that require hardware stencil testing while stencil is detached.
7. Run workspace Clippy/tests, then the reference hardware test on both a physical D3D12 GPU and WARP where supported; require no debug-layer errors.
8. Only after those pass, compare the same GTA VI material-lighting scene in D24 and D16 modes and inspect frame captures.

### Acceptance tests

- Synthetic GPU test: write depth values through the title's R16 UAV view, then draw depth-`EQUAL` probes on both D24 and D16 host paths, including values within a fraction of one D16 quantization step.
- Synthetic GPU test: write stencil through the title's plane-1 R8 UAV, read it through every supported stencil SRV encoding, clear it through DSV clear, and copy it through the title's plane-1 subresource index.
- Cover two mips and multiple array slices, plus pipeline creation/binding with D16 DSVs; require zero D3D12 debug-layer errors.
- Only enable host D16 for GTA VI after the probe tests pass and a same-scene physical-GPU capture demonstrates that the material-lighting output changes as expected. Keep D24 as the default until then.

This issue is separate from the CPU-populated texture upload gap above: the D16S8 target in this report is GPU-written through UAVs, so fixing the plane-0 staging uploader alone will not restore those writes or the exact D16 depth comparisons.

## 3. Detile failure propagation and retry

Implemented on the current PR branch:
- `Staging::detile` returns `bool`; a failed mip/slice conversion returns `false`.
- The caller withholds the staging upload when any subresource fails, so a partially populated staging allocation is not published as a complete texture.
- For write-watched title memory, failed refreshes re-queue the tracked range so a retry does not depend on a new title write.
- For ordinary committed memory, the content hash is advanced only after successful detiling, preserving retry behavior.
- A write-watch regression test verifies that a failed consumer can re-queue pages it already took.
- The per-frame diagnostics line counts detile failures.

This closes the earlier silent early-return/retry gap in the inspected code. It does not prove that every detile layout is supported or that the game-world defects are fixed.

## 4. Pipeline warm-up and load stalls

Sources: `crates/victory-gpu/src/pipeline/make.rs` and `crates/victory-gpu/src/pipeline/library.rs`.

- Pipeline creation/loading can be moved to workers.
- The pipeline worker path uses a per-frame wait budget; a draw may still wait for a pipeline if it is not ready.
- The library documentation records that a driver may compile a cache miss during pipeline-library load, taking seconds for some pipelines.
- Adapter/driver incompatibility or a damaged library is rejected and an empty library is created.

Required measurements: pipeline cache bytes and load duration, hit/miss/reject counts, queue depth, worker count, time spent waiting on a pipeline in the title thread, and first-use pipeline creation time. Separate cold-cache and warm-cache runs.

## 5. Priority order

1. Capture the same broken world scene and correlate texture rejection counters with the actual texture descriptors.
2. Trace the format-118 material-depth target: its R16/R8 UAV writes, later DSV bindings, depth comparison function, and the lighting target written by those draws.
3. Prototype host-D16 with detached stencil only behind an explicit diagnostic switch; complete the depth/stencil view, clear, copy, barrier, and PSO-format paths before enabling it.
4. Implement and test plane-aware CPU texture uploads using verified console-to-host plane mappings; do not mistake this for the separate GPU-written UAV path.
5. Implement XOR swizzle only with correct pipe/bank configuration and verified address vectors.
6. Measure cold/warm pipeline behavior and world-load stages; optimize only after correctness is established.

## 6. Acceptance criteria

- No silently skipped texture class in the tested scene: each is uploaded correctly or logged with a precise unsupported reason.
- A failed mip conversion cannot be copied to the host as a complete texture, and dirty tracking permits retry.
- Depth/stencil plane tests pass on synthetic resources and the affected in-game scene is visibly corrected on a physical GPU.
- Cold and warm world-load timings are measured independently.
- No FPS target is declared achieved until a repeatable playable world scene is benchmarked on named physical hardware.
