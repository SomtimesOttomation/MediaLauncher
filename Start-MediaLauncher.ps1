<#
.SYNOPSIS
    MediaLauncher: one window with modules as tabs on the left side.
.DESCRIPTION
    Windows PowerShell 5.1 + WebView2. Finds modules in its modules folder (each has a module.json) at start and
    when "Scan for modules" is pressed. Modules listed in catalog.json that are published on GitHub but not installed
    show as greyed tabs with a download link. It asks before loading a module that is not in the catalog, and hosts each in its own WebView2 through the module contract (MODULE-CONTRACT.md). Only the visible
    module's worker runs; hidden ones are suspended. The launcher itself fetches nothing.
.PARAMETER Open
    Id of the module to open first (used after a module update relaunches the launcher).
.PARAMETER Restarted
    Set by the Restart & Reload button: shows a "restarted" message once the window is up.
.PARAMETER Debug
    Enables DevTools and context menus in every view.
#>
param(
    [string]$Open = '',
    [switch]$Restarted,
    [switch]$Debug
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Version = '0.0.0'
try { $Version = ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim() } catch { }
if ($Open -cnotmatch '^[a-z][a-z0-9]{1,19}$') { $Open = '' }

# WinForms + WebView2 need a single-threaded apartment.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Open) { $relaunch += @('-Open', $Open) }
    if ($Restarted) { $relaunch += '-Restarted' }
    if ($Debug) { $relaunch += '-Debug' }
    & powershell.exe @relaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$AppName = 'MediaLauncher'

# ---------------------------------------------------------------- WebView2 assemblies
$lib = Join-Path $Root 'lib'
$need = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll'
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $lib $_)) })
if ($missing.Count) {
    [Windows.Forms.MessageBox]::Show("Missing WebView2 files in $lib :`n`n$($missing -join "`n")`n`nRun Setup-WebView2.ps1 once.", $AppName, 'OK', 'Warning') | Out-Null
    exit 1
}
Add-Type -Namespace MediaLauncher -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetDllDirectory(string path);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hWnd, int attr, ref int value, int size);
'@
[MediaLauncher.Native]::SetDllDirectory($lib) | Out-Null       # lets .NET find WebView2Loader.dll
Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll')

# ---------------------------------------------------------------- one launcher at a time
$created = $false
$script:AppMutex = New-Object System.Threading.Mutex($true, 'Local\MediaLauncher', [ref]$created)
if (-not $created) {
    [Windows.Forms.MessageBox]::Show('MediaLauncher is already open.', $AppName, 'OK', 'Information') | Out-Null
    exit 1
}

Import-Module (Join-Path $Root 'core\MediaLauncher.Manifest.psm1') -Force
Import-Module (Join-Path $Root 'core\MediaLauncher.Catalog.psm1') -Force
Import-Module (Join-Path $Root 'core\MediaLauncher.DropIn.psm1') -Force
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Required = @('Initialize-Module', 'Start-ModuleWorker', 'Suspend-ModuleWorker', 'Invoke-ModuleCommand', 'Receive-ModuleEvents', 'Get-ModuleStatus', 'Stop-ModuleTraffic', 'Stop-Module')

# ---------------------------------------------------------------- settings
$script:DataDir = Join-Path $env:LOCALAPPDATA 'MediaLauncher'
$script:SettingsPath = Join-Path $env:APPDATA 'MediaLauncher\settings.json'
foreach ($d in @($script:DataDir, (Split-Path $script:SettingsPath))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$script:ModulesDir = Join-Path $Root 'modules'
if (-not (Test-Path $script:ModulesDir)) { New-Item -ItemType Directory -Path $script:ModulesDir -Force | Out-Null }
$script:Settings = [pscustomobject]@{
    settingsVersion = 2; scanFolders = @($script:ModulesDir); approved = @(); declined = @(); order = @(); lastTab = ''; theme = 'system'; bounds = $null
    catalogCheck = $true; updateCheck = $true; moduleUpdateCheck = $false
}
if (Test-Path $script:SettingsPath) {
    try {
        $loaded = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        # scanFolders is never read back: it is always this copy's own modules folder, so a moved or second copy of
        # MediaLauncher (they share these settings) never scans another copy's modules
        foreach ($k in 'approved', 'declined', 'order') { if ($null -ne $loaded.$k) { $script:Settings.$k = @($loaded.$k | Where-Object { $_ -is [string] }) } }
        if ($loaded.lastTab -is [string]) { $script:Settings.lastTab = $loaded.lastTab }
        if (@('system', 'light', 'dark') -contains [string]$loaded.theme) { $script:Settings.theme = [string]$loaded.theme }
        if ($loaded.bounds) { $script:Settings.bounds = $loaded.bounds }
        if ($loaded.catalogCheck -is [bool]) { $script:Settings.catalogCheck = $loaded.catalogCheck }
        if ($loaded.updateCheck -is [bool]) { $script:Settings.updateCheck = $loaded.updateCheck }
        if ($loaded.moduleUpdateCheck -is [bool]) { $script:Settings.moduleUpdateCheck = $loaded.moduleUpdateCheck }
    } catch { }
}
function Save-Settings {
    $keep = $script:Settings | Select-Object -Property * -ExcludeProperty scanFolders
    try { [IO.File]::WriteAllText($script:SettingsPath, ($keep | ConvertTo-Json -Depth 5), $script:Utf8) } catch { }
}
# A module is approved by id and folder together, so a different folder claiming the same id asks again.
function Get-ApprovalKey { param($Info) return ('{0}|{1}' -f $Info.Id, $Info.Folder.ToLowerInvariant()) }

# ---------------------------------------------------------------- catalog: known modules and their GitHub releases
# GitHub is asked at start (at most once an hour) and when "Scan for modules" is pressed (at most every 10 minutes),
# only while some catalog module is not installed. A module not yet seen published is asked about every time (at most
# once a minute), so a newly published one shows up straight away. The answers are cached, so an offline start still shows them.
$script:Catalog = @(Read-Catalog -Path (Join-Path $Root 'catalog.json'))
$script:CatalogIds = @($script:Catalog | ForEach-Object { $_.Id })
$script:CatalogCachePath = Join-Path $script:DataDir 'catalog-cache.json'
$script:CatalogCache = @{ checkedAt = ''; ok = $false; results = @{} }
try {
    if (Test-Path $script:CatalogCachePath) {
        $c = Get-Content $script:CatalogCachePath -Raw | ConvertFrom-Json
        $script:CatalogCache.checkedAt = [string]$c.checkedAt
        $script:CatalogCache.ok = [bool]$c.ok
        foreach ($p in @($c.results.PSObject.Properties)) { $script:CatalogCache.results[$p.Name] = $p.Value }
    }
} catch { }
$script:CatalogLive = @{}            # this run's answers, by repo
$script:CatalogJob = $null
function Get-CatalogState {
    param($Entry)
    return (Resolve-CatalogEntry -Entry $Entry -Result $script:CatalogLive[$Entry.Repo] -Cached $script:CatalogCache.results[$Entry.Repo])
}
function Start-CatalogCheck {
    <# Asks GitHub in a background runspace, so the window never waits on the network. #>
    param([int]$MinMinutes)
    if (-not $script:Settings.catalogCheck -or $script:CatalogJob) { return }
    $installed = @($script:Tabs | Where-Object { $_.State -ne 'available' -and $_.State -ne 'broken' } | ForEach-Object { $_.Id })
    $repos = @($script:Catalog | Where-Object { $installed -notcontains $_.Id -and $_.Published -ne $false } | ForEach-Object { $_.Repo })
    if (-not $repos.Count) { return }
    $last = [datetime]::MinValue
    if ($script:CatalogCache.checkedAt) { try { $last = [datetime]::Parse($script:CatalogCache.checkedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
    # A module not yet seen published (new in the catalog, or its repo was private or had no release last time) is asked
    # about at every start and Scan, at most once a minute, so it appears as soon as its release is out. Modules already
    # seen published keep the longer wait.
    $unseen = @($repos | Where-Object { $r = $script:CatalogCache.results[$_]; -not $r -or [string]$r.Status -ne 'published' })
    $wait = $(if ($unseen.Count) { [Math]::Min($MinMinutes, 1) } else { $MinMinutes })
    if ($script:CatalogCache.ok -and ((Get-Date) - $last).TotalMinutes -lt $wait) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript("param([string[]]`$Repos) Import-Module '$((Join-Path $Root 'core\MediaLauncher.Catalog.psm1') -replace "'", "''")' -Force; Get-ReleaseInfo -Repos `$Repos").AddParameter('Repos', [string[]]$repos)
    $script:CatalogJob = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
}
function Complete-CatalogCheck {
    <# Called from the timer once the background check has finished. #>
    $j = $script:CatalogJob
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $script:CatalogJob = $null
    $results = @()
    try { $results = @($j.Ps.EndInvoke($j.Handle)) } catch { }
    try { $j.Ps.Dispose() } catch { }
    $allOk = $results.Count -gt 0
    foreach ($r in $results) {
        if (-not $r -or -not $r.Repo) { continue }
        $script:CatalogLive[[string]$r.Repo] = $r
        if ($r.Status -ne 'error') { $script:CatalogCache.results[[string]$r.Repo] = $r } else { $allOk = $false }
    }
    $script:CatalogCache.checkedAt = (Get-Date).ToString('o')
    $script:CatalogCache.ok = $allOk
    try { [IO.File]::WriteAllText($script:CatalogCachePath, (ConvertTo-Json -InputObject $script:CatalogCache -Depth 6), $script:Utf8) } catch { }
    [void](Invoke-Rescan)
}

# ---------------------------------------------------------------- launcher updates (child process)
# Update-MediaLauncher.ps1 checks GitHub and downloads + verifies a release into the update folder; Apply-Update.ps1
# swaps the files after the launcher closes, relaunches it, and rolls back if the new version does not confirm.
# Neither ever touches the modules folder.
$script:UpdDir = Join-Path $script:DataDir 'update'
if (-not (Test-Path $script:UpdDir)) { New-Item -ItemType Directory -Path $script:UpdDir -Force | Out-Null }
$script:UpdProc = $null
$script:UpdAction = ''
$script:UpdOut = Join-Path $script:UpdDir 'update.out'
$script:UpdResultPath = Join-Path $script:UpdDir 'update-result.json'
$script:Upd = @{ status = 'idle'; current = $Version; latest = ''; notes = ''; published = ''; htmlUrl = ''; error = ''; pct = 0; text = ''; installable = $false }
function Read-UpdateJson {
    param([string]$Name)
    $p = Join-Path $script:UpdDir $Name
    if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { } }
    return $null
}
function Set-UpdateFromResult {
    param($R)
    if (-not $R) { return }
    $script:Upd.status = [string]$R.status
    foreach ($k in 'latest', 'notes', 'published', 'htmlUrl', 'error') { $script:Upd[$k] = [string]$R.$k }
    $script:Upd.installable = [bool]$R.installable
    if ($script:Upd.status -eq 'staged') { $script:Upd.installable = $true }
}
# the last answer, so the rail can show "update available" before any new check
$prev = Read-UpdateJson 'update-result.json'
if ($prev -and [string]$prev.status -eq 'available' -and [string]$prev.current -eq $Version) { Set-UpdateFromResult $prev }
$staged = Read-UpdateJson 'staged.json'
if ($staged -and [string]$staged.from -eq $Version -and (Test-Path (Join-Path $script:UpdDir 'stage\Start-MediaLauncher.ps1'))) { $script:Upd.status = 'staged'; $script:Upd.latest = [string]$staged.version; $script:Upd.installable = $true }

