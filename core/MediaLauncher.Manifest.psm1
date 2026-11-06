<#
.SYNOPSIS
    Finds module folders and checks their module.json against MediaLauncher's module contract.
.DESCRIPTION
    Windows PowerShell 5.1. A manifest is untrusted input: nothing here loads or runs a module's code, it only reads
    module.json and checks that every path stays inside the module folder and exists. The rules match MODULE-CONTRACT.md and
    schema\module.schema.json. Unknown fields are ignored, so optional fields added later do not break this launcher.
#>

$script:SupportedContract = 1
$script:RelPathPattern = '^(?![\\/])(?![A-Za-z]:)(?!.*(^|[\\/])\.\.([\\/]|$))[^:*?"<>|]+$'
$script:IdPattern = '^[a-z][a-z0-9]{1,19}$'
$script:Reserved = @('launcher')
$script:MaxManifestBytes = 65536

function Test-ModuleRelPath {
    <# True when $Rel is a relative path that cannot leave the module folder. #>
    param([AllowEmptyString()][AllowNull()][string]$Rel)
    if ([string]::IsNullOrWhiteSpace($Rel) -or $Rel.Length -gt 200) { return $false }
    return [bool]($Rel -match $script:RelPathPattern)
}

function Resolve-ModulePath {
    <# Joins a checked relative path to the module folder and confirms the result is still inside it. Returns $null if not. #>
    param([string]$Folder, [string]$Rel)
    $sep = [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Folder ($Rel -replace '[\\/]', $sep)))
    $base = [IO.Path]::GetFullPath($Folder).TrimEnd('\', '/') + $sep
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

function New-ModuleRecord {
    param([string]$Folder)
    return [pscustomobject]@{
        Ok = $false; Reason = ''; Folder = $Folder; Id = ''; Name = ''; Title = ''; Version = ''; Contract = 0
        Entry = ''; Paths = @{}; DataSources = @()
    }
}

function Read-ModuleManifest {
    <#
    .SYNOPSIS  Reads and checks one module folder's module.json. Always returns a record; Ok is $false with a Reason when it fails.
    #>
    param([Parameter(Mandatory)][string]$Folder)
    $r = New-ModuleRecord -Folder $Folder
    $file = Join-Path $Folder 'module.json'
    try {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $r.Reason = 'No module.json in this folder.'; return $r }
        if ((Get-Item -LiteralPath $file).Length -gt $script:MaxManifestBytes) { $r.Reason = 'module.json is larger than 64 KB.'; return $r }
        try { $m = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { $r.Reason = 'module.json is not valid JSON.'; return $r }
        if ($null -eq $m -or $m -isnot [pscustomobject]) { $r.Reason = 'module.json must hold one JSON object.'; return $r }

        # contract
        $c = $m.contract
        if ($null -eq $c -or -not ($c -is [int] -or $c -is [long]) -or $c -lt 1) { $r.Reason = '"contract" must be a whole number of 1 or more.'; return $r }
        $r.Contract = [int]$c
        if ($r.Contract -gt $script:SupportedContract) { $r.Reason = "Needs a newer MediaLauncher (module contract $($r.Contract); this launcher supports $script:SupportedContract)."; return $r }

        # id, name, title
        $id = [string]$m.id
        if ($m.id -isnot [string] -or $id -cnotmatch $script:IdPattern) { $r.Reason = '"id" must be 2 to 20 lowercase letters or digits, starting with a letter.'; return $r }
        if ($script:Reserved -contains $id) { $r.Reason = "The id `"$id`" is reserved."; return $r }
        $r.Id = $id
        if ($m.name -isnot [string] -or $m.name.Length -lt 1 -or $m.name.Length -gt 12) { $r.Reason = '"name" must be 1 to 12 characters.'; return $r }
        $r.Name = $m.name
        if ($m.title -isnot [string] -or $m.title.Length -lt 1 -or $m.title.Length -gt 60) { $r.Reason = '"title" must be 1 to 60 characters.'; return $r }
        $r.Title = $m.title

        # paths: field, required extension, file or folder
        $specs = @(
            @{ Key = 'versionFile'; Ext = '';               Kind = 'Leaf' },
            @{ Key = 'icon';        Ext = '\.(svg|png)$';   Kind = 'Leaf' },
            @{ Key = 'backend';     Ext = '\.psm1$';        Kind = 'Leaf' },
            @{ Key = 'ui';          Ext = '';               Kind = 'Container' },
            @{ Key = 'standalone';  Ext = '\.bat$';         Kind = 'Leaf' }
        )
        foreach ($s in $specs) {
            $rel = $m.($s.Key)
            if ($rel -isnot [string] -or -not (Test-ModuleRelPath $rel)) { $r.Reason = "`"$($s.Key)`" must be a relative path inside the module folder."; return $r }
            if ($s.Ext -and $rel -notmatch $s.Ext) { $r.Reason = "`"$($s.Key)`" has the wrong file type ($rel)."; return $r }
            $full = Resolve-ModulePath -Folder $Folder -Rel $rel
            if (-not $full) { $r.Reason = "`"$($s.Key)`" points outside the module folder."; return $r }
            if (-not (Test-Path -LiteralPath $full -PathType $s.Kind)) { $r.Reason = "`"$($s.Key)`" not found: $rel"; return $r }
            $r.Paths[$s.Key] = $full
        }

        # entry is a page inside ui
        $entry = $m.entry
        if ($entry -isnot [string] -or -not (Test-ModuleRelPath $entry) -or $entry -notmatch '\.html?$') { $r.Reason = '"entry" must be an .html file inside the ui folder.'; return $r }
        $entryFull = Resolve-ModulePath -Folder $r.Paths['ui'] -Rel $entry
        if (-not $entryFull -or -not (Test-Path -LiteralPath $entryFull -PathType Leaf)) { $r.Reason = "`"entry`" not found in the ui folder: $entry"; return $r }
        $r.Entry = ($entry -replace '\\', '/')

        # version
        $v = ''
        try { $v = ([IO.File]::ReadAllText($r.Paths['versionFile'])).Trim() } catch { }
        if ($v -notmatch '^\d+\.\d+\.\d+$') { $r.Reason = 'The version file must hold a version like 1.2.3.'; return $r }
        $r.Version = $v

        # optional data sources
        if ($null -ne $m.dataSources) {
            $list = @($m.dataSources)
            if ($list.Count -gt 20) { $r.Reason = '"dataSources" lists more than 20 sources.'; return $r }
            $out = @()
            foreach ($d in $list) {
                if ($d -isnot [pscustomobject] -or $d.name -isnot [string] -or $d.name.Length -lt 1 -or $d.name.Length -gt 80 -or $d.terms -isnot [string] -or $d.terms -notmatch '^https://\S+$') {
                    $r.Reason = 'Each "dataSources" entry needs a name (1 to 80 characters) and an https:// terms link.'; return $r
                }
                $out += [pscustomobject]@{ name = $d.name; terms = $d.terms }
            }
            $r.DataSources = $out
        }
        $r.Ok = $true
    } catch {
        $r.Ok = $false
        $r.Reason = "Could not read module.json: $($_.Exception.Message)"
    }
    return $r
}

function Find-Modulees {
    <#
    .SYNOPSIS  Looks one level deep in each scan folder for subfolders with a module.json. Returns one record per folder found.
    .PARAMETER Exclude  Folders to skip (the launcher's own folder).
    #>
    param([string[]]$ScanFolders, [string[]]$Exclude = @())
    $skip = @($Exclude | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') })
    $seenFolders = @{}
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($scan in @($ScanFolders)) {
        if (-not $scan -or -not (Test-Path -LiteralPath $scan -PathType Container)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $scan -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($dir.Name.StartsWith('.')) { continue }                 # .installing-<id>: an install in progress
            $full = $dir.FullName.TrimEnd('\', '/')
            if ($skip -contains $full -or $seenFolders.ContainsKey($full.ToLowerInvariant())) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $full 'module.json') -PathType Leaf)) { continue }
            $seenFolders[$full.ToLowerInvariant()] = $true
            $records.Add((Read-ModuleManifest -Folder $full))
        }
    }
    # the first folder (by scan order, then name) keeps an id; later ones with the same id are broken
    $ids = @{}
    foreach ($r in $records) {
        if (-not $r.Ok) { continue }
        if ($ids.ContainsKey($r.Id)) { $r.Ok = $false; $r.Reason = "Another module already uses the id `"$($r.Id)`" ($($ids[$r.Id]))." }
        else { $ids[$r.Id] = $r.Folder }
    }
    return $records.ToArray()      # unrolled: callers wrap the call in @()
}

Export-ModuleMember -Function Test-ModuleRelPath, Resolve-ModulePath, Read-ModuleManifest, Find-Modulees
