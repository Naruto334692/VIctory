# Upscaling: AMD FSR and NVIDIA DLSS

## Current implementation status

| Technology | Status | What works today |
|---|---|---|
| AMD FidelityFX FSR | Partial integration exists | The title's FidelityFX upscaler calls can be served by the user's PC FidelityFX DX12 DLL. The adapter checks whether that DLL offers an upscaler for the host GPU and otherwise leaves the title's own DLLs in place. |
| NVIDIA DLSS Super Resolution | Not implemented | No NGX/Streamline runtime, DLSS feature creation, or render-frame injection exists yet. |
| Frame Generation | Not implemented | The current FidelityFX adapter explicitly refuses non-upscaler effects. No DLSS Frame Generation or FSR Frame Generation support is claimed. |

This project executes a supplied title and translates its console graphics API to host D3D12. It is not a standalone renderer with an independent post-processing graph. Merely loading an upscaler DLL or exposing a menu item would not make upscaling work.

## Existing FSR path

The Windows runtime can use the PC FidelityFX SDK upscaler in place of the title's console FidelityFX build:

1. Obtain a compatible AMD FidelityFX SDK package from the official [GPUOpen FidelityFX SDK repository](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK).
2. Set `VICTORY_FIDELITYFX_DIR` to the SDK `Kits/FidelityFX/signedbin` directory containing `amd_fidelityfx_upscaler_dx12.dll`, or set `[paths].fidelityfx_dir` in `victory.toml`.
3. Start the title and inspect the log. The runtime queries the host GPU for available upscaler versions. If the DLL is missing, cannot load, or offers no provider for the GPU, the title's own DLLs remain in use.
4. The current bridge translates the title's console backend/resource/list handles to host D3D12 objects. It supports the upscaler API only; other FidelityFX effects are refused.

The title supplies the upscaler description and dispatch parameters. There is not yet a VIctory graphics menu for selecting FSR Quality/Balanced/Performance modes or forcing an arbitrary render scale. The existence of the FSR bridge is not proof that every GPU, driver, title scene or requested FSR mode works.

## DLSS integration requirements

DLSS Super Resolution must be implemented as a separate NVIDIA backend, not as a renamed FSR DLL. The implementation needs:

- NVIDIA NGX/Streamline integration and a supported, user-supplied/redistributable runtime arrangement that respects NVIDIA SDK licensing.
- NVIDIA adapter/vendor/device capability checks and explicit unsupported-device errors.
- A safe hook into the title's D3D12 frame execution that can identify the current color, depth, motion-vector and exposure inputs, plus output dimensions and jitter/reset data.
- Correct resource-state transitions, command-list lifetime retention, synchronization and device-removal handling.
- A backend-neutral upscaler contract so FSR and DLSS can be selected without accidentally activating both on the same frame.
- Deterministic fallback to the title's native path when the selected provider is unavailable; never report DLSS active when it did not dispatch.

The current repository does not yet expose a reliable generic render-frame hook with all required inputs. The world also has incomplete depth/stencil upload and lighting/rendering paths. Therefore a DLSS implementation cannot honestly be marked working until those prerequisites are solved and validated on a physical RTX GPU.

## Planned user-facing settings

When both backends are genuinely wired to the frame path, the settings should expose:

- Upscaler: Auto / Native / AMD FSR / NVIDIA DLSS.
- Mode: Quality / Balanced / Performance / Ultra Performance (only modes actually reported by the selected provider).
- Render scale and output resolution separately (1080p / 1440p / 2160p).
- Dynamic resolution target: 30 / 60 / 90 / 120 FPS, with a safe minimum/maximum render scale.
- Status line: selected provider, provider version, adapter, active input/output dimensions, and fallback reason.

Auto selection must prefer a provider only when it is supported and successfully initialized. It must not infer DLSS support solely from an NVIDIA vendor ID; compatible RTX hardware, driver/runtime support, feature creation and a valid dispatch are all required.

## Validation matrix

- Unit tests: provider selection, capability filtering, mode filtering, fallback reasons and mutual exclusion of FSR/DLSS.
- D3D12 validation: resource states, descriptor/resource lifetime, resize, command-list reset, device removal and repeated create/destroy.
- Hardware validation: AMD GPU with FSR, NVIDIA RTX GPU with DLSS, and a non-RTX fallback device.
- Performance: same repeatable scene at native 1080p/1440p/2160p and each supported upscaler mode; record average and p95/p99 present intervals, CPU preparation and GPU timings separately.
- A 60 FPS target is a measurement goal, not a guarantee. Do not compare WARP timings with physical GPU performance.