function Start-Updater {
    param([ValidateSet('Check', 'Stage', 'StageZip')][string]$Action, [string]$ZipPath = '')
    if ($script:UpdProc -and -not $script:UpdProc.HasExited) { return $false }
    $cur = if ($env:MEDIALAUNCHER_FAKE_VERSION) { $env:MEDIALAUNCHER_FAKE_VERSION } else { $Version }     # test hook
    Remove-Item $script:UpdResultPath -Force -ErrorAction SilentlyContinue
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Update-MediaLauncher.ps1')),
                  '-Action', $Action, '-CurrentVersion', $cur, '-WorkDir', ('"{0}"' -f $script:UpdDir))
    if ($env:MEDIALAUNCHER_UPDATE_API) { $argsList += @('-ApiBase', $env:MEDIALAUNCHER_UPDATE_API) }      # test hook
    if ($ZipPath) { $argsList += @('-ZipPath', ('"{0}"' -f $ZipPath)) }
    $script:UpdAction = $Action
    $script:UpdProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:UpdOut
    $script:Upd.status = $(if ($Action -eq 'Check') { 'checking' } else { 'downloading' })
    $script:Upd.pct = 0; $script:Upd.text = 'Starting...'; $script:Upd.error = ''
    Send-UpdateState
    return $true
}
function Get-UpdaterProgress {
    $r = @{ pct = 0; text = '' }
    try {
        $fs = [IO.File]::Open($script:UpdOut, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs)
        while (($l = $sr.ReadLine()) -ne $null) { if ($l -match '^##PROGRESS (\d+)\|(.*)$') { $r.pct = [int]$Matches[1]; $r.text = $Matches[2] } }
        $sr.Close()
    } catch { }
    return $r
}
$script:LastUpdJson = ''
function Send-UpdateState {
    $json = ConvertTo-Json -InputObject @{ event = 'update'; data = $script:Upd } -Depth 4 -Compress
    if ($json -ne $script:LastUpdJson) { $script:LastUpdJson = $json; Send-View $panelView $json; Push-RailState }
}
function Watch-Updater {
    # from the timer: progress while it runs, the result once it ends
    if (-not $script:UpdProc) { return }
    if (-not $script:UpdProc.HasExited) {
        $p = Get-UpdaterProgress
        $script:Upd.pct = $p.pct; $script:Upd.text = $p.text
        Send-UpdateState
        return
    }
    $script:UpdProc = $null
    $res = Read-UpdateJson 'update-result.json'
    if (-not $res) { $res = [pscustomobject]@{ status = 'error'; error = 'The update check ended without an answer.' } }
    $was = $script:Upd.status
    Set-UpdateFromResult $res
    Send-UpdateState
    $d = $script:DropApply
    if ($d -and $d.Kind -eq 'launcher') {
        # a MediaLauncher package from the updates folder: install it straight away, as the person already said Apply
        $script:DropApply = $null
        if ($script:Upd.status -eq 'staged') {
            Move-DropDone $d.Path
            $err = Install-StagedUpdate
            if (-not $err) { $form.Close(); return }
            Show-Toast ("The MediaLauncher package was not applied: {0}" -f $err)
        } else {
            Show-Toast ("The MediaLauncher package was not applied: {0}" -f $script:Upd.error)
        }
        return
    }
    if ($script:Upd.status -eq 'available' -and $was -eq 'checking' -and -not $script:PanelOverride) { Show-Toast ("MediaLauncher v{0} is available. Click the version at the bottom of the tab rail." -f $script:Upd.latest) }
}
function Start-UpdateCheckIfDue {
    # at start: at most once a day, and only if the person has not turned it off
    if (-not $script:Settings.updateCheck) { return }
    Start-ModuleCheck -MinMinutes 1440 -Toast            # only does anything with module checks ticked
    if (@('staged', 'available') -contains $script:Upd.status) { return }
    $last = $null
    if ($prev -and $prev.checkedAt) { try { $last = [datetime]::Parse([string]$prev.checkedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
    if ($last -and ((Get-Date) - $last).TotalHours -lt 24 -and [string]$prev.status -ne 'error') { return }
    [void](Start-Updater 'Check')
}
function Install-StagedUpdate {
    $st = Read-UpdateJson 'staged.json'
    $stage = Join-Path $script:UpdDir 'stage'
    if (-not $st -or -not (Test-Path (Join-Path $stage 'Start-MediaLauncher.ps1'))) { return 'There is no downloaded update to install. Download it again.' }
    # run the helper from a copy, so replacing the launcher's files cannot touch the running helper
    $runDir = Join-Path $script:UpdDir 'run'
    if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
    $helper = Join-Path $runDir 'Apply-Update.ps1'
    Copy-Item (Join-Path $Root 'Apply-Update.ps1') $helper -Force
    $relaunch = '"' + (Join-Path $Root 'Start-MediaLauncher.bat') + '"'
    $b64 = [Convert]::ToBase64String($script:Utf8.GetBytes($relaunch))
    $h = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helper), '-AppDir', ('"{0}"' -f $Root), '-StageDir', ('"{0}"' -f $stage),
           '-WorkDir', ('"{0}"' -f $script:UpdDir), '-ParentPid', [string]$PID, '-OldVersion', $Version, '-NewVersion', [string]$st.version, '-RelaunchB64', $b64)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $h -WindowStyle Hidden | Out-Null
    return ''
}
# After an update: report the result once, and tell the helper this start worked (once the rail has loaded).
$script:UpdateNote = $null
$pend = Read-UpdateJson 'update-pending.json'
if ($pend -and [string]$pend.to -eq $Version) { $script:UpdateNote = @{ ok = $true; from = [string]$pend.from; to = [string]$pend.to } }
$failed = Read-UpdateJson 'update-failed.json'
if ($failed) {
    $script:UpdateNote = @{ ok = $false; from = [string]$failed.from; to = [string]$failed.to; reason = [string]$failed.reason }
    Remove-Item (Join-Path $script:UpdDir 'update-failed.json'), (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
}
function Confirm-UpdateStarted {
    $n = $script:UpdateNote
    if (-not $n) { return }
    $script:UpdateNote = $null
    if ($n.ok) {
        try { [IO.File]::WriteAllText((Join-Path $script:UpdDir 'update-ok.json'), '{"ok":true}', $script:Utf8) } catch { }
        Remove-Item (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
        $script:Upd.status = 'current'
        Show-Toast ("MediaLauncher was updated to v{0}." -f $n.to)
    } else {
        Show-Toast ("The update to v{0} did not work, so MediaLauncher is back on v{1}. {2}" -f $n.to, $n.from, $n.reason)
    }
}

# ---------------------------------------------------------------- one-click install of a catalog module (child process)
# Install-MediaLauncherModule.ps1 downloads the release zip and its checksum, checks them, unpacks into modules and checks the
# module.json id; the launcher then rescans and the greyed tab becomes a working one.
$script:InstallProc = $null
$script:InstallOut = Join-Path $script:DataDir 'install.out'
$script:InstallResult = Join-Path $script:DataDir 'install-result.json'
$script:Install = @{ id = ''; status = 'idle'; pct = 0; text = ''; error = ''; zip = '' }
$script:LastInstallJson = ''
function Send-InstallState {
    $json = ConvertTo-Json -InputObject @{ event = 'install'; data = $script:Install } -Depth 3 -Compress
    if ($json -ne $script:LastInstallJson) { $script:LastInstallJson = $json; Send-View $panelView $json }
}
function Start-ModuleInstall {
    param($Tab)
    if ($script:InstallProc -and -not $script:InstallProc.HasExited) { return 'Another module is installing. Wait for it to finish.' }
    $repo = $Tab.Catalog.Repo
    $zip = [string]$Tab.Release.Asset; $sha = [string]$Tab.Release.Sha
    if ($zip -notlike "https://github.com/$repo/releases/download/*" -or $sha -notlike "https://github.com/$repo/releases/download/*") { return 'This release has no package that can be installed automatically.' }
    Remove-Item $script:InstallResult -Force -ErrorAction SilentlyContinue
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Install-MediaLauncherModule.ps1')),
                  '-Id', $Tab.Id, '-Repo', $repo, '-ZipUrl', ('"{0}"' -f $zip), '-ShaUrl', ('"{0}"' -f $sha),
                  '-ModulesDir', ('"{0}"' -f $script:ModulesDir), '-ResultFile', ('"{0}"' -f $script:InstallResult))
    $script:InstallProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:InstallOut
    $script:Install = @{ id = $Tab.Id; status = 'installing'; pct = 0; text = 'Starting...'; error = '' }
    Send-InstallState
    return ''
}
function Start-ModuleInstallFromZip {
    # a module that is not installed yet, from a zip in the updates folder
    param([string]$Id, [string]$Zip)
    if ($script:InstallProc -and -not $script:InstallProc.HasExited) { return 'Another module is installing. Wait for it to finish.' }
    Remove-Item $script:InstallResult -Force -ErrorAction SilentlyContinue
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Install-MediaLauncherModule.ps1')),
                  '-Id', $Id, '-ZipPath', ('"{0}"' -f $Zip), '-ModulesDir', ('"{0}"' -f $script:ModulesDir), '-ResultFile', ('"{0}"' -f $script:InstallResult))
    $script:InstallProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:InstallOut
    $script:Install = @{ id = $Id; status = 'installing'; pct = 0; text = 'Starting...'; error = ''; zip = $Zip }
    Send-InstallState
    return ''
}
function Watch-Install {
    # from the timer: progress while it runs, then rescan so the tab turns on
    if (-not $script:InstallProc) { return }
    if (-not $script:InstallProc.HasExited) {
        $p = @{ pct = 0; text = '' }
        try {
            $fs = [IO.File]::Open($script:InstallOut, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
            while (($l = $sr.ReadLine()) -ne $null) { if ($l -match '^##PROGRESS (\d+)\|(.*)$') { $p.pct = [int]$Matches[1]; $p.text = $Matches[2] } }
            $sr.Close()
        } catch { }
        $script:Install.pct = $p.pct; $script:Install.text = $p.text
        Send-InstallState
        return
    }
    $script:InstallProc = $null
    $res = $null
    try { $res = Get-Content $script:InstallResult -Raw | ConvertFrom-Json } catch { }
    $id = $script:Install.id
    $name = $(if ($script:ById.ContainsKey($id)) { $script:ById[$id].Name } else { $id })
    if ($res -and [string]$res.status -eq 'installed') {
        if ($script:Install.zip) { Move-DropDone $script:Install.zip }
        $script:Install = @{ id = $id; status = 'installed'; pct = 100; text = 'Installed'; error = ''; zip = '' }
        Send-InstallState
        Show-Toast ("{0} is installed." -f $name)
        [void](Invoke-Rescan)
        if ($script:ById.ContainsKey($id) -and $script:Active -ne $id) { $script:Active = ''; Select-Tab $id }
    } else {
        $why = $(if ($res -and $res.error) { [string]$res.error } else { 'The installer ended without an answer.' })
        if ($script:Install.zip) { Show-Toast ("{0} was not installed: {1}" -f $name, $why) }
        $script:Install = @{ id = $id; status = 'error'; pct = 0; text = ''; error = $why; zip = '' }
        Send-InstallState
        if ($script:Active -eq $id) { Show-Notice }
    }
}

# ---------------------------------------------------------------- module updates (opt-in, on the update page)
# With "Also check my modules for updates" ticked (off by default), the launcher asks GitHub for the latest
# release of every installed module listed in catalog.json: when the update page opens (at most every 10 minutes), with
# Check again, and at start along with the launcher's own daily check. The person ticks which ones to update. MediaLauncher
# closes those modules, updates each with Install-MediaLauncherModule.ps1 -UpdateFolder (checksum, backup, rollback), then
# restarts on the same tab so the new files load fresh, as Restart & Reload does.
$script:ModRelPath = Join-Path $script:DataDir 'module-releases.json'
$script:ModRel = @{}                  # repo -> the last Get-ReleaseInfo answer
$script:ModCheckedAt = ''
try {
    if (Test-Path $script:ModRelPath) {
        $c = Get-Content $script:ModRelPath -Raw | ConvertFrom-Json
        $script:ModCheckedAt = [string]$c.checkedAt
        foreach ($p in @($c.results.PSObject.Properties)) { $script:ModRel[$p.Name] = $p.Value }
    }
} catch { }
$script:ModJob = $null
$script:ModJobToast = $false
$script:ModProc = $null
$script:ModOut = Join-Path $script:DataDir 'modupdate.out'
$script:ModResultPath = Join-Path $script:DataDir 'modupdate-result.json'
$script:ModDonePath = Join-Path $script:DataDir 'module-update-done.json'
$script:ModRun = @{ status = 'idle'; queue = @(); total = 0; index = 0; current = ''; pct = 0; text = ''; results = @{}; ok = 0 }
$script:PendingModUpd = $null
$script:LastModJson = ''

function Get-CatalogEntry { param([string]$Id) return ($script:Catalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1) }
function Get-ModuleRelease {
    <# The resolved latest release for an installed catalog module, or $null if never checked. #>
    param($Entry)
    $r = $script:ModRel[$Entry.Repo]
    if (-not $r) { return $null }
    return [pscustomobject]@{ Raw = $r; Res = (Resolve-CatalogEntry -Entry $Entry -Result $r -Cached $null) }
}
function Get-ModuleUpdateItems {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($script:Tabs | Where-Object { $_.Info -and $_.Info.Ok -and @('broken', 'available') -notcontains $_.State })) {
        $it = [ordered]@{ id = $t.Id; name = $t.Name; title = $t.Info.Title; current = $t.Info.Version; latest = ''; state = 'unknown'; note = '' }
        $entry = Get-CatalogEntry $t.Id
        if (-not $entry) { $it.state = 'notlisted'; $it.note = "Not in MediaLauncher's list of modules: update it from inside the module." }
        else {
            $rel = Get-ModuleRelease $entry
            if ($rel) {
                if ($rel.Raw.Status -eq 'error') { $it.state = 'error'; $it.note = [string]$rel.Raw.Error }
                elseif ($rel.Raw.Status -ne 'published' -or -not $rel.Res.Version) { $it.state = 'none' }
                else {
                    $it.latest = $rel.Res.Version
                    $cv = ConvertTo-ModuleVersion $t.Info.Version; $lv = ConvertTo-ModuleVersion $rel.Res.Version
                    if ($cv -and $lv -and $lv -gt $cv) { $it.state = $(if ($rel.Res.Asset -and $rel.Res.Sha) { 'update' } else { 'nopackage' }) }
                    elseif ($cv -and $lv -and $lv -lt $cv) { $it.state = 'ahead' }
                    else { $it.state = 'current' }
                }
            }
        }
        $res = $script:ModRun.results[$t.Id]
        if ($res -and -not $res.ok) { $it.note = [string]$res.error }
        $items.Add([pscustomobject]$it)
    }
    return $items.ToArray()
}
function Get-ModuleUpdateLatest {
    # for the rail badge: the newer version this check found for one tab, or $null
    param($Tab)
    if (-not $script:Settings.moduleUpdateCheck -or -not $Tab.Info -or -not $Tab.Info.Ok) { return $null }
    $entry = Get-CatalogEntry $Tab.Id
    if (-not $entry) { return $null }
    $rel = Get-ModuleRelease $entry
    if (-not $rel -or $rel.Raw.Status -ne 'published') { return $null }
    $cv = ConvertTo-ModuleVersion $Tab.Info.Version; $lv = ConvertTo-ModuleVersion $rel.Res.Version
    if ($cv -and $lv -and $lv -gt $cv) { return $rel.Res.Version }
    return $null
}
function Get-ModuleUpdateState {
    $r = $script:ModRun
    return @{
        enabled = [bool]$script:Settings.moduleUpdateCheck; checking = [bool]$script:ModJob; checkedAt = $script:ModCheckedAt
        items = @(Get-ModuleUpdateItems)
        run = @{ status = $r.status; total = $r.total; index = $r.index; current = $r.current; pct = $r.pct; text = $r.text }
    }
}
function Send-ModuleUpdateState {
    $json = ConvertTo-Json -InputObject @{ event = 'modules'; data = (Get-ModuleUpdateState) } -Depth 6 -Compress
    if ($json -ne $script:LastModJson) { $script:LastModJson = $json; Send-View $panelView $json }
}
function Start-ModuleCheck {
    <# Asks GitHub about the installed catalog modules in a background runspace. -MinMinutes 0 always asks. #>
    param([int]$MinMinutes = 10, [switch]$Toast)
    if (-not $script:Settings.moduleUpdateCheck -or $script:ModJob) { return }
    if ($MinMinutes -gt 0 -and $script:ModCheckedAt) {
        try { if (((Get-Date) - [datetime]::Parse($script:ModCheckedAt, [Globalization.CultureInfo]::InvariantCulture)).TotalMinutes -lt $MinMinutes) { return } } catch { }
    }
    $repos = @($script:Tabs | Where-Object { $_.Info -and $_.Info.Ok -and @('broken', 'available') -notcontains $_.State } |
               ForEach-Object { Get-CatalogEntry $_.Id } | Where-Object { $_ } | ForEach-Object { $_.Repo } | Select-Object -Unique)
    if (-not $repos.Count) { $script:ModCheckedAt = (Get-Date).ToString('o'); Send-ModuleUpdateState; return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript("param([string[]]`$Repos) Import-Module '$((Join-Path $Root 'core\MediaLauncher.Catalog.psm1') -replace "'", "''")' -Force; Get-ReleaseInfo -Repos `$Repos").AddParameter('Repos', [string[]]$repos)
    $script:ModJob = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
    $script:ModJobToast = [bool]$Toast
    Send-ModuleUpdateState
}
function Complete-ModuleCheck {
    $j = $script:ModJob
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $script:ModJob = $null
    $results = @()
    try { $results = @($j.Ps.EndInvoke($j.Handle)) } catch { }
    try { $j.Ps.Dispose() } catch { }
    foreach ($r in $results) { if ($r -and $r.Repo) { $script:ModRel[[string]$r.Repo] = $r } }
    $script:ModCheckedAt = (Get-Date).ToString('o')
    try { [IO.File]::WriteAllText($script:ModRelPath, (ConvertTo-Json -InputObject @{ checkedAt = $script:ModCheckedAt; results = $script:ModRel } -Depth 6), $script:Utf8) } catch { }
    Send-ModuleUpdateState
    Push-RailState
    $names = @(Get-ModuleUpdateItems | Where-Object { $_.state -eq 'update' } | ForEach-Object { $_.name })
    if ($script:ModJobToast -and $names.Count -and $script:PanelOverride -ne 'update') {
        Show-Toast ("Module update available: {0}. Click the version at the bottom of the tab rail." -f ($names -join ', '))
    }
}
function Complete-ModuleUpdateStart {
    # just after the page's mod.update command: may ask first if a chosen module is syncing
    $p = $script:PendingModUpd
    $script:PendingModUpd = $null
    $answer = 'false'
    try {
        if ($script:ModRun.status -eq 'updating' -or ($script:InstallProc -and -not $script:InstallProc.HasExited)) { Show-Toast 'Wait for the current install or update to finish.'; return }
        $pick = @(Get-ModuleUpdateItems | Where-Object { $_.state -eq 'update' -and $p.Ids -contains $_.id })
        if (-not $pick.Count) { return }
        $busy = @()
        foreach ($it in $pick) { $t = $script:ById[$it.id]; if ($t -and $t.State -eq 'ready' -and $t.Status -and $t.Status.Syncing) { $busy += "$($t.Name) is syncing" } }
        if ($busy.Count) {
            $q = "{0}.`n`nUpdating stops it. Update now?" -f ($busy -join ' and ')
            if ([Windows.Forms.MessageBox]::Show($q, $AppName, 'YesNo', 'Question') -ne 'Yes') { return }
        }
        $script:ModRun = @{ status = 'updating'; queue = @($pick | ForEach-Object { $_.id }); total = $pick.Count; index = 0; current = ''; pct = 0; text = ''; results = @{}; ok = 0 }
        $answer = 'true'
    } finally {
        if ($p) { Send-View $p.View ('{{"id":{0},"ok":true,"data":{1}}}' -f $p.Id, $answer) }
    }
    Start-NextModuleUpdate
}
function Start-NextModuleUpdate {
    $run = $script:ModRun
    while (@($run.queue).Count) {
        $q = @($run.queue)[0]
        $run.queue = @($run.queue | Select-Object -Skip 1)
        $run.index++
        $zip = ''
        if ($q -is [hashtable]) { $id = [string]$q.id; $zip = [string]$q.zip } else { $id = [string]$q }
        $t = $script:ById[$id]
        $entry = Get-CatalogEntry $id
        $rel = $(if ($entry -and -not $zip) { Get-ModuleRelease $entry } else { $null })
        if (-not $t -or -not $t.Info -or (-not $rel -and -not $zip)) { $run.results[$id] = @{ ok = $false; error = 'It is no longer installed.' }; continue }
        $folder = $t.Info.Folder
        Close-Tab $t                                   # stops it and releases its host lock
        $m = $null
        if ([Threading.Mutex]::TryOpenExisting("Local\ModuleHost-$id", [ref]$m)) {
            try { $m.Dispose() } catch { }
            $run.results[$id] = @{ ok = $false; error = "$($t.Name) is open in its own window. Close that window, then update again." }
            continue
        }
        Remove-Item $script:ModResultPath -Force -ErrorAction SilentlyContinue
        $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Install-MediaLauncherModule.ps1')), '-Id', $id)
        if ($zip) { $argsList += @('-ZipPath', ('"{0}"' -f $zip)) }
        else { $argsList += @('-Repo', $entry.Repo, '-ZipUrl', ('"{0}"' -f $rel.Res.Asset), '-ShaUrl', ('"{0}"' -f $rel.Res.Sha)) }
        $argsList += @('-ModulesDir', ('"{0}"' -f $script:ModulesDir), '-UpdateFolder', ('"{0}"' -f $folder), '-ResultFile', ('"{0}"' -f $script:ModResultPath))
        $run.current = $id; $run.currentZip = $zip; $run.pct = 0; $run.text = 'Starting...'
        $script:ModProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:ModOut
        Send-ModuleUpdateState
        Push-RailState
        return
    }
    Complete-ModuleUpdates
}
function Watch-ModuleUpdate {
    if (-not $script:ModProc) { return }
    $run = $script:ModRun
    if (-not $script:ModProc.HasExited) {
        try {
            $fs = [IO.File]::Open($script:ModOut, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
            while (($l = $sr.ReadLine()) -ne $null) { if ($l -match '^##PROGRESS (\d+)\|(.*)$') { $run.pct = [int]$Matches[1]; $run.text = $Matches[2] } }
            $sr.Close()
        } catch { }
        Send-ModuleUpdateState
        return
    }
    $script:ModProc = $null
    $res = $null
    try { $res = Get-Content $script:ModResultPath -Raw | ConvertFrom-Json } catch { }
    if ($res -and [string]$res.status -eq 'updated') {
        $run.results[$run.current] = @{ ok = $true; from = [string]$res.from; to = [string]$res.version }; $run.ok++
        if ($run.currentZip) { Move-DropDone $run.currentZip }
    }
    else { $run.results[$run.current] = @{ ok = $false; error = $(if ($res -and $res.error) { [string]$res.error } else { 'The updater ended without an answer.' }) } }
    $run.current = ''
    Start-NextModuleUpdate
}
function Complete-ModuleUpdates {
    $run = $script:ModRun
    $list = @(foreach ($k in $run.results.Keys) { $r = $run.results[$k]; $t = $script:ById[$k]; @{ id = $k; name = $(if ($t) { $t.Name } else { $k }); ok = [bool]$r.ok; from = [string]$r.from; to = [string]$r.to; error = [string]$r.error } })
    if ($run.ok -gt 0) {
        try { [IO.File]::WriteAllText($script:ModDonePath, (ConvertTo-Json -InputObject @{ results = $list } -Depth 4), $script:Utf8) } catch { }
        $run.status = 'restarting'
        Send-ModuleUpdateState
        try { Start-Relaunch; $form.Close(); return } catch { Show-Toast ("Updated, but could not restart: {0} Use Restart & Reload." -f $_.Exception.Message) }
    }
    $run.status = 'idle'
    Send-ModuleUpdateState
    Push-RailState
    $fail = @($list | Where-Object { -not $_.ok } | Select-Object -First 1)
    if ($fail.Count -and $run.ok -eq 0) { Show-Toast ("{0} was not updated: {1}" -f $fail[0].name, $fail[0].error) }
}
function Show-ModuleUpdateResult {
    # after the restart that follows module updates: say what happened, once
    if (-not (Test-Path $script:ModDonePath)) { return $false }
    $d = $null
    try { $d = Get-Content $script:ModDonePath -Raw | ConvertFrom-Json } catch { }
    Remove-Item $script:ModDonePath -Force -ErrorAction SilentlyContinue
    if (-not $d) { return $false }
    $ok = @($d.results | Where-Object { $_.ok } | ForEach-Object { "{0} v{1}" -f $_.name, $_.to })
    $bad = @($d.results | Where-Object { -not $_.ok } | ForEach-Object { "{0} was not updated: {1}" -f $_.name, $_.error })
    $text = ''
    if ($ok.Count) { $text = 'Updated ' + ($ok -join ', ') + '.' }
    if ($bad.Count) { $text = ($text + ' ' + ($bad -join ' ')).Trim() }
    Show-Toast $text
    return $true
}

# ---------------------------------------------------------------- drop-in updates: the updates folder
# A MediaLauncher or module zip dropped into <launcher>\updates is noticed within about 5 seconds (one folder
# listing; a zip is opened only once, after its size and time have stayed the same for 5 seconds so it is fully copied).
# If it is newer than what is installed, a prompt at the bottom right asks to apply it, and Apply runs the usual update:
# MediaLauncher stages it, swaps its files and restarts; a module is updated in place (backup and rollback) and MediaLauncher
# restarts, or a module that is not installed yet is installed. An applied zip is moved to updates\applied.
# Not now leaves the zip where it is; MediaLauncher asks again the next time it starts.
$script:DropDir = Join-Path $Root 'updates'
try { if (-not (Test-Path $script:DropDir)) { New-Item -ItemType Directory -Path $script:DropDir -Force | Out-Null } } catch { }
$script:DropSeen = @{}           # path -> size|time already handled this run
$script:DropPending = @{}        # path -> size|time seen once; acted on when unchanged at the next look
$script:DropAsk = $null          # the package being asked about
$script:DropApply = $null        # the MediaLauncher package being staged

function Move-DropDone {
    # an applied package goes to updates\applied, with its .sha256 if it had one
    param([string]$Path)
    try {
        $done = Join-Path $script:DropDir 'applied'
        if (-not (Test-Path $done)) { New-Item -ItemType Directory -Path $done -Force | Out-Null }
        $dest = Join-Path $done ([IO.Path]::GetFileName($Path))
        if (Test-Path -LiteralPath $dest) { $dest = Join-Path $done ('{0}-{1}{2}' -f [IO.Path]::GetFileNameWithoutExtension($Path), (Get-Date).ToString('yyyyMMdd-HHmmss'), [IO.Path]::GetExtension($Path)) }
        Move-Item -LiteralPath $Path -Destination $dest -Force
        if (Test-Path -LiteralPath "$Path.sha256") { Move-Item -LiteralPath "$Path.sha256" -Destination "$dest.sha256" -Force }
    } catch { }
}
function Test-DropFolder {
    <# Every 5 seconds from the timer. Cheap: one listing of the folder's top-level zip files. #>
    if ($script:DropAsk -or $script:DropApply -or $script:PendingModUpd) { return }
    if (@('updating', 'restarting') -contains $script:ModRun.status) { return }
    if (($script:InstallProc -and -not $script:InstallProc.HasExited) -or ($script:UpdProc -and -not $script:UpdProc.HasExited)) { return }
    $files = @()
    try { $files = @((New-Object IO.DirectoryInfo($script:DropDir)).GetFiles('*.zip') | Sort-Object Name) } catch { return }
    foreach ($f in $files) {
        $sig = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks
        if ($script:DropSeen[$f.FullName] -eq $sig) { continue }
        if ($script:DropPending[$f.FullName] -ne $sig) { $script:DropPending[$f.FullName] = $sig; continue }     # still arriving, or just arrived
        try { $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $fs.Close() } catch { continue }       # something still has it open
        $script:DropPending.Remove($f.FullName)
        $script:DropSeen[$f.FullName] = $sig
        $info = Get-DropInfo -Path $f.FullName
        $ask = Resolve-Drop $f $info
        if ($ask) { $script:DropAsk = $ask; Show-DropPrompt $ask.Text; return }
    }
}
function Resolve-Drop {
    # Returns what to ask about the package, or $null after a short message when there is nothing to apply.
    param($File, $Info)
    $n = $File.Name
    if ($Info.Kind -eq 'unknown') { Show-Toast ("{0} in the updates folder was not used: {1}" -f $n, $Info.Reason); return $null }
    $new = ConvertTo-ModuleVersion $Info.Version
    if ($Info.Kind -eq 'launcher') {
        $cur = ConvertTo-ModuleVersion $Version
        if (-not ($new -gt $cur)) { Show-Toast ("{0} is MediaLauncher v{1}, and you already have v{2}." -f $n, $Info.Version, $Version); return $null }
        return @{ Kind = 'launcher'; Path = $File.FullName; Info = $Info
                  Text = ("Update found: MediaLauncher v{0} ({1}). Apply it now? MediaLauncher restarts." -f $Info.Version, $n) }
    }
    $t = $script:ById[$Info.Id]
    if ($t -and $t.Info -and $t.Info.Ok -and @('broken', 'available') -notcontains $t.State) {
        $cur = ConvertTo-ModuleVersion $t.Info.Version
        if (-not ($new -gt $cur)) { Show-Toast ("{0} is {1} v{2}, and you already have v{3}." -f $n, $t.Name, $Info.Version, $t.Info.Version); return $null }
        return @{ Kind = 'update'; Path = $File.FullName; Info = $Info
                  Text = ("Update found: {0} v{1} (you have v{2}). Apply it now? MediaLauncher restarts." -f $t.Name, $Info.Version, $t.Info.Version) }
    }
    $name = $(if ($Info.Name) { $Info.Name } else { $Info.Id })
    return @{ Kind = 'install'; Path = $File.FullName; Info = $Info
              Text = ("New module found: {0} v{1} ({2}). Install it now?" -f $name, $Info.Version, $n) }
}
function Invoke-DropAnswer {
    param([bool]$Apply)
    $d = $script:DropAsk
    $script:DropAsk = $null
    Hide-DropPrompt
    if (-not $d) { return }
    if (-not $Apply) { Show-Toast 'Left in the updates folder. MediaLauncher asks again the next time it starts.'; return }
    if (-not (Test-Path -LiteralPath $d.Path)) { Show-Toast 'That package is no longer in the updates folder.'; return }
    switch ($d.Kind) {
        'launcher' {
            $script:DropApply = $d
            if (-not (Start-Updater 'StageZip' $d.Path)) { $script:DropApply = $null; Show-Toast 'An update check is running. Try again in a moment.'; return }
            Show-Toast ("Checking the MediaLauncher v{0} package..." -f $d.Info.Version)
        }
        'update' {
            if ($script:ModRun.status -eq 'updating') { Show-Toast 'Wait for the current update to finish.'; return }
            $t = $script:ById[$d.Info.Id]
            if ($t -and $t.State -eq 'ready' -and $t.Status -and $t.Status.Syncing) {
                if ([Windows.Forms.MessageBox]::Show("$($t.Name) is syncing.`n`nUpdating stops it. Update now?", $AppName, 'YesNo', 'Question') -ne 'Yes') { return }
            }
            $script:ModRun = @{ status = 'updating'; queue = @(@{ id = $d.Info.Id; zip = $d.Path }); total = 1; index = 0; current = ''; currentZip = ''; pct = 0; text = ''; results = @{}; ok = 0 }
            Show-Toast ("Updating {0}..." -f $(if ($t) { $t.Name } else { $d.Info.Id }))
            Start-NextModuleUpdate
        }
        'install' {
            $err = Start-ModuleInstallFromZip $d.Info.Id $d.Path
            if ($err) { Show-Toast $err } else { Show-Toast ("Installing {0}..." -f $(if ($d.Info.Name) { $d.Info.Name } else { $d.Info.Id })) }
        }
    }
}

# ---------------------------------------------------------------- tabs
$script:Tabs = New-Object System.Collections.ArrayList
$script:ById = @{}
$script:Active = ''

function Get-IconData {
    # The rail page cannot read module folders, so icons travel as data: URIs (200 KB max).
    param([string]$Path)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 204800) { return '' }
        $mime = if ($Path -match '\.svg$') { 'image/svg+xml' } else { 'image/png' }
        return ('data:{0};base64,{1}' -f $mime, [Convert]::ToBase64String($bytes))
    } catch { return '' }
}

function New-Tab {
    param($Info, [string]$State, [string]$Id, [string]$Name, [string]$Message = '', $Catalog = $null, $Release = $null)
    $icon = ''
    if ($Info -and $Info.Ok) { $icon = Get-IconData $Info.Paths['icon'] }
    elseif ($Catalog -and $Catalog.Icon) { $icon = Get-IconData (Join-Path $Root $Catalog.Icon) }
    return [pscustomobject]@{
        Id = $Id; Name = $Name; Info = $Info; State = $State; Error = $Message; Catalog = $Catalog; Release = $Release
        Module = $null; Fn = @{}; Ctx = $null; Init = $null; WebView = $null; Status = $null; Icon = $icon
    }
}

function Approve-Module {
    # Asks once per module folder. Returns the tab state: 'unloaded' (approved) or 'declined'.
    param($Info)
    $key = Get-ApprovalKey $Info
    if ($script:Settings.declined -contains $key) { return 'declined' }
    if ($script:Settings.approved -contains $key) { return 'unloaded' }
    if ($script:CatalogIds -contains $Info.Id) {
        # a module from the catalog, installed by the person from its release: no extra question
        $script:Settings.approved = @($script:Settings.approved) + $key
        Save-Settings
        return 'unloaded'
    }
    $q = "Add this module to MediaLauncher?`n`n{0} (version {1})`n{2}`n`nIts code will run inside MediaLauncher. Only add modules you got from a source you trust." -f $Info.Title, $Info.Version, $Info.Folder
    $state = 'declined'
    if ([Windows.Forms.MessageBox]::Show($form, $q, $AppName, 'YesNo', 'Question') -eq 'Yes') { $script:Settings.approved = @($script:Settings.approved) + $key; $state = 'unloaded' }
    else { $script:Settings.declined = @($script:Settings.declined) + $key }
    Save-Settings
    return $state
}

function Update-Tabs {
    <#
    Scans the module folders and rebuilds the tab list. A running module whose folder (or module.json) is gone is shut down
    and its tab removed. Returns counts of modules added and removed.
    ById is cleared and refilled rather than replaced: each module's Post closure holds a reference to it.
    #>
    $found = @(Find-Modulees -ScanFolders $script:Settings.scanFolders -Exclude @($Root))
    $before = @{}
    foreach ($t in $script:Tabs) { if ($t.Info -and $t.State -ne 'broken') { $before[(Get-ApprovalKey $t.Info)] = $true } }
    $loaded = @{}
    foreach ($t in $script:Tabs) {
        if (-not ($t.Module -or $t.Init)) { continue }
        if ($t.Info -and (Test-Path -LiteralPath (Join-Path $t.Info.Folder 'module.json') -PathType Leaf)) { $loaded[$t.Id] = $t }
        else { Close-Tab $t }                                         # removed or moved: shut it down
    }
    $order = @($script:Settings.order)
    $ok = @($found | Where-Object { $_.Ok } | Sort-Object @{ Expression = { $i = [array]::IndexOf($order, $_.Id); if ($i -lt 0) { 10000 } else { $i } } }, Folder)
    $newTabs = New-Object System.Collections.ArrayList
    $added = 0
    $seen = @{}
    foreach ($info in $ok) {
        $key = Get-ApprovalKey $info
        $seen[$key] = $true
        if ($loaded.ContainsKey($info.Id)) { [void]$newTabs.Add($loaded[$info.Id]); $loaded.Remove($info.Id); continue }
        if (-not $before.ContainsKey($key)) { $added++ }
        $state = Approve-Module $info
        [void]$newTabs.Add((New-Tab -Info $info -State $state -Id $info.Id -Name $info.Name))
    }
    foreach ($t in $loaded.Values) { Close-Tab $t }                 # its module.json no longer passes the checks
    $have = @($newTabs | ForEach-Object { $_.Id })
    foreach ($entry in $script:Catalog) {
        if ($have -contains $entry.Id) { continue }
        $st = Get-CatalogState $entry
        if ($st.Show) { [void]$newTabs.Add((New-Tab -Info $null -State 'available' -Id $entry.Id -Name $entry.Name -Catalog $entry -Release $st)) }
    }
    $n = 0
    foreach ($info in @($found | Where-Object { -not $_.Ok })) {
        $n++
        $leaf = Split-Path $info.Folder -Leaf
        if ($leaf.Length -gt 12) { $leaf = $leaf.Substring(0, 12) }
        [void]$newTabs.Add((New-Tab -Info $info -State 'broken' -Id ('broken' + $n) -Name $leaf -Message $info.Reason))
    }
    foreach ($t in $newTabs) { if (($t.Module -or $t.Init) -and $t.Info) { $seen[(Get-ApprovalKey $t.Info)] = $true } }
    $removed = @($before.Keys | Where-Object { -not $seen.ContainsKey($_) }).Count
    # the person's tab order (dragged on the rail) applies to every tab, installed or greyed; tabs not in it keep their
    # place after the ordered ones, and modules with a module.json problem stay at the end
    $pos = 0
    $sorted = @($newTabs | ForEach-Object {
        $i = [array]::IndexOf($order, $_.Id)
        $key = $(if ($_.State -eq 'broken') { 20000 + $pos } elseif ($i -ge 0) { $i } else { 10000 + $pos })
        $pos++
        [pscustomobject]@{ Key = $key; Tab = $_ }
    } | Sort-Object Key | ForEach-Object { $_.Tab })
    $script:Tabs.Clear()
    $script:ById.Clear()
    foreach ($t in $sorted) { [void]$script:Tabs.Add($t); $script:ById[$t.Id] = $t }
    return @{ added = $added; removed = $removed; broken = $n; total = @($newTabs | Where-Object { @('broken', 'available') -notcontains $_.State }).Count }
}

function ConvertTo-TabJson {
    param($T)
    $s = $T.Status
    return @{
        id = $T.Id; name = $T.Name; state = $T.State; icon = $T.Icon; error = $T.Error
        title = $(if ($T.Info) { $T.Info.Title } elseif ($T.Catalog) { $T.Catalog.Title } else { '' })
        version = $(if ($T.Info) { $T.Info.Version } elseif ($T.Release) { $T.Release.Version } else { '' })
        live = $(if ($s) { [int]$s.Live } else { 0 }); syncing = $(if ($s) { [bool]$s.Syncing } else { $false })
        syncPct = $(if ($s) { $s.SyncPct } else { $null })
        update = $(if ($s -and $s.UpdateAvailable) { $s.UpdateAvailable } else { Get-ModuleUpdateLatest $T })
        statusError = $(if ($s) { $s.Error } else { $null })
    }
}

# ---------------------------------------------------------------- window
$form = New-Object Windows.Forms.Form
$form.Text = $AppName
$form.MinimumSize = New-Object Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1600, 1000)
$b = $script:Settings.bounds
if ($b -and $b.w -ge 900 -and $b.h -ge 600) {
    $rect = New-Object Drawing.Rectangle([int]$b.x, [int]$b.y, [int]$b.w, [int]$b.h)
    if (@([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($rect) }).Count) {
        $form.StartPosition = 'Manual'
        $form.Bounds = $rect
        if ($b.max) { $form.WindowState = 'Maximized' }
    }
}

$launcherProfile = Join-Path $script:DataDir 'webview2'
function New-MediaLauncherView {
    param([string]$DockStyle)
    $v = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $p = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $p.UserDataFolder = $launcherProfile
    $v.CreationProperties = $p
    $v.Dock = $DockStyle
    return $v
}
$content = New-Object Windows.Forms.Panel
$content.Dock = 'Fill'
$form.Controls.Add($content)
$rail = New-MediaLauncherView 'Left'
$rail.Width = 76
$form.Controls.Add($rail)
$content.BringToFront()                       # docks last, so it fills what the rail leaves
$panelView = New-MediaLauncherView 'Fill'
$panelView.Visible = $false
$content.Controls.Add($panelView)

# ---------------------------------------------------------------- toast: bottom right, over whichever view is showing
# Same look as the modules' toasts (dark rounded box, 18 px from the corner, 3.5 seconds). A native control, because a
# page's HTML cannot draw over the other WebView2s.
$script:Toast = New-Object Windows.Forms.Label
$script:Toast.AutoSize = $true
$script:Toast.MaximumSize = New-Object Drawing.Size(420, 0)
$script:Toast.Padding = New-Object Windows.Forms.Padding(14, 10, 14, 10)
$script:Toast.Font = New-Object Drawing.Font('Segoe UI', 10)
$script:Toast.Anchor = 'Bottom, Right'
$script:Toast.Visible = $false
$content.Controls.Add($script:Toast)
$script:ToastTimer = New-Object Windows.Forms.Timer
$script:ToastTimer.Interval = 3500
$script:ToastTimer.add_Tick({ $script:ToastTimer.Stop(); $script:Toast.Visible = $false })
function Set-ToastShape {
    $t = $script:Toast; $d = 20
    if ($t.Width -lt $d -or $t.Height -lt $d) { return }
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($t.Width - $d, 0, $d, $d, 270, 90)
    $path.AddArc($t.Width - $d, $t.Height - $d, $d, $d, 0, 90); $path.AddArc(0, $t.Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $t.Region = New-Object Drawing.Region($path)
}
function Move-Toast {
    # sits above the drop-in prompt while that is showing
    $t = $script:Toast
    $bottom = $content.ClientSize.Height - 18
    if ($script:Prompt -and $script:Prompt.Visible) { $bottom = $script:Prompt.Top - 10 }
    $t.Location = New-Object Drawing.Point(($content.ClientSize.Width - $t.Width - 18), ($bottom - $t.Height))
}
function Test-DarkTheme {
    if ($script:Settings.theme -eq 'dark') { return $true }
    if ($script:Settings.theme -eq 'light') { return $false }
    try { return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { return $false }
}
# Title bar and corners: dark or light to match the theme, and rounded corners. Windows 11 also takes the launcher's own
# background and text colours for the bar; Windows 10 gets the plain dark or light bar and keeps square corners.
$script:FrameDark = $null
function Set-WindowFrame {
    param([switch]$Force)
    if (-not $form.IsHandleCreated) { return }
    $dark = [bool](Test-DarkTheme)
    if (-not $Force -and $dark -eq $script:FrameDark) { return }
    $script:FrameDark = $dark
    $h = $form.Handle
    $set = { param([int]$Attr, [int]$Value) $v = $Value; try { [MediaLauncher.Native]::DwmSetWindowAttribute($h, $Attr, [ref]$v, 4) } catch { -1 } }
    $on = [int]$dark
    if ((& $set 20 $on) -ne 0) { [void](& $set 19 $on) }          # dark mode (19 on Windows 10 before 20H1)
    [void](& $set 33 2)                                             # rounded corners (Windows 11)
    # COLORREF is 0x00BBGGRR: the --bg and --text colours from launcher.css
    if ($dark) { [void](& $set 35 0x0017100D); [void](& $set 36 0x00F4ECE8) }
    else { [void](& $set 35 0x00F8F5F4); [void](& $set 36 0x00221713) }
    [void](& $set 34 $(if ($dark) { 0x003E2F27 } else { 0x00EAE3DF }))   # border colour: --line
}
function Show-Toast {
    param([string]$Text)
    if (-not $Text) { return }
    $t = $script:Toast
    if (Test-DarkTheme) { $t.BackColor = [Drawing.Color]::FromArgb(232, 236, 244); $t.ForeColor = [Drawing.Color]::FromArgb(13, 16, 23) }
    else { $t.BackColor = [Drawing.Color]::FromArgb(19, 23, 34); $t.ForeColor = [Drawing.Color]::FromArgb(244, 245, 248) }
    $t.Text = $Text
    Set-ToastShape
    Move-Toast
    $t.Visible = $true
    $t.BringToFront()
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
}
$script:Toast.add_SizeChanged({ Set-ToastShape; Move-Toast })

# The drop-in prompt: like a toast, but it stays until Apply or Not now is pressed.
$script:Prompt = New-Object Windows.Forms.Panel
$script:Prompt.Size = New-Object Drawing.Size(380, 110)
$script:Prompt.Anchor = 'Bottom, Right'
$script:Prompt.Visible = $false
$script:PromptText = New-Object Windows.Forms.Label
$script:PromptText.Location = New-Object Drawing.Point(16, 14)
$script:PromptText.Size = New-Object Drawing.Size(348, 44)
$script:PromptText.Font = New-Object Drawing.Font('Segoe UI', 10)
$script:PromptApply = New-Object Windows.Forms.Button
$script:PromptLater = New-Object Windows.Forms.Button
foreach ($pb in @($script:PromptApply, $script:PromptLater)) {
    $pb.FlatStyle = 'Flat'; $pb.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5); $pb.Size = New-Object Drawing.Size(96, 30); $pb.Cursor = 'Hand'
}
$script:PromptApply.Text = 'Apply'
$script:PromptLater.Text = 'Not now'
$script:PromptApply.add_Click({ Invoke-DropAnswer $true })
$script:PromptLater.add_Click({ Invoke-DropAnswer $false })
$script:Prompt.Controls.AddRange(@($script:PromptText, $script:PromptApply, $script:PromptLater))
$content.Controls.Add($script:Prompt)
function Show-DropPrompt {
    param([string]$Text)
    $p = $script:Prompt
    $dark = [bool](Test-DarkTheme)
    $bg = $(if ($dark) { [Drawing.Color]::FromArgb(232, 236, 244) } else { [Drawing.Color]::FromArgb(19, 23, 34) })
    $fg = $(if ($dark) { [Drawing.Color]::FromArgb(13, 16, 23) } else { [Drawing.Color]::FromArgb(244, 245, 248) })
    $accent = $(if ($dark) { [Drawing.Color]::FromArgb(29, 66, 138) } else { [Drawing.Color]::FromArgb(110, 160, 255) })
    $p.BackColor = $bg; $script:PromptText.ForeColor = $fg; $script:PromptText.Text = $Text
    $sz = [Windows.Forms.TextRenderer]::MeasureText($Text, $script:PromptText.Font, (New-Object Drawing.Size(348, 0)), [Windows.Forms.TextFormatFlags]::WordBreak)
    $script:PromptText.Height = [Math]::Max(20, $sz.Height)
    $by = 14 + $script:PromptText.Height + 12
    $script:PromptApply.Location = New-Object Drawing.Point(16, $by)
    $script:PromptLater.Location = New-Object Drawing.Point(120, $by)
    $script:PromptApply.BackColor = $accent; $script:PromptApply.ForeColor = $(if ($dark) { [Drawing.Color]::White } else { [Drawing.Color]::FromArgb(13, 16, 23) })
    $script:PromptApply.FlatAppearance.BorderColor = $accent
    $script:PromptLater.BackColor = $bg; $script:PromptLater.ForeColor = $fg; $script:PromptLater.FlatAppearance.BorderColor = $fg
    $p.Height = $by + 30 + 14
    $d = 20
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($p.Width - $d, 0, $d, $d, 270, 90)
    $path.AddArc($p.Width - $d, $p.Height - $d, $d, $d, 0, 90); $path.AddArc(0, $p.Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $p.Region = New-Object Drawing.Region($path)
    Move-Prompt
    $p.Visible = $true
    $p.BringToFront()
    if ($script:Toast.Visible) { Move-Toast; $script:Toast.BringToFront() }
}
function Hide-DropPrompt { $script:Prompt.Visible = $false; if ($script:Toast.Visible) { Move-Toast } }
function Move-Prompt {
    $p = $script:Prompt
    $p.Location = New-Object Drawing.Point(($content.ClientSize.Width - $p.Width - 18), ($content.ClientSize.Height - $p.Height - 18))
}
$content.add_Resize({ if ($script:Prompt.Visible) { Move-Prompt } })
$content.add_Resize({ if ($script:Toast.Visible) { Move-Toast } })

function Send-View {
    param($View, [string]$Json)
    try { if ($View -and $View.CoreWebView2) { $View.CoreWebView2.PostWebMessageAsJson($Json) } } catch { }
}
function Send-Event {
    param($View, [string]$Name, $Data)
    Send-View $View (ConvertTo-Json -InputObject @{ event = $Name; data = $Data } -Depth 8 -Compress)
}
$script:LastRailJson = ''
function Push-RailState {
    $upd = $(if (@('available', 'staged', 'downloading') -contains $script:Upd.status) { $script:Upd.latest } else { '' })
    $obj = @{ tabs = @($script:Tabs | ForEach-Object { ConvertTo-TabJson $_ }); active = $script:Active; theme = $script:Settings.theme; launcherUpdate = $upd; overlay = [string]$script:PanelOverride }
    $json = ConvertTo-Json -InputObject @{ event = 'tabs'; data = $obj } -Depth 8 -Compress
    if ($json -ne $script:LastRailJson) { $script:LastRailJson = $json; Send-View $rail $json }
}

# ---------------------------------------------------------------- notices (locked, error, broken, declined, empty)
$script:Notice = $null
$script:PanelOverride = ''
function Get-Notice {
    if ($script:PanelOverride -eq 'update') { return @{ kind = 'update'; update = $script:Upd; updateCheck = [bool]$script:Settings.updateCheck; modules = (Get-ModuleUpdateState) } }
    $t = $script:ById[$script:Active]
    if (-not $t) {
        $sample = Join-Path $Root 'samples\SampleModule'
        return @{ kind = 'empty'; modulesDir = $script:ModulesDir; scanFolders = @($script:Settings.scanFolders); sampleDir = $(if (Test-Path $sample) { $sample } else { '' }) }
    }
    if ($t.State -eq 'available') {
        $repoName = ($t.Catalog.Repo -split '/')[1]
        return @{
            kind = 'available'; id = $t.Id; name = $t.Name; title = $t.Catalog.Title; repo = $t.Catalog.Repo
            version = $t.Release.Version; publishedAt = $t.Release.PublishedAt; assetName = $t.Release.AssetName
            hasAsset = [bool]$t.Release.Asset; hasSha = [bool]$t.Release.Sha; source = $t.Release.Source
            install = $(if ($script:Install.id -eq $t.Id) { $script:Install } else { $null })
            modulesDir = $script:ModulesDir; target = (Join-Path $script:ModulesDir $repoName)
        }
    }
    return @{
        kind = $t.State; id = $t.Id; name = $t.Name; message = $t.Error
        title = $(if ($t.Info) { $t.Info.Title } else { '' })
        folder = $(if ($t.Info) { $t.Info.Folder } else { '' })
        version = $(if ($t.Info) { $t.Info.Version } else { '' })
    }
}
function Show-Notice {
    $script:Notice = Get-Notice
    $panelView.Visible = $true
    $panelView.BringToFront()
    if ($script:Prompt.Visible) { $script:Prompt.BringToFront() }
    if ($script:Toast.Visible) { $script:Toast.BringToFront() }
    Send-Event $panelView 'notice' $script:Notice
}

# ---------------------------------------------------------------- module lifecycle
# ---------------------------------------------------------------- keyboard: Ctrl+1..9 jump to a tab, Ctrl+Tab cycles
# Keys typed in a module go to its WebView2, not to this window, so after each page loads the launcher adds this
# listener. It sends launcher.* messages, which the launcher handles itself and never passes to the module.
$script:KeyScript = @'
(() => {
  if (window.__launcherKeys) return;
  window.__launcherKeys = true;
  window.addEventListener('keydown', (e) => {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    const m = /^(?:Digit|Numpad)([1-9])$/.exec(e.code);
    const key = m ? m[1] : (e.key === 'Tab' ? 'Tab' : '');
    if (!key) return;
    e.preventDefault(); e.stopPropagation();
    window.chrome.webview.postMessage({ cmd: 'launcher.key', args: { key: key, shift: e.shiftKey } });
  }, true);
})();
'@
function Invoke-MediaLauncherKey {
    param($A)
    $tabs = @($script:Tabs)
    if (-not $tabs.Count) { return }
    $key = [string]$A.key
    $target = $null
    if ($key -match '^[1-9]$') {
        $i = [int]$key - 1
        if ($i -lt $tabs.Count) { $target = $tabs[$i] }
    } elseif ($key -eq 'Tab') {
        $cur = [array]::IndexOf(@($tabs | ForEach-Object { $_.Id }), $script:Active)
        $step = if ($A.shift) { -1 } else { 1 }
        $target = $tabs[(($cur + $step) % $tabs.Count + $tabs.Count) % $tabs.Count]
    }
    if ($target -and $target.Id -ne $script:Active) { Select-Tab $target.Id }
}

function Invoke-ModuleFn {
    # Calls a backend function through its own module object, never by bare name: every module exports the same names.
    param($Tab, [string]$Name, [hashtable]$Params = @{})
    $cmd = $Tab.Fn[$Name]
    if (-not $cmd) { return $null }
    return (& $cmd @Params)
}

function New-ModuleContext {
    param($Tab)
    $id = $Tab.Id; $reg = $script:ById; $fm = $form
    return [pscustomobject]@{
        Mode            = 'launcher'
        Root            = $Tab.Info.Folder
        Post            = { param([string]$Json) $r = $reg[$id]; if ($r -and $r.WebView -and $r.WebView.CoreWebView2) { try { $r.WebView.CoreWebView2.PostWebMessageAsJson($Json) } catch { } } }.GetNewClosure()
        Close           = { $fm.Close() }.GetNewClosure()
        Relaunch        = ('"{0}" -Open {1}' -f (Join-Path $Root 'Start-MediaLauncher.bat'), $id)
        HostPid         = $PID
        Theme           = $script:Settings.theme
        MediaLauncherVersion = $Version
        Debug           = [bool]$Debug
    }
}

function Remove-ModuleView {
    param($Tab)
    if ($Tab.WebView) {
        try { $content.Controls.Remove($Tab.WebView); $Tab.WebView.Dispose() } catch { }
        $Tab.WebView = $null
    }
}

function Close-Tab {
    <# Shuts a loaded module down and forgets its backend, so its tab can be removed or loaded again fresh. #>
    param($Tab)
    if ($Tab.Init) { try { Invoke-ModuleFn $Tab 'Stop-Module' | Out-Null } catch { } }
    Remove-ModuleView $Tab
    if ($Tab.Module) { try { Remove-Module -ModuleInfo $Tab.Module -Force -ErrorAction SilentlyContinue } catch { } }
    $Tab.Module = $null; $Tab.Fn = @{}; $Tab.Init = $null; $Tab.Ctx = $null; $Tab.Status = $null
    $Tab.State = 'unloaded'
}

function Open-Tab {
    <# Loads the backend if needed, initializes it, creates its WebView2 and starts its worker. #>
    param($Tab)
    try {
        if (-not $Tab.Module) {
            $mods = @(Import-Module -Name $Tab.Info.Paths['backend'] -PassThru -Force -DisableNameChecking -ErrorAction Stop)
            $mod = $mods | Where-Object { $_.Path -eq $Tab.Info.Paths['backend'] } | Select-Object -First 1
            if (-not $mod) { $mod = $mods[0] }
            $fns = @{}
            foreach ($f in $script:Required) {
                $c = $mod.ExportedCommands[$f]
                if (-not $c) { throw "Its backend does not export $f (module contract 1)." }
                $fns[$f] = $c
            }
            if ($mod.ExportedCommands['Invoke-ModuleSync']) { $fns['Invoke-ModuleSync'] = $mod.ExportedCommands['Invoke-ModuleSync'] }
            $Tab.Fn = $fns
            $Tab.Module = $mod
        }
        if (-not $Tab.Init) {
            if (-not $Tab.Ctx) { $Tab.Ctx = New-ModuleContext $Tab }
            # the last hashtable or object it outputs is the result, in case the backend leaks other output
            $init = @(Invoke-ModuleFn $Tab 'Initialize-Module' @{ Context = $Tab.Ctx }) | Where-Object { $_ -is [hashtable] -or $_ -is [pscustomobject] } | Select-Object -Last 1
            if (-not $init -or -not $init.Ok) {
                if ($init -and [string]$init.Reason -eq 'locked') { $Tab.State = 'locked'; $Tab.Error = '' }
                else { $Tab.State = 'error'; $Tab.Error = $(if ($init) { [string]$init.Reason } else { 'Initialize-Module returned nothing.' }) }
                return
            }
            foreach ($k in 'CacheDir', 'WebViewDataDir') {
                if (-not ($init.$k -is [string]) -or -not $init.$k) { throw "Initialize-Module did not return $k." }
                if (-not (Test-Path $init.$k)) { New-Item -ItemType Directory -Path $init.$k -Force | Out-Null }
            }
            $Tab.Init = $init
        }
        $Tab.State = 'ready'
        $Tab.Error = ''
        Remove-ModuleView $Tab
        New-ModuleView $Tab
        Invoke-ModuleFn $Tab 'Start-ModuleWorker' | Out-Null
    } catch {
        $Tab.State = 'error'
        $Tab.Error = $_.Exception.Message
    }
}

function New-ModuleView {
    param($Tab)
    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $p = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $p.UserDataFolder = $Tab.Init.WebViewDataDir     # the module's own profile: browser storage matches standalone
    $wv.CreationProperties = $p
    $wv.Dock = 'Fill'
    $wv.Tag = $Tab.Id
    $wv.Visible = ($script:Active -eq $Tab.Id)
    $content.Controls.Add($wv)
    $wv.BringToFront()
    # Events on the WinForms control: the sender is the control itself, whose Tag is the module id.
    $wv.add_CoreWebView2InitializationCompleted({ param($sender, $e) Complete-ModuleView $sender $e })
    $wv.add_WebMessageReceived({
        param($s, $a)
        $tab = $script:ById[[string]$s.Tag]
        if (-not $tab -or $tab.State -ne 'ready' -or -not [object]::ReferenceEquals($tab.WebView, $s)) { return }
        $msg = $null
        try { $msg = $a.WebMessageAsJson | ConvertFrom-Json } catch { return }
        if ($msg.cmd -is [string] -and $msg.cmd.StartsWith('launcher.')) {
            if ($msg.cmd -eq 'launcher.key') { try { Invoke-MediaLauncherKey $msg.args } catch { } }
            return
        }
        try { Invoke-ModuleFn $tab 'Invoke-ModuleCommand' @{ Message = $msg } | Out-Null } catch { }
    })
    $wv.add_NavigationStarting({
        param($s, $a)
        if ($a.Uri -notmatch ('^https://' + [regex]::Escape([string]$s.Tag) + '\.(ui|cache)/')) { $a.Cancel = $true }
    })
    $wv.add_NavigationCompleted({
        param($s, $a)
        Send-Event $s 'host.theme' @{ theme = $script:Settings.theme }
        try { [void]$s.CoreWebView2.ExecuteScriptAsync($script:KeyScript) } catch { }
    })
    $Tab.WebView = $wv
    [void]$wv.EnsureCoreWebView2Async($null)
}

function Complete-ModuleView {
    param($Sender, $E)
    $t = $script:ById[[string]$Sender.Tag]
    if (-not $t) { return }
    if (-not $E.IsSuccess) {
        $t.State = 'error'
        $t.Error = "WebView2 failed to start: $($E.InitializationException.Message)"
        if ($script:Active -eq $t.Id) { $Sender.Visible = $false; Show-Notice }
        Push-RailState
        return
    }
    $core = $Sender.CoreWebView2
    $allow = [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow
    $core.SetVirtualHostNameToFolderMapping("$($t.Id).ui", $t.Info.Paths['ui'], $allow)
    $core.SetVirtualHostNameToFolderMapping("$($t.Id).cache", $t.Init.CacheDir, $allow)
    $core.Settings.AreDefaultContextMenusEnabled = [bool]$Debug
    $core.Settings.AreDevToolsEnabled = [bool]$Debug
    $core.Settings.IsStatusBarEnabled = $false
    $core.add_NewWindowRequested({ param($s, $a) $a.Handled = $true })      # no pop-ups
    $core.Navigate(('https://{0}.ui/{1}' -f $t.Id, $t.Info.Entry))
}

function Select-Tab {
    param([string]$Id)
    if (@('updating', 'restarting') -contains $script:ModRun.status) { Show-Toast 'Wait for the module updates to finish.'; return }
    $script:PanelOverride = ''
    $next = $script:ById[$Id]
    if (-not $next) { return }
    $cur = $script:ById[$script:Active]
    if ($cur -and $cur -ne $next -and $cur.State -eq 'ready') {
        try { Invoke-ModuleFn $cur 'Suspend-ModuleWorker' | Out-Null } catch { }
        Send-Event $cur.WebView 'host.hidden' @{}
        if ($cur.WebView) { $cur.WebView.Visible = $false }
    }
    $wasActive = ($script:Active -eq $Id)
    $script:Active = $Id
    if ($next.Info -and $next.Info.Ok) { $script:Settings.lastTab = $Id }
    if ($next.State -eq 'unloaded') { Open-Tab $next }
    elseif ($next.State -eq 'ready' -and -not $wasActive) {
        try { Invoke-ModuleFn $next 'Start-ModuleWorker' | Out-Null } catch { }
        Send-Event $next.WebView 'host.visible' @{}
    }
    if ($next.State -eq 'ready' -and $next.WebView) {
        $panelView.Visible = $false
        $next.WebView.Visible = $true
        $next.WebView.BringToFront()
        if ($script:Prompt.Visible) { $script:Prompt.BringToFront() }
        if ($script:Toast.Visible) { $script:Toast.BringToFront() }
        $form.Text = '{0} - {1}' -f $next.Info.Title, $AppName
    } else {
        $form.Text = $AppName
        Show-Notice
    }
    Push-RailState
}

function Test-RunningModules {
    <#
    Every 2 seconds: one file check per running module (not a folder watch, and it never looks for new modules). A module
    whose module.json is gone keeps running from memory but would break on its next sync, update or reload, so it is
    paused and covered with a notice offering Close or Reload.
    #>
    foreach ($t in @($script:Tabs)) {
        if ($t.State -ne 'ready' -or -not $t.Info) { continue }
        if (Test-Path -LiteralPath (Join-Path $t.Info.Folder 'module.json') -PathType Leaf) { continue }
        $t.State = 'missing'
        try { Invoke-ModuleFn $t 'Suspend-ModuleWorker' | Out-Null } catch { }
        if ($script:Active -eq $t.Id) {
            if ($t.WebView) { $t.WebView.Visible = $false }
            $form.Text = $AppName
            Show-Notice
        }
        Show-Toast ("{0}'s folder was removed from the modules folder." -f $t.Name)
    }
}

function Stop-AllTraffic {
    $q = "Stop all traffic to every module's data sources now?`n`nSyncs, live refreshes and data requests stop. Update checks are not affected. Each module stays stopped until you resume it inside that module."
    if ([Windows.Forms.MessageBox]::Show($q, $AppName, 'YesNo', 'Warning') -ne 'Yes') { return -1 }
    $n = 0
    foreach ($t in $script:Tabs) {
        if ($t.State -eq 'ready') { try { Invoke-ModuleFn $t 'Stop-ModuleTraffic' | Out-Null; $n++ } catch { } }
    }
    return $n
}

$script:PendingStop = $null
function Complete-StopAllTraffic {
    $p = $script:PendingStop
    $n = 0
    try { $n = Stop-AllTraffic } catch { }
    $script:PendingStop = $null
    if ($p) { Send-View $p.View ('{{"id":{0},"ok":true,"data":{1}}}' -f $p.Id, $n) }
    if ($n -eq 0) { Show-Toast 'No module is running, so there was nothing to stop.' }
    elseif ($n -eq 1) { Show-Toast 'Data traffic stopped in 1 module. Resume it from inside the module.' }
    elseif ($n -gt 1) { Show-Toast "Data traffic stopped in $n modules. Resume each from inside the module." }
    Push-RailState
}

# Restart & Reload: close the launcher (every module is stopped cleanly) and start it again on the same tab, so
# changed module files are read afresh. A hidden helper waits for this process to exit, then starts the .bat.
$script:PendingRestart = $null
function Start-Relaunch {
    # starts the helper that reopens MediaLauncher on the same tab once this process has ended; the caller closes the form
    $openId = if ($script:Active -and $script:ById.ContainsKey($script:Active)) { $script:Active } else { [string]$script:Settings.lastTab }
    $h = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Restart-MediaLauncher.ps1')),
           '-AppDir', ('"{0}"' -f $Root), '-ParentPid', [string]$PID)
    if ($openId -cmatch '^[a-z][a-z0-9]{1,19}$') { $h += @('-Open', $openId) }
    if ($Debug) { $h += '-DebugMode' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $h -WindowStyle Hidden | Out-Null
}
function Complete-Restart {
    $p = $script:PendingRestart
    $ok = $false
    try {
        $busy = @()
        foreach ($t in $script:Tabs) { if ($t.State -eq 'ready' -and $t.Status -and $t.Status.Syncing) { $busy += "$($t.Name) is syncing" } }
        if ($script:InstallProc -and -not $script:InstallProc.HasExited) { $busy += 'a module is installing' }
        $go = $true
        if ($busy.Count) {
            $q = "{0}.`n`nRestarting stops it. Restart MediaLauncher now?" -f ($busy -join ' and ')
            $go = ([Windows.Forms.MessageBox]::Show($q, $AppName, 'YesNo', 'Question') -eq 'Yes')
        }
        if ($go) { Start-Relaunch; $ok = $true }
    } catch {
        Show-Toast ("Could not restart: {0}" -f $_.Exception.Message)
    }
    $script:PendingRestart = $null
    if ($p) { Send-View $p.View ('{{"id":{0},"ok":true,"data":{1}}}' -f $p.Id, $ok.ToString().ToLower()) }
    if ($ok) { $form.Close() }
}

$script:Scanning = $false
$script:PendingScan = $null
function Invoke-Rescan {
    <# Rescans the module folders, then reopens the active tab if its state changed. Returns the counts. #>
    if ($script:Scanning) { return $null }
    $script:Scanning = $true
    try {
        $active = $script:Active
        $r = Update-Tabs
        $stillReady = ($active -and $script:ById.ContainsKey($active) -and $script:ById[$active].State -eq 'ready')
        if (-not $stillReady) {
            $pick = $null
            if ($active -and $script:ById.ContainsKey($active)) { $pick = $active }
            else { $f = $script:Tabs | Where-Object { $_.State -eq 'unloaded' } | Select-Object -First 1; if (-not $f) { $f = $script:Tabs | Select-Object -First 1 }; if ($f) { $pick = $f.Id } }
            $script:Active = ''
            if ($pick) { Select-Tab $pick } else { Show-Notice }
        }
        Push-RailState
        return $r
    } finally { $script:Scanning = $false }
}
function Format-ScanResult {
    param($R)
    if ($R.busy) { return 'Already scanning.' }
    $bits = @()
    if ($R.added) { $bits += $(if ($R.added -eq 1) { '1 new module' } else { "$($R.added) new modules" }) }
    if ($R.removed) { $bits += $(if ($R.removed -eq 1) { '1 module removed' } else { "$($R.removed) modules removed" }) }
    if ($R.broken) { $bits += $(if ($R.broken -eq 1) { '1 module has a problem' } else { "$($R.broken) modules have a problem" }) }
    if (-not $bits.Count) { return 'No changes in the modules folder.' }
    return (($bits -join ', ') + '.')
}
function Complete-Scan {
    $p = $script:PendingScan
    $r = $null
    try { $r = Invoke-Rescan } catch { }
    try { Start-CatalogCheck -MinMinutes 10 } catch { }
    $script:PendingScan = $null
    if (-not $r) { $r = @{ added = 0; removed = 0; broken = 0; total = $script:Tabs.Count; busy = $true } }
    Show-Toast (Format-ScanResult $r)
    if ($p) { Send-View $p.View ('{{"id":{0},"ok":true,"data":{1}}}' -f $p.Id, (ConvertTo-Json -InputObject $r -Compress)) }
}

function Show-StandaloneWindow {
    # A locked module is open in its own window: bring that window to the front.
    param($Tab)
    $title = $Tab.Info.Title
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -eq $title } | Select-Object -First 1
    if (-not $p) { return $false }
    if ([MediaLauncher.Native]::IsIconic($p.MainWindowHandle)) { [MediaLauncher.Native]::ShowWindow($p.MainWindowHandle, 9) | Out-Null }
    return [MediaLauncher.Native]::SetForegroundWindow($p.MainWindowHandle)
}

# ---------------------------------------------------------------- rail and notice page commands
function Invoke-MediaLauncherCommand {
    param($View, $Msg)
    $a = $Msg.args
    $reply = { param($DataJson) Send-View $View ('{{"id":{0},"ok":true,"data":{1}}}' -f [int]$Msg.id, $DataJson) }
    $fail = { param($Text) Send-View $View ('{{"id":{0},"ok":false,"error":{1}}}' -f [int]$Msg.id, (ConvertTo-Json -InputObject ([string]$Text) -Compress)) }
    $tabArg = { $i = [string]$a.id; if ($i -cmatch '^[a-z][a-z0-9]{1,19}$' -and $script:ById.ContainsKey($i)) { $script:ById[$i] } else { $null } }
    switch ([string]$Msg.cmd) {
        'rail.init' {
            $script:LastRailJson = ''
            & $reply (ConvertTo-Json -InputObject @{ version = $Version; theme = $script:Settings.theme; debug = [bool]$Debug } -Compress)
            Push-RailState
            Confirm-UpdateStarted                     # the launcher has loaded: an update just installed can be kept
        }
        'update.open' {
            & $reply 'true'
            $script:PanelOverride = 'update'
            $form.Text = $AppName
            Show-Notice
            Push-RailState
            if (@('idle', 'error', 'none') -contains $script:Upd.status) { [void](Start-Updater 'Check') }
            Start-ModuleCheck -MinMinutes 10
        }
        'update.close' {
            & $reply 'true'
            if (@('updating', 'restarting') -contains $script:ModRun.status) { Show-Toast 'Wait for the module updates to finish.'; return }
            $back = $script:Active
            $script:PanelOverride = ''
            $script:Active = ''
            if ($back -and $script:ById.ContainsKey($back)) { Select-Tab $back } else { Show-Notice; Push-RailState }
        }
        'update.check' { & $reply ((Start-Updater 'Check').ToString().ToLower()) }
        'mod.auto' {
            $script:Settings.moduleUpdateCheck = [bool]$a.on
            Save-Settings
            & $reply 'true'
            if ($script:Settings.moduleUpdateCheck) { Start-ModuleCheck -MinMinutes 10 }
            Send-ModuleUpdateState
            Push-RailState
        }
        'mod.check' { & $reply 'true'; Start-ModuleCheck -MinMinutes 0 }
        'mod.update' {
            $ids = @(@($a.ids) | Where-Object { $_ -is [string] -and $_ -cmatch '^[a-z][a-z0-9]{1,19}$' })
            if (-not $ids.Count) { & $fail 'nothing chosen'; return }
            if ($script:PendingModUpd) { & $reply 'false'; return }
            $script:PendingModUpd = @{ View = $View; Id = [int]$Msg.id; Ids = $ids }
            [void]$form.BeginInvoke([Action]{ Complete-ModuleUpdateStart })
        }
        'update.stage' { & $reply ((Start-Updater 'Stage').ToString().ToLower()) }
        'update.cancel' {
            try { if ($script:UpdProc -and -not $script:UpdProc.HasExited) { $script:UpdProc.Kill() } } catch { }
            & $reply 'true'
        }
        'update.apply' {
            $err = Install-StagedUpdate
            if ($err) { & $fail $err; return }
            & $reply 'true'
            $form.Close()                              # the helper waits for this process to end, then swaps the files
        }
        'update.auto' {
            $script:Settings.updateCheck = [bool]$a.on
            Save-Settings
            & $reply 'true'
        }
        'panel.get' { & $reply (ConvertTo-Json -InputObject @{ notice = (Get-Notice); theme = $script:Settings.theme } -Depth 6 -Compress) }
        'tab.select' {
            $t = & $tabArg
            if (-not $t) { & $fail 'unknown tab'; return }
            & $reply 'true'
            Select-Tab $t.Id
        }
        'tab.retry' {
            $t = & $tabArg
            if (-not $t -or @('locked', 'error') -notcontains $t.State) { & $fail 'nothing to retry'; return }
            if (-not $t.Init) { $t.Module = $null }           # import again in case the backend file was fixed
            $t.State = 'unloaded'
            & $reply 'true'
            $script:Active = ''
            Select-Tab $t.Id
        }
        'tab.approve' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'declined') { & $fail 'not declined'; return }
            $key = Get-ApprovalKey $t.Info
            $script:Settings.declined = @($script:Settings.declined | Where-Object { $_ -ne $key })
            $script:Settings.approved = @($script:Settings.approved) + $key
            Save-Settings
            $t.State = 'unloaded'
            & $reply 'true'
            $script:Active = ''
            Select-Tab $t.Id
        }
        'tab.close' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'missing') { & $fail 'not missing'; return }
            & $reply 'true'
            Close-Tab $t
            $script:Active = ''
            [void](Invoke-Rescan)
        }
        'tab.reload' {
            # only if the folder is back: then the module starts again fresh from its files
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'missing') { & $fail 'not missing'; return }
            if (-not (Test-Path -LiteralPath (Join-Path $t.Info.Folder 'module.json') -PathType Leaf)) { & $reply 'false'; return }
            & $reply 'true'
            $id = $t.Id
            Close-Tab $t
            [void](Invoke-Rescan)
            if ($script:ById.ContainsKey($id) -and $script:Active -ne $id) { $script:Active = ''; Select-Tab $id }
        }
        'tab.switchTo' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'locked') { & $fail 'not locked'; return }
            & $reply ((Show-StandaloneWindow $t).ToString().ToLower())
        }
        'tabs.reorder' {
            # the rail's new order after a drag; tabs it does not name keep their place after the named ones
            $ids = @(@($a.ids) | Where-Object { $_ -is [string] -and $script:ById.ContainsKey($_) } | Select-Object -Unique)
            if (-not $ids.Count) { & $fail 'no tabs'; return }
            $rest = @($script:Tabs | Where-Object { $ids -notcontains $_.Id })
            $new = @($ids | ForEach-Object { $script:ById[$_] }) + $rest
            $script:Tabs.Clear()
            foreach ($t in $new) { [void]$script:Tabs.Add($t) }
            $script:Settings.order = @($script:Tabs | Where-Object { $_.State -ne 'broken' } | ForEach-Object { $_.Id })
            Save-Settings
            & $reply 'true'
            Push-RailState
        }
        'theme.set' {
            $th = [string]$a.theme
            if (@('system', 'light', 'dark') -notcontains $th) { & $fail 'bad theme'; return }
            $script:Settings.theme = $th
            Save-Settings
            foreach ($t in $script:Tabs) {
                if ($t.Ctx) { $t.Ctx.Theme = $th }
                if ($t.State -eq 'ready') { Send-Event $t.WebView 'host.theme' @{ theme = $th } }
            }
            Send-Event $panelView 'theme' @{ theme = $th }
            & $reply 'true'
            Set-WindowFrame
            Push-RailState
        }
        'modules.scan' {
            # approval dialogs may open, so run it just after this WebView2 event returns
            if ($script:PendingScan) { & $reply '{"busy":true}'; return }
            $script:PendingScan = @{ View = $View; Id = [int]$Msg.id }
            [void]$form.BeginInvoke([Action]{ Complete-Scan })
        }
        'app.restart' {
            # may ask first (a sync or install is running), so run it just after this WebView2 event returns
            if ($script:PendingRestart) { & $reply 'false'; return }
            $script:PendingRestart = @{ View = $View; Id = [int]$Msg.id }
            [void]$form.BeginInvoke([Action]{ Complete-Restart })
        }
        'catalog.download' {
            # open the release download (or its page) in the default browser; only github.com links for that repo
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'available') { & $fail 'not available'; return }
            $url = if ($a.page -or -not $t.Release.Asset) { $t.Release.Url } else { $t.Release.Asset }
            if ($url -notlike "https://github.com/$($t.Catalog.Repo)/*") { & $fail 'bad link'; return }
            try { Start-Process $url; & $reply 'true' } catch { & $fail $_.Exception.Message }
        }
        'catalog.install' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'available') { & $fail 'not available'; return }
            $err = Start-ModuleInstall $t
            if ($err) { & $fail $err; return }
            & $reply 'true'
        }
        'modules.open' {
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:ModulesDir); & $reply 'true' } catch { & $fail $_.Exception.Message }
        }
        'key' { & $reply 'true'; Invoke-MediaLauncherKey $a }
        'traffic.stop' {
            # WebView2 must not run a modal dialog inside its own event: ask just after this handler returns
            if ($script:PendingStop) { & $reply '0'; return }
            $script:PendingStop = @{ View = $View; Id = [int]$Msg.id }
            [void]$form.BeginInvoke([Action]{ Complete-StopAllTraffic })
        }
        default { & $fail ('unknown command: ' + [string]$Msg.cmd) }
    }
}

