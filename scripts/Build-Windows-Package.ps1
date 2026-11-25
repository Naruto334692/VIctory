[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$Diagnostics
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Push-Location $repoRoot

function Invoke-Cargo {
    param([Parameter(Mandatory = $true)][string[]]$CargoArguments)
    & cargo @CargoArguments
    if ($LASTEXITCODE -ne 0) {
        throw "cargo $($CargoArguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

try {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw "Cargo was not found. Install Rust using rustup, then reopen PowerShell."
    }

    Invoke-Cargo -CargoArguments @("xtask", "policy")

    if (-not $SkipTests) {
        Invoke-Cargo -CargoArguments @("test", "--workspace", "--locked")
    }

    if ($Diagnostics) {
        Invoke-Cargo -CargoArguments @("build", "--profile", "diag", "-p", "victory", "--features", "diagnostics", "--locked")
        $profile = "diag"
        $packageName = "VIctory-Windows-x64-diagnostics"
    } else {
        Invoke-Cargo -CargoArguments @("build", "--release", "-p", "victory", "--locked")
        $profile = "release"
        $packageName = "VIctory-Windows-x64"
    }

    $binary = Join-Path $repoRoot "target\$profile\victory.exe"
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "Build finished without the expected executable: $binary"
    }

    $outDir = Join-Path $repoRoot "out"
    $stageDir = Join-Path $outDir $packageName
    $zipPath = Join-Path $outDir "$packageName.zip"

    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    Copy-Item -LiteralPath $binary -Destination (Join-Path $stageDir "victory.exe")
    Copy-Item -LiteralPath (Join-Path $repoRoot "README.md") -Destination $stageDir
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination $stageDir
    Copy-Item -LiteralPath (Join-Path $repoRoot "victory.example.toml") -Destination $stageDir
    Copy-Item -LiteralPath (Join-Path $repoRoot "docs\architecture.md") -Destination $stageDir
    Copy-Item -LiteralPath (Join-Path $repoRoot "docs\asset-policy.md") -Destination $stageDir
    New-Item -ItemType Directory -Force -Path (Join-Path $stageDir "scripts") | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\Run-VIctory.ps1") -Destination (Join-Path $stageDir "scripts")

    $commit = (& git rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $commit = "unknown (source archive without git metadata)" }
    $rust = (& rustc --version)
    if ($LASTEXITCODE -ne 0) { $rust = "unknown" }
    $buildInfo = @"
VIctory Windows x64 runtime package
Profile: $profile
Source commit: $commit
Compiler: $rust
Built: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")

This package contains the VIctory runtime only. It does not include game executables,
archives, shaders, save files, account credentials, or any proprietary title data.
"@
    Set-Content -LiteralPath (Join-Path $stageDir "BUILD-INFO.txt") -Value $buildInfo -Encoding UTF8

    if ($Diagnostics) {
        $firstRun = @"
DIAGNOSTIC PACKAGE

This package contains the diagnostics-enabled VIctory runtime. It still needs
your own legally obtained title files; no game data is included.

Open PowerShell in this extracted folder, then run:
    `$env:VICTORY_D3D12_DRED = '1'
    `$env:VICTORY_GPU_TIMING = '1'
    .\scripts\Run-VIctory.ps1 -GameDir 'D:\YourGameFiles' -GameExe 'YourTitle.exe'

Diagnostics and timing can reduce performance. Keep the console output and
crashes.log when reporting a reproducible problem.
"@
    } else {
        $firstRun = @"
1. Read RUN-THIS-FIRST.txt.
2. Open PowerShell in this extracted folder.
3. Run:
   .\scripts\Run-VIctory.ps1 -GameDir 'D:\YourGameFiles' -GameExe 'YourTitle.exe'
4. The first shader/pipeline warm-up can take many minutes.
"@
    }
    Set-Content -LiteralPath (Join-Path $stageDir "RUN-THIS-FIRST.txt") -Value $firstRun -Encoding UTF8

    Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "Package created:"
    Write-Host "  $zipPath"
    Write-Host "SHA256: $hash"
    Write-Host "Executable profile: $profile"
} finally {
    Pop-Location
}
