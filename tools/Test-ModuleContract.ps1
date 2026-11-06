<#
.SYNOPSIS
    Checks a module folder against MediaLauncher's module contract, without opening a window or fetching anything.
.DESCRIPTION
    1. Checks module.json (the same rules the launcher uses).
    2. Loads the backend module and checks it exports the eight required functions.
    3. Unless -SkipInit: calls Initialize-Module with a test context, then Get-ModuleStatus, Receive-ModuleEvents,
       Suspend-ModuleWorker, Stop-ModuleTraffic and Stop-Module, and checks what they return. Start-ModuleWorker is never
       called, so the module's worker does not run and nothing is fetched. Initialize-Module creates the module's usual
       settings and cache folders, as running the module would, and the module must be closed (it takes its host lock).
.EXAMPLE
    powershell -File tools\Test-ModuleContract.ps1 -Path modules\SampleModule
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$SkipInit
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'core\MediaLauncher.Manifest.psm1') -Force
$script:Fail = 0
function Pass { param([string]$Text) Write-Host "  ok    $Text" -ForegroundColor Green }
function Fail { param([string]$Text) $script:Fail++; Write-Host "  FAIL  $Text" -ForegroundColor Red }
function Note { param([string]$Text) Write-Host "  note  $Text" -ForegroundColor Yellow }

$folder = (Resolve-Path -LiteralPath $Path).ProviderPath
Write-Host "Module contract check: $folder"

# 1. manifest
$info = Read-ModuleManifest -Folder $folder
if (-not $info.Ok) { Fail "module.json: $($info.Reason)"; exit 1 }
Pass ("module.json: {0} ({1}) v{2}, contract {3}" -f $info.Title, $info.Id, $info.Version, $info.Contract)
if (Test-Path -LiteralPath (Join-Path $folder '.github/workflows/release.yml') -PathType Leaf) { Pass 'release workflow present (.github/workflows/release.yml)' }
else { Note 'no .github/workflows/release.yml: releases will have no update package (see samples\SampleModule)' }
$updScript = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Update-*.ps1' })
if ($updScript.Count -and (Test-Path -LiteralPath (Join-Path $folder 'Apply-Update.ps1') -PathType Leaf)) { Pass ("updater present ({0}, Apply-Update.ps1)" -f $updScript[0].Name) }
else { Note 'no updater (Update-<Name>.ps1 and Apply-Update.ps1): see samples\SampleModule' }
if (-not @($info.DataSources).Count) { Note 'module.json lists no dataSources. Fine for a module that contacts nothing; otherwise list every third-party source and its terms.' }

# 2. backend exports
$required = @('Initialize-Module', 'Start-ModuleWorker', 'Suspend-ModuleWorker', 'Invoke-ModuleCommand', 'Receive-ModuleEvents', 'Get-ModuleStatus', 'Stop-ModuleTraffic', 'Stop-Module')
try {
    $mods = @(Import-Module -Name $info.Paths['backend'] -PassThru -Force -DisableNameChecking)
    $mod = $mods | Where-Object { $_.Path -eq $info.Paths['backend'] } | Select-Object -First 1
    if (-not $mod) { $mod = $mods[0] }
} catch { Fail "backend did not load: $($_.Exception.Message)"; exit 1 }
$missing = @($required | Where-Object { -not $mod.ExportedCommands[$_] })
if ($missing.Count) { Fail ("backend is missing: " + ($missing -join ', ')) } else { Pass 'backend exports all 8 required functions' }
if ($mod.ExportedCommands['Invoke-ModuleSync']) { Pass 'backend exports the optional Invoke-ModuleSync' } else { Note 'no Invoke-ModuleSync (optional; the master sync would skip this module)' }
$text = [IO.File]::ReadAllText($info.Paths['backend'])
if ($text -match 'Microsoft\.Web\.WebView2|Windows\.Forms\.Form\b') { Fail 'backend mentions WebView2 or creates a Form; only the host may do that' } else { Pass 'backend creates no window and does not load WebView2' }
$nonAscii = @(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue | Where-Object { @('.ps1', '.psm1', '.bat') -contains $_.Extension.ToLowerInvariant() -and [IO.File]::ReadAllText($_.FullName) -match '[^\x00-\x7F]' })
if ($nonAscii.Count) { Fail ('non-ASCII characters in: ' + (($nonAscii | ForEach-Object { $_.Name }) -join ', ')) } else { Pass 'scripts are ASCII-only' }
if ($missing.Count -or $SkipInit) { Write-Host ("Done: {0} problem(s)." -f $script:Fail); exit ([int]($script:Fail -gt 0)) }

# 3. lifecycle without the worker
$posted = New-Object System.Collections.Generic.List[string]
$sink = $posted
$ctx = [pscustomobject]@{
    Mode = 'launcher'; Root = $folder
    Post = { param([string]$Json) $sink.Add($Json) }.GetNewClosure()
    Close = { }; Relaunch = '"C:\MediaLauncher\Start-MediaLauncher.bat" -Open ' + $info.Id
    HostPid = $PID; Theme = 'system'; MediaLauncherVersion = '0.0.0-test'; Debug = $false
}
$call = { param([string]$Name, [hashtable]$P = @{}) $c = $mod.ExportedCommands[$Name]; & $c @P }
$initOk = $false
try {
    $init = & $call 'Initialize-Module' @{ Context = $ctx }
    if (-not $init) { Fail 'Initialize-Module returned nothing' }
    elseif (-not $init.Ok -and [string]$init.Reason -eq 'locked') { Fail 'Initialize-Module says locked: close the module (and MediaLauncher) and run this again'; exit 1 }
    elseif (-not $init.Ok) { Fail "Initialize-Module failed: $($init.Reason)" }
    else {
        $initOk = $true
        $bad = @('CacheDir', 'WebViewDataDir' | Where-Object { -not ($init.$_ -is [string]) -or -not $init.$_ })
        if ($bad.Count) { Fail ('Initialize-Module did not return ' + ($bad -join ', ')) } else { Pass "Initialize-Module: cache $($init.CacheDir)" }
        $again = & $call 'Initialize-Module' @{ Context = $ctx }
        if ($again -and $again.Ok) { Pass 'Initialize-Module can be called twice' } else { Note 'a second Initialize-Module call did not return Ok' }
    }
} catch { Fail "Initialize-Module threw: $($_.Exception.Message)" }