function Initialize-MediaLauncherView {
    param($View, [string]$Page)
    $View.add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if (-not $e.IsSuccess) {
            [Windows.Forms.MessageBox]::Show("WebView2 failed to start:`n$($e.InitializationException.Message)`n`nInstall the Evergreen WebView2 Runtime from Microsoft.", $AppName, 'OK', 'Error') | Out-Null
            $form.Close(); return
        }
        $core = $sender.CoreWebView2
        $core.SetVirtualHostNameToFolderMapping('launcher.ui', (Join-Path $Root 'ui'), [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
        $core.Settings.AreDefaultContextMenusEnabled = [bool]$Debug
        $core.Settings.AreDevToolsEnabled = [bool]$Debug
        $core.Settings.IsStatusBarEnabled = $false
        $core.add_NewWindowRequested({ param($s, $a) $a.Handled = $true })
        $core.Navigate('https://launcher.ui/' + $sender.Tag)
    })
    $View.add_WebMessageReceived({
        param($s, $a)
        $msg = $null
        try { $msg = $a.WebMessageAsJson | ConvertFrom-Json } catch { return }
        try { Invoke-MediaLauncherCommand $s $msg } catch { }
    })
    $View.add_NavigationStarting({ param($s, $a) if ($a.Uri -notmatch '^https://launcher\.ui/') { $a.Cancel = $true } })
    $View.Tag = $Page
}
Initialize-MediaLauncherView $rail 'rail.html'
Initialize-MediaLauncherView $panelView 'panel.html'

