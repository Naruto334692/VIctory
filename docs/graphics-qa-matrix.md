# Graphics and runtime QA matrix

This matrix separates platform/runtime checks from title-level gameplay checks.
VIctory executes the supplied title; it is not a replacement game engine.
Physics, explosion logic, vehicle collision response, animation and most
lighting decisions belong to the title. A passing runtime test cannot prove
those systems work in the game.

## Evidence-based baseline

The current repository status is deliberately conservative:

- The title reaches the world and presents geometry, vehicles and characters,
  but the world is not playable yet and currently takes roughly 1–2 seconds
  per frame on the one reported test machine (Windows 11, AMD RX 6700 XT).
- The world is unlit. Some geometry is missing and some character shots are
  broken. Full lighting/shadow correctness is therefore **not verified**.
- HDR, real display queries, depth bounds and scaling are not implemented.
  Depth/stencil texture planes are not uploaded by the current texture upload
  path; only plane 0 is uploaded.
- DXGI currently advertises one 3840x2160 at 60 Hz mode. The
  `VICTORY_WINDOW_MAX` setting limits the outer window; it does not change
  the title's render resolution. The presenter can resize its swap chain when
  the source render texture changes size, but user-selectable render
  resolution/presets are not yet established.
- The menu runs at the title's 30 fps. The first world scene is much slower;
  no sustained gameplay performance claim is made.
- The runtime reports average FPS and average ms/frame, CPU preparation,
  GPU submission, copy-back, draw counts and dropped pipelines. It does not
  yet publish p95/p99 frame-time percentiles.

## Automated checks available now

Run on Windows with the pinned Rust toolchain:

```powershell
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --locked
```

For software-adapter diagnostics on D3D12/WARP:

```powershell
$env:VICTORY_D3D12_WARP = '1'
$env:VICTORY_D3D12_DEBUG = '1'
cargo test -p victory-gpu --lib --features diagnostics --locked -- --test-threads=1
```

WARP is useful for deterministic API and resource-lifetime checks, not for
estimating real-game FPS. Run the GPU tests serially: several tests intentionally
exercise process-wide D3D12 objects, tracked virtual memory and descriptor heaps.

Existing coverage relevant to this matrix includes:

- Frame pacing: `frame::tests::waits_end_on_ticks_and_count_frames` and
  `frame::tests::waits_begun_together_take_different_ticks`.
- Swap-chain recovery: `host::tests::swap_chain_failures_retry_once_per_second_and_success_clears_the_wait`.
- Descriptor bounds/lifetime: `descriptor::host::tests::empty_and_overlong_buffer_views_are_refused`,
  `dynamic_slots_are_held_until_released`, and
  `slot_resources_outlive_the_heap_until_the_list_resets`.
- Texture layouts and malformed input: `victory-formats` texture tests,
  including depth/stencil plane layout and overflow rejection.
- Pipeline state translation: `victory-game::pipelines` tests for blend,
  depth-write and rasterizer fields.
- Draw/list validation: `list::tests::resolve_queries_rejects_overflowing_offset`
  and tests for inline command fallbacks.

A CI pass validates the tested code paths only. It is not a physical AMD/NVIDIA
driver run and cannot certify a complete gameplay scene.

## Stress and gameplay matrix

