# CPU, RAM, GPU and driver stability QA

This plan tests the host runtime and its D3D12 failure boundaries. It does not
claim that an unplayable title scene, game physics, or vendor driver has passed
hardware validation. Run hardware stress only on a machine where an unexpected
reboot or application exit is acceptable; save work first.

## Current automated baseline

The Windows CI workflow currently runs one Windows runner configuration:

- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`
- `cargo test --workspace --locked`

The latest run associated with commit `d10e9800ba0a91c14447ec45f96d8faff3c891ca`
completed successfully (Clippy, diagnostics Clippy and workspace tests).
That is a code/CI result, not a RAM/VRAM stress run or a physical AMD/NVIDIA
driver certification.

## CPU core and thread matrix

Use the same build, title save/location, capture settings and GPU for each run.
Record physical cores, logical processors, CPU model, power plan and background
load. Run each case at least three times after one warm-up run.

| Case | CPU capacity to expose to the process | What to watch |
|---|---:|---|
| C2 | 2 logical processors | deadlocks, starvation, excessive serial work |
| C4 | 4 logical processors | lock contention and work-queue saturation |
| C6 | 6 logical processors | scheduling balance |
| C8 | 8 logical processors | throughput and frame-time variance |
| C12 | 12 logical processors | queue contention and oversubscription |
| C16 | 16 logical processors | allocator/descriptor contention |
| Cmax | all available logical processors | scaling plateau, thread explosion, memory growth |

Do not assume more worker threads are faster. Compare CPU preparation time,
GPU wait/submission time, total frame time and p95/p99 frame times. If CPU
preparation rises as cores are added, inspect contention and scheduling before
increasing thread counts. If GPU wait dominates, adding CPU threads is unlikely
to solve the bottleneck.

For automated Rust test parallelism, use separate CI invocations and preserve
the GPU-specific serial run. The GPU tests use process-wide D3D12 objects and
tracked virtual memory; do not run the D3D12 test suite concurrently with
itself merely to simulate more CPU cores.

## RAM / commit pressure

Run the following sequence with the title closed first, then repeat with the
title running:

1. Record installed RAM, available RAM, committed bytes and commit limit.
2. Run an idle 10-minute baseline.
3. Run a 15-minute steady scene and record private bytes, working set and
   commit growth once per minute.
4. Repeat create/update/destroy and scene-load cycles 20 times.
5. Close the title and wait 2 minutes; compare memory with the pre-run baseline.
6. Repeat with other applications using moderate memory, never intentionally
   exhausting the machine's commit limit.

Pass criteria: no monotonically growing private bytes after warm-up, no
unbounded descriptor/resource count, and allocation failure is reported rather
than followed by invalid resource use. A process working set may shrink or
grow due to the Windows memory manager; do not treat working set alone as a
leak. Compare private bytes, commit and resource counts together.

For a controlled test, cap the test workload by bytes and stop before system
commit reaches 80% of its limit. Do not use scripts that allocate until OOM:
that can destabilize Windows and corrupt unrelated work.

## GPU / VRAM pressure

Test on each physical adapter separately, with the same driver and scene:

1. Record adapter name, PCI vendor/device IDs, dedicated/shared memory and
   driver version/date.
2. Run idle, then a steady scene, then repeated texture/descriptor churn.
3. Increase render-target/texture sizes in bounded steps; stop at 80% of the
   reported dedicated-memory budget or at the first allocation failure.
4. Release resources and verify usage returns toward baseline.
5. Repeat with WARP only for API/resource correctness, never for performance.
6. Repeat with D3D12 debug layer; enable GPU-based validation only for a
   targeted reproduction because it is very slow and changes timing.

Pass criteria: failed allocations are handled cleanly; no stale descriptor
references, use-after-free, device removal, or steadily increasing memory
after resource release. A device removal must preserve its HRESULT, removal
reason, DRED breadcrumbs/page-fault data and the last submitted command-list
identity where available.

## AMD and NVIDIA driver fault matrix

Run the exact same workload separately on AMD and NVIDIA hardware; do not
compare different scenes or different graphics settings.

| Fault / signal | Evidence to collect | Runtime response expected |
|---|---|---|
| `DXGI_ERROR_DEVICE_REMOVED` | HRESULT, `GetDeviceRemovedReason()`, DRED | stop GPU submissions, write crash report, exit cleanly |
| `DXGI_ERROR_DEVICE_RESET` | same as above plus Windows System log | no reuse of invalid device/queue/resources |
| `DXGI_ERROR_DEVICE_HUNG` | DRED auto-breadcrumbs, page-fault VA, D3D12 debug messages | identify last command list; do not retry the same invalid work blindly |
| `DXGI_ERROR_DRIVER_INTERNAL_ERROR` | HRESULT, vendor driver version, WHEA/System events | preserve diagnostics; no automatic driver reset or registry hack |
| Device/resource creation failure | HRESULT, requested dimensions/format/heap flags, budget | return a controlled error; release partial allocations |
| Present/swap-chain failure | HRESULT, output mode, window dimensions and retry timestamps | bounded retry; avoid tight retry loops |
| GPU timeout / TDR | Event Viewer Display and vendor provider events, WER dump | report likely GPU hang; do not claim recovery unless a fresh device is proven |

A D3D12 device removed/reset/hung is not safely recoverable by continuing to
submit work to the old device. The conservative current policy is to capture
diagnostics and terminate the run. Full device recreation would require
rebuilding every device-owned object, descriptor heap, pipeline, resource,
queue and swap chain; it must be implemented as a separate explicit recovery
state machine and tested on hardware. Do not add a superficial retry around
`ExecuteCommandLists`.

## Diagnostics build and environment

Build:

```powershell
cargo build --profile diag -p victory --features diagnostics
```

For a targeted physical-GPU run:

```powershell
$env:VICTORY_D3D12_DEBUG = '1'
$env:VICTORY_D3D12_DRED = '1'
$env:VICTORY_GPU_TIMING = '1'
$env:VICTORY_TRACE_ROOT_VIEWS = '1'
$env:VICTORY_CAPTURE = 'D:\qa\victory-frames'
```

For WARP API correctness only:

```powershell
$env:VICTORY_D3D12_WARP = '1'
$env:VICTORY_D3D12_DEBUG = '1'
cargo test -p victory-gpu --lib --features diagnostics --locked -- --test-threads=1
```

Run `tools/collect-gpu-diagnostics.ps1` from an elevated PowerShell only if
you want Windows event logs included. It writes a local report; inspect it
before sharing because Windows event messages can contain machine paths or
other environment details.

## Driver troubleshooting: safe order

1. Save the crash report and Windows Event Viewer entries before changing
   anything. Record exact driver version, GPU model, game build and repro.
2. Remove GPU overclock/undervolt and CPU/RAM overclock temporarily; test
   vendor-default clocks and a stable memory profile.
3. Check GPU temperature, hotspot, power connectors, PSU capacity and Windows
   hardware error events. A WHEA error is not automatically a graphics-driver
   bug.
4. Install a current stable driver from the GPU vendor's official support page.
   If the fault began after an update, test one known-good previous WHQL/stable
   release. Change one variable at a time.
5. If normal installation does not resolve a reproducible driver corruption,
   use the vendor's documented clean-install procedure. Avoid third-party
   driver packs and unofficial modified drivers.
6. Re-test with debug layer off and on. If only debug/GBV triggers a failure,
   inspect validation messages; if only one vendor/driver build fails, preserve
   a minimal repro and report it to that vendor.

Do not recommend changing `TdrDelay`/`TdrDdiDelay`, disabling TDR, forcing
a driver reset, or suppressing device-removed errors as a fix. Those changes
can hide a real GPU hang or turn a recoverable timeout into a system freeze.
A driver update cannot fix invalid resource lifetime or bad command recording
in the runtime; those must be fixed in code.

## Repro report template

Record: OS build; CPU model / physical cores / logical processors; installed
RAM and commit limit; GPU model / vendor ID / dedicated VRAM; driver version
and date; title/runtime commit; resolution; workload; duration; average and
p95/p99 frame time; private bytes and GPU memory before/after; exact HRESULT;
device-removed reason; DRED breadcrumb and page-fault data; relevant Event
Viewer event IDs; whether WARP reproduces; whether the issue reproduces on a
second driver version.

## Known gaps

- No physical AMD + NVIDIA driver farm is currently attached to CI.
- The existing frame report has average FPS / average frame time, not p95/p99.
- WARP is not a substitute for hardware load, VRAM pressure or driver TDR.
- The world scene is not yet playable; explosions, collisions, full shadows and
  sustained gameplay remain unverified.
- No automatic device recreation is claimed. On device loss, a diagnostic
  crash report and clean termination are safer than reusing invalid objects.


## Official vendor and Microsoft references

- AMD Cleanup Utility and its recommended Safe Mode workflow:
  https://www.amd.com/en/resources/support-articles/faqs/GPU-601.html
- AMD stability troubleshooting, including clean installation, reverting to a previously stable driver, RAM checks and hardware connections:
  https://www.amd.com/en/resources/support-articles/faqs/TS-TIPS.html
- NVIDIA's manual clean driver installation procedure:
  https://nvidia.custhelp.com/app/answers/detail/a_id/10
- Microsoft DRED guidance for GPU page faults, auto-breadcrumbs and device-removal diagnostics:
  https://learn.microsoft.com/en-us/windows/win32/direct3d12/use-dred
- Microsoft TDR behavior and the requirement for applications to recreate the D3D device and its objects after a successful reset:
  https://learn.microsoft.com/en-us/windows-hardware/drivers/display/timeout-detection-and-recovery
- Microsoft DirectX dump files for postmortem GPU hang analysis:
  https://learn.microsoft.com/en-us/windows/pix/directx-dump-files/overview

Driver cleanup is a user-side troubleshooting operation, not a runtime workaround. Use the vendor utility only when evidence points to a corrupted/conflicting installation, and save a restore point or recovery path first.