# ---------------------------------------------------------------- timer: page events every 250 ms, status every 2 s
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$script:Tick = 0
$timer.add_Tick({
    $script:Tick++
    foreach ($t in @($script:Tabs)) {
        if ($t.State -ne 'ready') { continue }
        try { foreach ($json in @(Invoke-ModuleFn $t 'Receive-ModuleEvents')) { if ($json) { Send-View $t.WebView ([string]$json) } } } catch { }
        if ($script:Tick % 8 -eq 0) {
            try { $t.Status = Invoke-ModuleFn $t 'Get-ModuleStatus' } catch { $t.Status = @{ Error = $_.Exception.Message } }
        }
    }
    if ($script:Tick % 8 -eq 0) { Test-RunningModules; Push-RailState }
    if ($script:Tick % 8 -eq 4 -and $script:Settings.theme -eq 'system') { Set-WindowFrame }     # follows a Windows light/dark switch
    if ($script:CatalogJob -and $script:CatalogJob.Handle.IsCompleted) { Complete-CatalogCheck }
    if ($script:UpdProc) { Watch-Updater }
    if ($script:InstallProc) { Watch-Install }
    if ($script:ModJob -and $script:ModJob.Handle.IsCompleted) { Complete-ModuleCheck }
    if ($script:ModProc) { Watch-ModuleUpdate }
    if ($script:Tick % 20 -eq 10) { Test-DropFolder }                    # the updates folder, every 5 seconds
})

