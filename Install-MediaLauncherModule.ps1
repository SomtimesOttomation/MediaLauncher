<#
.SYNOPSIS
    Installs a module from its GitHub release into MediaLauncher's modules folder.
.DESCRIPTION
    Windows PowerShell 5.1. Runs as a hidden child process of the launcher, so the window never freezes.
    Downloads the release zip and its published SHA-256, checks they match, unpacks it entry by entry (rejecting path
    tricks and oversized archives) into a temporary folder inside modules, checks its module.json passes the launcher's
    rules and has the expected id, then renames the folder into place. An existing folder is never replaced.
    Only https links on github.com for the given repo are accepted.
    With -ZipPath it uses a zip the person dropped into the updates folder instead of downloading (no -Repo or links
    needed). If <zip>.sha256 sits beside it, the zip must match it. The dropped file itself is never changed.
    With -UpdateFolder it updates an installed module instead: the same download and checks, then the package's files
    are copied over that folder after backing up what they replace. Its lib\ and update\ folders and anything else not in
    the package are kept (a module keeps its settings and cache outside its folder). Leftover files the new version no
    longer has are removed only inside folders the package itself has. If anything fails, the backup is put back.
    Progress lines on stdout:  ##PROGRESS <pct>|<text>
    Result: a JSON file (UTF-8, no BOM): { status: 'installed' | 'updated' | 'error', id, folder, version, from, error }.
#>
param(
    [Parameter(Mandatory)][string]$Id,
    [string]$Repo = '',
    [string]$ZipUrl = '',
    [string]$ShaUrl = '',
    [string]$ZipPath = '',                 # a zip dropped into the updates folder instead of a GitHub download
    [Parameter(Mandatory)][string]$ModulesDir,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$FolderName = '',
    [string]$UpdateFolder = '',            # update this installed module in place instead of installing a new one
    [long]$MaxZipBytes = 100MB,
    [long]$MaxUnpackedBytes = 300MB,
    [switch]$AllowLocalTestUrls,           # test hook: lets the test suite serve files from 127.0.0.1
    [switch]$TestFailAfterCopy             # test hook: fails an update after its files are copied, to test the rollback
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
Import-Module (Join-Path $PSScriptRoot 'core\MediaLauncher.Manifest.psm1') -Force
$utf8 = New-Object System.Text.UTF8Encoding($false)
$DroppedZip = $ZipPath          # (PowerShell names ignore case: $zipPath below is the working copy)
$staging = $null
$zipPath = $null
$skipTop = 'lib', 'update', '.git'      # a module's own top-level folders that an update never backs up, overwrites or deletes

function Get-RelFiles {
    param([string]$Dir)
    $r = [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($r.Length)
        if ($skipTop -contains ($rel -split '[\\/]')[0].ToLowerInvariant()) { continue }
        $rel
    }
}
function Copy-Rel {
    param([string]$From, [string]$To, [string]$Rel)
    $dst = Join-Path $To $Rel
    $dir = Split-Path $dst
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $From $Rel) -Destination $dst -Force
}
function Update-InPlace {
    # Copies the checked package over the installed folder; puts the backup back if anything goes wrong.
    param([string]$Package, [string]$Target, [string]$Backup, [string]$Expect)
    $new = @(Get-RelFiles $Package)
    $old = @(Get-RelFiles $Target)
    $newTops = @($new | Where-Object { $_ -match '[\\/]' } | ForEach-Object { ($_ -split '[\\/]')[0].ToLowerInvariant() } | Select-Object -Unique)
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    foreach ($rel in $old) { Copy-Rel $Target $Backup $rel }
    try {
        foreach ($rel in $new) { Copy-Rel $Package $Target $rel }
        foreach ($rel in $old) {
            if ($new -contains $rel -or $rel -notmatch '[\\/]') { continue }
            if ($newTops -contains ($rel -split '[\\/]')[0].ToLowerInvariant()) { Remove-Item -LiteralPath (Join-Path $Target $rel) -Force -ErrorAction SilentlyContinue }
        }
        if ($TestFailAfterCopy) { throw 'Test failure after copying.' }
        $check = Read-ModuleManifest -Folder $Target
        if (-not $check.Ok -or $check.Id -cne $Id -or $check.Version -ne $Expect) { throw "The updated module did not check out ($($check.Reason)). The previous version was put back." }
    } catch {
        foreach ($rel in $new) { if ($old -notcontains $rel) { Remove-Item -LiteralPath (Join-Path $Target $rel) -Force -ErrorAction SilentlyContinue } }
        foreach ($rel in $old) { Copy-Rel $Backup $Target $rel }
        Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
}

function Set-Progress { param([int]$Pct, [string]$Text) Write-Output ("##PROGRESS {0}|{1}" -f $Pct, $Text) }
function Write-Result {
    param([hashtable]$Result)
    $tmp = "$ResultFile.tmp"
    [IO.File]::WriteAllText($tmp, ($Result | ConvertTo-Json -Depth 4), $utf8)
    Move-Item -Path $tmp -Destination $ResultFile -Force
}
function Test-AllowedUrl {
    param([string]$Url)
    if ($AllowLocalTestUrls -and $Url -match '^http://127\.0\.0\.1:\d+/') { return $true }
    return ($Url -like "https://github.com/$Repo/releases/download/*")
}

function Save-Url {
    # Streams a URL to a file with progress. Follows GitHub's redirect to its download host.
    param([string]$Url, [string]$Dest, [long]$MaxBytes, [int]$PctFrom, [int]$PctTo, [string]$Label)
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'MediaLauncher-Installer'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        if ($total -gt $MaxBytes) { throw "The download is larger than expected ($total bytes)." }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($Dest)
        try {
            $buf = New-Object byte[] 65536
            $done = 0L; $last = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                if ($done -gt $MaxBytes) { throw 'The download is larger than expected.' }
                if ($total -gt 0) {
                    $pct = $PctFrom + [int](($PctTo - $PctFrom) * $done / $total)
                    if ($pct -ne $last) { $last = $pct; Set-Progress $pct ('{0} {1:N1} of {2:N1} MB' -f $Label, ($done / 1MB), ($total / 1MB)) }
                }
            }
        } finally { $out.Close(); $in.Close() }
    } finally { $resp.Close() }
}

