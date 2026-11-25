[CmdletBinding()]
param(
    [string]$BinaryPath,
    [string]$PackageZip
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# Parse both shipped PowerShell entry points before building anything.
foreach ($relativePath in @("scripts/Build-Windows-Package.ps1", "scripts/Run-VIctory.ps1")) {
    $scriptPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required script is missing: $scriptPath"
    }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join "; "
        throw "PowerShell syntax errors in $relativePath : $details"
    }
}
$launcherSource = Get-Content -LiteralPath (Join-Path $repoRoot "scripts\Run-VIctory.ps1") -Raw
if ($launcherSource -notmatch '\$runtime\s*=\s*Join-Path\s+\(Split-Path\s+-Parent\s+\$PSScriptRoot\)\s+"victory\.exe"') {
    throw "Launcher must resolve victory.exe from the package root, one directory above scripts."
}
Write-Host "PowerShell syntax and package-relative launcher path: ok"

# The runtime CLI can be smoke-tested without proprietary game files.
if ($BinaryPath) {
    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        throw "Runtime executable is missing: $BinaryPath"
    }
    $binary = (Resolve-Path -LiteralPath $BinaryPath).Path
    $cases = @(
        [pscustomobject]@{ Arguments = @("--help"); Label = "root help" }
        [pscustomobject]@{ Arguments = @("run", "--help"); Label = "run help" }
        [pscustomobject]@{ Arguments = @("translate", "--help"); Label = "translate help" }
        [pscustomobject]@{ Arguments = @("config", "--help"); Label = "config help" }
    )
    foreach ($case in $cases) {
        $cliArguments = $case.Arguments
        $output = (& $binary @cliArguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
            throw "CLI smoke test failed: $($case.Label) (exit $exitCode)"
        }
    }
    Write-Host "CLI smoke tests: ok"
}

# Inspect the ZIP directory without extracting or executing its contents.
if ($PackageZip) {
    if (-not (Test-Path -LiteralPath $PackageZip -PathType Leaf)) {
        throw "Package ZIP is missing: $PackageZip"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $PackageZip).Path)
    try {
        $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
        foreach ($required in @("victory.exe", "LICENSE", "README.md", "victory.example.toml", "RUN-THIS-FIRST.txt", "BUILD-INFO.txt", "scripts/Run-VIctory.ps1")) {
            if ($entries -notcontains $required) {
                throw "Required package entry is missing: $required"
            }
        }
        $executables = @($entries | Where-Object { $_ -match "\.exe$" })
        if ($executables.Count -ne 1 -or $executables[0] -ne "victory.exe") {
            throw "Package must contain only the VIctory runtime executable; found: $($executables -join ", ")"
        }
        $forbidden = @($entries | Where-Object { $_ -match "\.(dll|rpf|xvd|xvc|msixvc|dds|dxil|dxbc|xma|awc|bk2|bik)$" })
        if ($forbidden.Count -gt 0) {
            throw "Unexpected game or binary payload in runtime ZIP: $($forbidden -join ", ")"
        }
    } finally {
        $archive.Dispose()
    }

    # Extract only the generated runtime package into a temporary folder and
    # invoke the launcher with an intentionally missing GameDir. The expected
    # error proves the launcher found victory.exe in the package root first.
    $smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "victory-package-smoke-$PID"
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force
    }
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $PackageZip).Path, $smokeRoot)
        $launcher = Join-Path $smokeRoot "scripts\Run-VIctory.ps1"
        $missingGame = Join-Path $smokeRoot "missing-game"
        $launcherError = $null
        try {
            & $launcher -GameDir $missingGame -GameExe "missing.exe" | Out-Null
        } catch {
            $launcherError = $_.Exception.Message
        }
        if ($launcherError -notlike "*Game directory does not exist*") {
            throw "Launcher package-layout smoke test failed. Expected missing GameDir error, got: $launcherError"
        }
    } finally {
        if (Test-Path -LiteralPath $smokeRoot) {
            Remove-Item -LiteralPath $smokeRoot -Recurse -Force
        }
    }
    Write-Host "Launcher package-layout smoke test: ok"
    Write-Host "Package contents: ok"
}

Write-Host "Windows package checks passed."