# ---------------------------------------------------------------- start and close
$form.add_HandleCreated({ Set-WindowFrame -Force })
$form.add_Shown({
    Set-WindowFrame -Force
    [void](Update-Tabs)
    [void]$rail.EnsureCoreWebView2Async($null)
    [void]$panelView.EnsureCoreWebView2Async($null)
    $first = $null
    foreach ($want in @($Open, $script:Settings.lastTab)) {
        if ($want -and $script:ById.ContainsKey($want) -and @('unloaded', 'declined') -contains $script:ById[$want].State) { $first = $want; break }
    }
    if (-not $first) { $f = $script:Tabs | Where-Object { $_.State -eq 'unloaded' } | Select-Object -First 1; if ($f) { $first = $f.Id } }
    if (-not $first -and $script:Tabs.Count) { $first = $script:Tabs[0].Id }
    if ($first) { Select-Tab $first } else { Show-Notice }
    $timer.Start()
    Start-CatalogCheck -MinMinutes 60
    Start-UpdateCheckIfDue
    if (-not (Show-ModuleUpdateResult) -and $Restarted) { Show-Toast 'MediaLauncher restarted. Modules were read again.' }
})

$form.add_FormClosing({
    $timer.Stop()
    if ($script:CatalogJob) { try { $script:CatalogJob.Ps.Stop(); $script:CatalogJob.Ps.Dispose() } catch { } }
    if ($script:ModJob) { try { $script:ModJob.Ps.Stop(); $script:ModJob.Ps.Dispose() } catch { } }
    # a module update in progress is left to finish (it rolls back on its own if it fails)
    try { if ($script:UpdProc -and -not $script:UpdProc.HasExited) { $script:UpdProc.Kill() } } catch { }
    try { if ($script:InstallProc -and -not $script:InstallProc.HasExited) { $script:InstallProc.Kill() } } catch { }
    foreach ($t in @($script:Tabs)) {
        if ($t.Init) { try { Invoke-ModuleFn $t 'Stop-Module' | Out-Null } catch { } }
    }
    $nb = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    $script:Settings.bounds = @{ x = $nb.X; y = $nb.Y; w = $nb.Width; h = $nb.Height; max = ($form.WindowState -eq 'Maximized') }
    Save-Settings
})

[Windows.Forms.Application]::Run($form)
try { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() } catch { }