function Expand-Safe {
    # Unpacks entry by entry. Rejects path tricks, too many files and oversized archives.
    param([string]$Zip, [string]$Dest)
    $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $count = 0; $bytes = 0L
        foreach ($e in $archive.Entries) {
            $name = $e.FullName
            if ($name -match '(^|[\\/])\.\.([\\/]|$)' -or $name -match '^[\\/]' -or $name -match ':') { throw "Unsafe path in the module package: $name" }
            $target = [IO.Path]::GetFullPath((Join-Path $Dest $name))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path in the module package: $name" }
            $count++; $bytes += $e.Length
            if ($count -gt 3000 -or $bytes -gt $MaxUnpackedBytes) { throw 'The module package is larger than expected.' }
            if ($name.EndsWith('/') -or $name.EndsWith('\')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            $dir = Split-Path $target
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $archive.Dispose() }
}

try {
    if ($Id -cnotmatch '^[a-z][a-z0-9]{1,19}$') { throw 'Bad module id.' }
    if ($DroppedZip) {
        if (-not (Test-Path -LiteralPath $DroppedZip -PathType Leaf)) { throw 'The dropped package is no longer there.' }
        if ((Get-Item -LiteralPath $DroppedZip).Length -gt $MaxZipBytes) { throw 'The dropped package is larger than expected.' }
        if (-not $FolderName -and -not $UpdateFolder) {
            # SampleModule-v0.15.0.zip -> SampleModule
            $FolderName = [IO.Path]::GetFileNameWithoutExtension($DroppedZip) -replace '[-_ ]?v?\d+\.\d+\.\d+.*$', ''
        }
    } else {
        if ($Repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { throw 'Bad repo name.' }
        if (-not (Test-AllowedUrl $ZipUrl) -or -not (Test-AllowedUrl $ShaUrl)) { throw "Refusing a download link that is not this module's GitHub release." }
    }
    $fromVersion = ''
    if ($UpdateFolder) {
        $target = [IO.Path]::GetFullPath($UpdateFolder).TrimEnd('\', '/')
        $have = Read-ModuleManifest -Folder $target
        if (-not $have.Ok -or $have.Id -cne $Id) { throw "The installed folder is not the $Id module, so it was not updated." }
        $fromVersion = $have.Version
    } else {
        if (-not $FolderName) { $FolderName = ($Repo -split '/')[1] }
        if ($FolderName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Bad folder name.' }
        if (-not (Test-Path -LiteralPath $ModulesDir -PathType Container)) { New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null }
        $target = Join-Path $ModulesDir $FolderName
        # never a second copy of a module that is already installed under another folder name
        foreach ($dir in @(Get-ChildItem -LiteralPath $ModulesDir -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') })) {
            $other = Read-ModuleManifest -Folder $dir.FullName
            if ($other.Ok -and $other.Id -ceq $Id) { throw "$Id is already installed in $($dir.Name), so nothing was installed. Update it instead." }
        }
        if (Test-Path -LiteralPath $target) {
            if (@(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue).Count) { throw "There is already a folder named $FolderName in the modules folder, so nothing was installed. Remove or rename it, then try again." }
            Remove-Item -LiteralPath $target -Force
        }
    }

    # download into a temporary folder inside modules, so the final step is a rename on the same drive
    if (-not (Test-Path -LiteralPath $ModulesDir -PathType Container)) { New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null }
    $staging = Join-Path $ModulesDir ($(if ($UpdateFolder) { '.updating-' } else { '.installing-' }) + $Id)
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $zipPath = Join-Path $staging 'package.zip'

    if ($DroppedZip) {
        Set-Progress 20 'Copying the package...'
        Copy-Item -LiteralPath $DroppedZip -Destination $zipPath -Force
        if (Test-Path -LiteralPath "$DroppedZip.sha256") {
            Set-Progress 60 'Checking it against its checksum...'
            $line = ([IO.File]::ReadAllText("$DroppedZip.sha256")).Trim()
            if ($line -notmatch '^([0-9a-fA-F]{64})\b') { throw 'The .sha256 file beside the package is not in the expected format.' }
            if ((Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1].ToLowerInvariant()) { throw 'The package does not match the .sha256 file beside it. Nothing was installed.' }
        }
    } else {
        Set-Progress 3 'Downloading the checksum...'
        Save-Url $ShaUrl "$zipPath.sha256" 4096 3 5 'Checksum'
        $line = ([IO.File]::ReadAllText("$zipPath.sha256")).Trim()
        if ($line -notmatch '^([0-9a-fA-F]{64})\b') { throw 'The published checksum file is not in the expected format.' }
        $expected = $Matches[1].ToLowerInvariant()

        Save-Url $ZipUrl $zipPath $MaxZipBytes 5 80 'Downloading'
        Set-Progress 82 'Checking the download...'
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw 'The download did not match its published checksum and was discarded. Nothing was installed.' }
    }

    Set-Progress 86 'Unpacking...'
    $unpack = Join-Path $staging 'files'
    New-Item -ItemType Directory -Path $unpack -Force | Out-Null
    Expand-Safe $zipPath $unpack
    # module.json at the root, or inside a single top folder
    $root = $unpack
    if (-not (Test-Path -LiteralPath (Join-Path $root 'module.json'))) {
        $dirs = @(Get-ChildItem -LiteralPath $unpack -Directory)
        $files = @(Get-ChildItem -LiteralPath $unpack -File)
        if ($dirs.Count -eq 1 -and $files.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $dirs[0].FullName 'module.json'))) { $root = $dirs[0].FullName }
        else { throw 'The module package has no module.json at its root, so it is not a MediaLauncher module.' }
    }

    Set-Progress 92 'Checking the module...'
    $info = Read-ModuleManifest -Folder $root
    if (-not $info.Ok) { throw "The module's module.json has a problem: $($info.Reason)" }
    if ($info.Id -cne $Id) { throw "The package is a different module (id '$($info.Id)', expected '$Id'). Nothing was installed." }
    # filter by extension: Windows PowerShell 5.1 ignores -Include when -LiteralPath is used
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { @('.ps1', '.psm1') -contains $_.Extension.ToLowerInvariant() })) {
        $errs = $null; $tokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        if ($errs -and $errs.Count) { throw "The module package has a damaged script ($($f.Name)). Nothing was installed." }
    }

    if ($UpdateFolder) {
        Set-Progress 95 'Replacing the files...'
        Update-InPlace -Package $root -Target $target -Backup (Join-Path $ModulesDir ('.backup-' + $Id)) -Expect $info.Version
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Set-Progress 100 'Updated'
        Write-Result @{ status = 'updated'; id = $Id; folder = $target; version = $info.Version; from = $fromVersion }
        exit 0
    }
    Set-Progress 97 'Putting it in place...'
    Move-Item -LiteralPath $root -Destination $target
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Set-Progress 100 'Installed'
    Write-Result @{ status = 'installed'; id = $Id; folder = $target; version = $info.Version }
    exit 0
} catch {
    if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    $msg = $_.Exception.Message
    if ($msg -match 'remote name could not be resolved|unable to connect|timed out|No such host') { $msg = 'Could not reach GitHub. Check the internet connection and try again.' }
    Write-Result @{ status = 'error'; id = $Id; error = $msg }
    exit 1
}