if ($initOk) {
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $s = & $call 'Get-ModuleStatus'
        $ms = $sw.ElapsedMilliseconds
        $keys = @('Live', 'Syncing', 'SyncPct', 'UpdateAvailable', 'Error', 'Traffic')
        $have = if ($s -is [hashtable]) { @($s.Keys) } else { @($s.PSObject.Properties.Name) }
        $miss = @($keys | Where-Object { $have -notcontains $_ })
        if ($miss.Count) { Fail ('Get-ModuleStatus is missing: ' + ($miss -join ', ')) } else { Pass "Get-ModuleStatus returns all keys ($ms ms)" }
        if ($s.Traffic -and $null -ne $s.Traffic.Requests -and $null -ne $s.Traffic.Bytes -and $null -ne $s.Traffic.Errors) { Pass 'Traffic has Requests, Bytes, Errors' } else { Fail 'Traffic must be @{ Requests; Bytes; Errors }' }
        if ($ms -gt 200) { Note 'Get-ModuleStatus took over 200 ms; it runs on the UI thread every 2 seconds' }
    } catch { Fail "Get-ModuleStatus threw: $($_.Exception.Message)" }
    try {
        $ev = @(& $call 'Receive-ModuleEvents')
        $nonString = @($ev | Where-Object { $_ -isnot [string] })
        if ($nonString.Count) { Fail 'Receive-ModuleEvents must return JSON strings' } elseif ($ev.Count -gt 25) { Fail 'Receive-ModuleEvents returned more than 25 items' } else { Pass "Receive-ModuleEvents returned $($ev.Count) message(s)" }
    } catch { Fail "Receive-ModuleEvents threw: $($_.Exception.Message)" }
    try {
        $r = @(& $call 'Invoke-ModuleCommand' @{ Message = [pscustomobject]@{ id = 999; cmd = 'no.such.command'; args = [pscustomobject]@{} } })
        $reply = @($posted | Where-Object { $_ -match '"id"\s*:\s*999' })
        if ($reply.Count -and $reply[0] -match '"ok"\s*:\s*false') { Pass 'an unknown command gets an error reply through Context.Post' } else { Fail 'an unknown command should be answered with {id, ok:false, error} through Context.Post' }
    } catch { Fail "Invoke-ModuleCommand threw on an unknown command: $($_.Exception.Message)" }
    foreach ($pc in @(@{ Id = 1001; Cmd = 'traffic.stop'; Stopped = 'true' }, @{ Id = 1002; Cmd = 'traffic.resume'; Stopped = 'false' })) {
        try {
            $posted.Clear()
            & $call 'Invoke-ModuleCommand' @{ Message = [pscustomobject]@{ id = $pc.Id; cmd = $pc.Cmd; args = [pscustomobject]@{} } } | Out-Null
            $reply = @($posted | Where-Object { $_ -match ('"id"\s*:\s*{0}\b' -f $pc.Id) })
            $evt = @($posted | Where-Object { $_ -match '"event"\s*:\s*"traffic"' -and $_ -match ('"stopped"\s*:\s*{0}' -f $pc.Stopped) })
            if (-not $reply.Count -or $reply[0] -notmatch '"ok"\s*:\s*true') { Fail "the page command $($pc.Cmd) must reply ok (see Kill switch in MODULE-CONTRACT.md)" }
            elseif (-not $evt.Count) { Fail "$($pc.Cmd) should send {""event"":""traffic"",""data"":{""stopped"":$($pc.Stopped)}} to the page" }
            else { Pass "page command $($pc.Cmd) replies ok and sends the traffic event" }
        } catch { Fail "$($pc.Cmd) threw: $($_.Exception.Message)" }
    }
    foreach ($fn in 'Suspend-ModuleWorker', 'Stop-ModuleTraffic') {
        try { & $call $fn | Out-Null; Pass "$fn ran" } catch { Fail "$fn threw: $($_.Exception.Message)" }
    }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $call 'Stop-Module' | Out-Null
        if ($sw.ElapsedMilliseconds -gt 2500) { Fail "Stop-Module took $($sw.ElapsedMilliseconds) ms (limit 2 s)" } else { Pass 'Stop-Module ran within 2 seconds' }
    } catch { Fail "Stop-Module threw: $($_.Exception.Message)" }
    try {
        $again = & $call 'Initialize-Module' @{ Context = $ctx }
        if ($again -and $again.Ok) { Pass 'the host lock was released (initialized again after Stop-Module)'; & $call 'Stop-Module' | Out-Null }
        else { Fail 'could not initialize again after Stop-Module: the host lock may not be released' }
    } catch { Fail "re-initialize after Stop-Module threw: $($_.Exception.Message)" }
}
Write-Host ("Done: {0} problem(s)." -f $script:Fail)
exit ([int]($script:Fail -gt 0))
