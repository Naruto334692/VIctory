# Windows x64 runtime package

This package builds **VIctory**, the compatibility runtime. It is not a standalone copy of a game and does not contain any game executable, game archives, console firmware, shaders, saves, credentials, or proprietary assets. The user supplies their own legally obtained title files.

## Build on Windows

Requirements:

- Windows 10/11 x64.
- Rustup; the repository pins Rust 1.98.1 in rust-toolchain.toml.
- Visual Studio 2022 Build Tools with **Desktop development with C++** (MSVC).
- Internet access for Cargo to download Rust dependencies on the first build.

From a PowerShell terminal in the repository:

```powershell
rustup toolchain install
cargo xtask policy
cargo test --workspace --locked
cargo build --release -p victory --locked
.\scripts\Build-Windows-Package.ps1 -SkipTests
```

The ZIP is written to out\VIctory-Windows-x64.zip. The package contains victory.exe, the GPL-3.0 license, project documentation, the example configuration and the PowerShell launcher.

For a diagnostic build, use:

```powershell
.\scripts\Build-Windows-Package.ps1 -Diagnostics
```

The diagnostic executable is built with the diagnostics feature and is intended for troubleshooting, not faster gameplay.

## Automated build

The .github/workflows/windows-package.yml workflow builds on a GitHub-hosted Windows runner when a commit is pushed to the windows/pc-runtime-package branch, and can also be started manually from the repository's Actions tab when workflow dispatch is enabled. It runs workspace tests, builds the release executable, creates the ZIP and uploads it as a workflow artifact. The artifact is temporary CI output, not a permanent release.

## Run with the user's files

Extract the ZIP, open PowerShell in the extracted folder, then run:

```powershell
.\scripts\Run-VIctory.ps1 -GameDir 'D:\YourGameFiles' -GameExe 'YourTitle.exe'
```

GameDir is the directory containing the user's own shaders.rpf and title files; GameExe is the title executable's filename relative to that directory or a full path. Where present, XboxBvhBuilder.dll and amd_fidelityfx_upscaler_xbox.dll are included in shader warm-up.

The first translate --cache --pipelines pass may take many minutes and create a large local cache. To skip prewarming for a diagnostic attempt, add -SkipWarmup (first-use compilation can then stall or omit draws):

```powershell
.\scripts\Run-VIctory.ps1 -GameDir 'D:\YourGameFiles' -GameExe 'YourTitle.exe' -SkipWarmup
```

The launch script stores derived files under %LOCALAPPDATA%\victory\cache and persistent local data under %LOCALAPPDATA%\victory\data. It does not modify the user's game installation.

An optional PC FidelityFX SDK folder can be supplied with -FidelityFxDir when it contains amd_fidelityfx_upscaler_dx12.dll.

## Hardware and known limitations

The project's current README status is authoritative. The project has booted and reached the world on a tested Windows/AMD system, but it is explicitly **not playable yet**. World rendering has missing/incorrect lighting and geometry and very low frame rates; GPU faults or driver resets remain possible. A build completing successfully does not prove the title will run successfully on a particular PC.

The runtime requires an AVX2-capable x64 CPU and Direct3D 12 GPU with Shader Model 6.6; mesh shaders are required for world rendering. Leave several GiB of Windows commit/page-file headroom. Do not use VICTORY_D3D12_WARP=1 for performance testing: WARP is a slow software adapter intended for controlled diagnostics.

For a real run, compare hardware and driver details with the repository's latest reports. Do not upload game archives, executables, shader packs, memory dumps containing title data, or account material to GitHub issues.

## Safety and licensing

The repository's asset policy intentionally rejects binaries and proprietary game data. Keep user files, caches, saves and dumps outside the source tree. VIctory is GPL-3.0-or-later; retain the license and source notices when redistributing the runtime package. This project is not affiliated with or endorsed by Rockstar Games or Take-Two Interactive.
