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
Write-Host "PowerShell syntax: ok"

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
    Write-Host "Package contents: ok"
}

Write-Host "Windows package checks passed."