| Scenario | Test procedure | Expected result / evidence | Current status |
|---|---|---|---|
| Static scene | Leave a stable menu/world camera view for 60 seconds; capture identical frames and inspect resource counters | No black frame, no unexpected resource growth, no device removal; stable frame output | Menu only partially established; world visual defects remain |
| Dynamic scene | Rotate camera, move characters/vehicles, stream into a new area and repeat | Updated buffers/textures arrive, descriptors stay valid, no stale-frame artifacts | Runtime paths exist; real-world result incomplete |
| Heavy explosion | Trigger one explosion, then repeated/overlapping explosions with smoke, particles, debris and nearby lights | No GPU fault, missing effects or corrupted descriptors; capture frame-time spikes and GPU timings | **Not verified**; requires a playable scene and real game files |
| Collision: static geometry | Walk/drive into walls, edges, barriers and terrain at low/high speed | No tunnelling, sticking, teleportation or invalid transforms | **Not verified**; title physics/gameplay is not yet validated |
| Collision: dynamic objects | Repeated vehicle/object impacts, simultaneous contacts and chain collisions | Stable contact response; no freezes, corrupted state or runaway physics | **Not verified** |
| Shadow stability | Static caster, moving caster, camera movement, near/far transitions and overlapping casters | No flicker, detached shadows, missing depth or stale shadow maps | **Blocked** by incomplete lighting/depth-plane path; world is currently unlit |
| Lighting | Day/night or time-of-day transitions, moving lights, emissive effects and exposure changes | No black/overbright frames, stable material response and expected light falloff | **Blocked**; not a current runtime capability claim |
| Resolution/output | Test 1280x720, 1920x1080, 2560x1440 and 3840x2160 source textures; resize the window repeatedly | Correct swap-chain dimensions, aspect ratio and no stale back buffer | Presenter resize path exists; title mode list is fixed at 4K/60 and presets are not verified |
| Refresh rate | Test 60/120/144 Hz displays and changes while running | Correct mode negotiation and pacing without drift | **Not verified**; only 4K/60 is advertised |
| Static vs dynamic resources | Keep one texture unchanged while rewriting another every frame; churn descriptors while previous command lists remain recorded | Static copy is skipped; dynamic updates become visible; resources live through list reset | Unit coverage exists for changed/unchanged ranges and descriptor lifetimes; scene validation pending |
| Frame acceleration/slowdown | Compare menu, loading and world; induce CPU pressure and GPU pressure separately | No timing drift; diagnostics identify CPU preparation vs GPU time | Frame clock tests exist; world is currently 1–2 s/frame, so acceptable gameplay speed is not met |
| Memory pressure | Run with constrained commit, grow textures/heaps, then release them and repeat | Controlled allocation failure or clear error; no use-after-free or silent corruption | OOM recovery is not comprehensively tested |
| Device removal | Use diagnostics and DRED; reproduce on WARP first, then physical hardware | Faulting command/address is recorded; process exits cleanly with actionable report | Diagnostics path exists; physical AMD/NVIDIA validation remains outstanding |
| Presentation outage | Make the desktop/window unavailable, then restore it | Swap-chain creation retries at most once per second and recovers after success | Retry unit test exists; interactive desktop recovery still needs live validation |

## Real-title diagnostics run

Build the diagnostics profile:

```powershell
cargo build --profile diag -p victory --features diagnostics
```

Use a dedicated capture directory and enable only the diagnostics needed for
the current run. Example:

```powershell
$env:VICTORY_D3D12_DEBUG = '1'
$env:VICTORY_D3D12_DRED = '1'
$env:VICTORY_CAPTURE = 'D:\qa\victory-frames'
$env:VICTORY_CAPTURE_WORLD = '0,1,2,10,30'
$env:VICTORY_DUMP_TARGETS = '1'
$env:VICTORY_GPU_TIMING = '1'
$env:VICTORY_TRACE_ROOT_VIEWS = '1'
```

Then run the locally installed title with the user's own game files. Keep
the console log, `crashes.log`, captured frames and render-target dumps
together. For a software-adapter comparison, repeat with
`VICTORY_D3D12_WARP=1`; WARP is extremely slow and should not be used for
performance conclusions. GPU-based validation (`VICTORY_D3D12_GBV=1`) is
useful for descriptor errors but is especially slow.

## Pass/fail rules

A scenario is a pass only when its required evidence exists:

1. No test crash, panic, device removal or D3D12 debug-layer error.
2. Captured frames show the expected image; a non-black frame alone is not
   enough to prove correct lighting, shadows or collision response.
3. Resource references return to baseline after command-list reset and
   repeated create/update/destroy cycles.
4. Performance reports separate CPU preparation from GPU execution and
   include a repeatable scene, resolution, adapter and driver.
5. Title-level effects and physics remain **unverified** until the same
   scenario is exercised in the actual game on physical hardware.

Do not turn an unsupported setting into a "pass" by substituting window
resizing for internal render-resolution selection, or WARP timing for
hardware performance.
