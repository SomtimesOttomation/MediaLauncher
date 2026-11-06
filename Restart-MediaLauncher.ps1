<#
.SYNOPSIS
    Starts MediaLauncher again after the running one has closed (the Restart & Reload button).
.DESCRIPTION
    Windows PowerShell 5.1. Started hidden by the launcher. Waits for the launcher process to exit (so its single-instance
    lock is free), then starts Start-MediaLauncher.bat the same way the person would, on the same tab. Nothing is copied or
    replaced; modules are simply read afresh by the new start. If the launcher does not close in time, nothing is started.
#>
param(
    [Parameter(Mandatory)][string]$AppDir,
    [Parameter(Mandatory)][int]$ParentPid,
    [string]$Open = '',
    [switch]$DebugMode,
    [int]$WaitSeconds = 45
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$AppDir = [IO.Path]::GetFullPath($AppDir).TrimEnd('\', '/')
$logDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MediaLauncher' } else { $AppDir }
$logFile = Join-Path $logDir 'restart.log'
function Write-Log {
    param([string]$Text)
    try { if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }; [IO.File]::AppendAllText($logFile, ("{0}  {1}`r`n" -f (Get-Date).ToString('s'), $Text), $utf8) } catch { }
}

try {
    $bat = Join-Path $AppDir 'Start-MediaLauncher.bat'
    if (-not (Test-Path -LiteralPath $bat -PathType Leaf)) { throw "Start-MediaLauncher.bat was not found in $AppDir." }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) { throw 'MediaLauncher did not close in time, so it was not started again.' }
    Start-Sleep -Milliseconds 400      # let Windows release the single-instance lock and the WebView2 profile

    $line = '"{0}" -Restarted' -f $bat
    if ($Open -cmatch '^[a-z][a-z0-9]{1,19}$') { $line += ' -Open ' + $Open }
    if ($DebugMode) { $line += ' -Debug' }
    $extra = @{}
    if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { $extra.WindowStyle = 'Hidden' }     # (PowerShell 7 on Linux has no such switch: test runs only)
    # cmd /c ""file.bat" args": the outer quotes keep cmd from stripping the inner ones when the path has spaces
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', ('"{0}"' -f $line) -WorkingDirectory $AppDir @extra
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
