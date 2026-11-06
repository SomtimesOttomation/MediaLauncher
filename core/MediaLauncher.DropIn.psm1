<#
.SYNOPSIS
    Drop-in updates: tells what a zip dropped into MediaLauncher's updates folder is, without unpacking it.
.DESCRIPTION
    Windows PowerShell 5.1. Reads at most two small entries from the zip (module.json and its version file, or VERSION).
    A zip is either the MediaLauncher package (Start-MediaLauncher.ps1 and VERSION at its root, or inside one top folder) or a
    module (module.json at its root, or inside one top folder). Anything else is 'unknown'.
#>

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Read-ZipText {
    param($Archive, [string]$Name, [int]$MaxBytes = 65536)
    $e = $Archive.GetEntry($Name)
    if (-not $e) { $e = @($Archive.Entries | Where-Object { $_.FullName -eq $Name.Replace('/', '\') }) | Select-Object -First 1 }
    if (-not $e -or $e.Length -gt $MaxBytes) { return $null }
    $sr = New-Object IO.StreamReader($e.Open())
    try { return $sr.ReadToEnd() } finally { $sr.Close() }
}

function Get-DropInfo {
    <#
    .OUTPUTS  Kind ('launcher' | 'module' | 'unknown'), Id, Name, Version, Top (the single top folder or ''), Reason
    #>
    param([Parameter(Mandatory)][string]$Path)
    $o = [pscustomobject]@{ Kind = 'unknown'; Id = ''; Name = ''; Version = ''; Top = ''; Reason = '' }
    $zip = $null
    try { $zip = [IO.Compression.ZipFile]::OpenRead($Path) } catch { $o.Reason = 'It is not a zip file that can be opened.'; return $o }
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        $tops = @($names | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
        $prefixes = @('')
        if ($tops.Count -eq 1 -and @($names | Where-Object { $_ -match '/' }).Count) { $prefixes += ($tops[0] + '/'); $o.Top = $tops[0] }
        foreach ($pre in $prefixes) {
            if ($names -contains ($pre + 'module.json')) {
                $m = $null
                try { $m = (Read-ZipText $zip ($pre + 'module.json')) | ConvertFrom-Json } catch { }
                if (-not $m -or [string]$m.id -cnotmatch '^[a-z][a-z0-9]{1,19}$') { $o.Reason = 'Its module.json could not be read.'; return $o }
                $o.Id = [string]$m.id; $o.Name = [string]$m.name
                $vf = [string]$m.versionFile
                if ($vf -and $vf -notmatch '\.\.' -and $vf -notmatch '^[\\/]|:') { $o.Version = ([string](Read-ZipText $zip ($pre + $vf.Replace('\', '/')))).Trim() }
                if ($o.Version -notmatch '^\d+\.\d+\.\d+$') { $o.Reason = 'Its version file could not be read.'; $o.Version = ''; return $o }
                $o.Kind = 'module'
                if ($pre -eq '') { $o.Top = '' }
                return $o
            }
            if ($names -contains ($pre + 'Start-MediaLauncher.ps1') -and $names -contains ($pre + 'VERSION')) {
                $v = ([string](Read-ZipText $zip ($pre + 'VERSION'))).Trim()
                if ($v -notmatch '^\d+\.\d+\.\d+$') { $o.Reason = 'Its VERSION file could not be read.'; return $o }
                $o.Kind = 'launcher'; $o.Id = 'launcher'; $o.Name = 'MediaLauncher'; $o.Version = $v
                if ($pre -eq '') { $o.Top = '' }
                return $o
            }
        }
        $o.Reason = 'It is not a MediaLauncher or module package.'
        return $o
    } finally { $zip.Dispose() }
}

Export-ModuleMember -Function Get-DropInfo
