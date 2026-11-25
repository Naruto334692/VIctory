[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PWD ("VIctory-GPU-Diagnostics-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [int]$EventDays = 7
)

$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$summaryPath = Join-Path $OutputDirectory "system-summary.txt"
$eventsPath = Join-Path $OutputDirectory "graphics-system-events.txt"
$dxdiagPath = Join-Path $OutputDirectory "dxdiag.txt"

function Write-Section {
    param([string]$Name, [object]$Value)
    Add-Content -Path $summaryPath -Value ([Environment]::NewLine + "===== " + $Name + " =====")
    ($Value | Out-String -Width 240) | Add-Content -Path $summaryPath
}

"VIctory host diagnostics - $(Get-Date -Format o)" | Set-Content -Path $summaryPath
Write-Section "Windows" (Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OSArchitecture,
        @{Name="TotalPhysicalMemoryGB";Expression={[math]::Round($_.TotalVisibleMemorySize / 1MB, 2)}},
        @{Name="FreePhysicalMemoryGB";Expression={[math]::Round($_.FreePhysicalMemory / 1MB, 2)}},
        @{Name="CommitLimitGB";Expression={[math]::Round($_.TotalVirtualMemorySize / 1MB, 2)}},
        @{Name="FreeCommitGB";Expression={[math]::Round($_.FreeVirtualMemory / 1MB, 2)}})

Write-Section "CPU" (Get-CimInstance Win32_Processor |
    Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors,
        MaxClockSpeed, CurrentClockSpeed)

Write-Section "GPU adapters" (Get-CimInstance Win32_VideoController |
    Select-Object Name, AdapterCompatibility, PNPDeviceID, DriverVersion,
        DriverDate, VideoModeDescription,
        @{Name="AdapterRAM_GB";Expression={if ($_.AdapterRAM) {[math]::Round($_.AdapterRAM / 1GB, 2)} else {$null}}})

try {
    $counter = Get-Counter -Counter '\Memory\Committed Bytes','\Memory\Commit Limit' -ErrorAction Stop
    Write-Section "Memory counters (instantaneous)" $counter.CounterSamples |
        Select-Object Path, CookedValue
} catch {
    Add-Content -Path $summaryPath -Value ("Memory performance counters unavailable: " + $_.Exception.Message)
}

$start = (Get-Date).AddDays(-[math]::Abs($EventDays))
$providers = @('Display','nvlddmkm','amdkmdag','WHEA-Logger','Microsoft-Windows-DxgKrnl','Microsoft-Windows-Kernel-PnP')
try {
    $systemEvents = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start; Level=1,2,3} -ErrorAction Stop |
        Where-Object { $providers -contains $_.ProviderName -or $_.ProviderName -match 'nvlddmkm|amdkmdag|DxgKrnl|WHEA' } |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
    $systemEvents | Format-List * | Out-String -Width 300 | Set-Content -Path $eventsPath
} catch {
    ("Could not read System event log: " + $_.Exception.Message) | Set-Content -Path $eventsPath
}

$dxdiag = Get-Command dxdiag.exe -ErrorAction SilentlyContinue
if ($dxdiag) {
    try {
        Start-Process -FilePath $dxdiag.Source -ArgumentList @('/whql:off','/t',('"' + $dxdiagPath + '"')) -Wait -NoNewWindow
    } catch {
        ("dxdiag failed: " + $_.Exception.Message) | Set-Content -Path $dxdiagPath
    }
} else {
    "dxdiag.exe not found." | Set-Content -Path $dxdiagPath
}

Write-Host "Diagnostics written to: $OutputDirectory"
Write-Host "Review the files before sharing; dxdiag and event messages may contain machine names, paths, or device identifiers."
