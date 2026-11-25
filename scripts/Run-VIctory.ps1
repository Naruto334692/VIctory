[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDir,

    [Parameter(Mandatory = $true)]
    [string]$GameExe,

    [ValidateSet("series-x", "series-s")]
    [string]$Console = "series-x",

    [switch]$SkipWarmup,

    [string]$FidelityFxDir
)

$ErrorActionPreference = "Stop"

$runtime = Join-Path (Split-Path -Parent $PSScriptRoot) "victory.exe"
if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    throw "victory.exe is missing. Extract the complete VIctory-Windows-x64 package first."
}

if (-not (Test-Path -LiteralPath $GameDir -PathType Container)) {
    throw "Game directory does not exist: $GameDir"
}
$gameRoot = (Resolve-Path -LiteralPath $GameDir).Path

if ([System.IO.Path]::IsPathRooted($GameExe)) {
    $titleExe = $GameExe
} else {
    $titleExe = Join-Path $gameRoot $GameExe
}
if (-not (Test-Path -LiteralPath $titleExe -PathType Leaf)) {
    throw "The title executable was not found: $titleExe"
}
$titleExe = (Resolve-Path -LiteralPath $titleExe).Path

$shaderPack = Join-Path $gameRoot "shaders.rpf"
if (-not (Test-Path -LiteralPath $shaderPack -PathType Leaf)) {
    throw "shaders.rpf was not found in the supplied game directory: $gameRoot"
}

$env:VICTORY_GAME_DIR = $gameRoot
$cacheDir = Join-Path $env:LOCALAPPDATA "victory\cache"
$dataDir = Join-Path $env:LOCALAPPDATA "victory\data"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$env:VICTORY_CACHE_DIR = $cacheDir
$env:VICTORY_DATA_DIR = $dataDir
if (-not $env:VICTORY_LOG) {
    $env:VICTORY_LOG = "info"
}

if ($FidelityFxDir) {
    if (-not (Test-Path -LiteralPath $FidelityFxDir -PathType Container)) {
        throw "FidelityFX directory does not exist: $FidelityFxDir"
    }
    $fxRoot = (Resolve-Path -LiteralPath $FidelityFxDir).Path
    $fxDll = Join-Path $fxRoot "amd_fidelityfx_upscaler_dx12.dll"
    if (-not (Test-Path -LiteralPath $fxDll -PathType Leaf)) {
        throw "amd_fidelityfx_upscaler_dx12.dll was not found in: $fxRoot"
    }
    $env:VICTORY_FIDELITYFX_DIR = $fxRoot
}

# Include title-side modules in the shader warm-up when present. These files
# must come from the user's own game installation/dump, not this package.
$translationInputs = @($shaderPack, $titleExe)
foreach ($dllName in @("XboxBvhBuilder.dll", "amd_fidelityfx_upscaler_xbox.dll")) {
    $candidate = Join-Path $gameRoot $dllName
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $translationInputs += (Resolve-Path -LiteralPath $candidate).Path
    }
}

if (-not $SkipWarmup) {
    Write-Host "Warming the shader and pipeline cache. The first pass may take many minutes."
    $translateArgs = @("translate", "--cache", "--pipelines") + $translationInputs
    & $runtime @translateArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Shader/pipeline warm-up failed with exit code $LASTEXITCODE."
    }
} else {
    Write-Warning "Warm-up skipped. First-use shader translation may cause long pauses and missing frames."
}

Write-Host "Starting VIctory for: $titleExe"
Write-Host "Cache: $cacheDir"
Write-Host "Local data: $dataDir"

$runArgs = @("run", $titleExe, "--execute", "--console", $Console)
& $runtime @runArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Warning "VIctory exited with code $exitCode. Check the console and crashes.log in the data folder."
}
exit $exitCode
