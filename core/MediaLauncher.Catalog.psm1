<#
.SYNOPSIS
    The list of known modules (catalog.json) and whether each one is published on GitHub.
.DESCRIPTION
    Windows PowerShell 5.1. A module counts as published when its GitHub repo has a published release (drafts and
    pre-releases do not count) at or above the catalog's minVersion. When GitHub cannot be reached, the last answer seen
    is used, and failing that the catalog's own "published" switch decides. "published": true or false in catalog.json
    always wins, so a module can be enabled or hidden by hand.
    Get-ReleaseInfo is the only function here that uses the network; the launcher runs it in a background runspace.
#>

$script:IdPattern = '^[a-z][a-z0-9]{1,19}$'
$script:RepoPattern = '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$'

function ConvertTo-ModuleVersion {
    # 'v1.2.3' or '1.2.3' -> [version]; anything else -> $null
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($Text -match '^v?(\d+)\.(\d+)\.(\d+)$') { return [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]) }
    return $null
}

function Read-Catalog {
    <# Reads catalog.json. Invalid entries are skipped. Returns the entries as objects. #>
    param([Parameter(Mandatory)][string]$Path)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $out.ToArray() }
    try { $c = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $out.ToArray() }
    $seen = @{}
    foreach ($m in @($c.modules)) {
        if ($null -eq $m -or $m -isnot [pscustomobject]) { continue }
        $id = [string]$m.id
        if ($m.id -isnot [string] -or $id -cnotmatch $script:IdPattern -or $seen.ContainsKey($id)) { continue }
        if ($m.repo -isnot [string] -or $m.repo -notmatch $script:RepoPattern) { continue }
        if ($m.name -isnot [string] -or $m.name.Length -lt 1 -or $m.name.Length -gt 12) { continue }
        $title = if ($m.title -is [string] -and $m.title.Length -ge 1 -and $m.title.Length -le 60) { $m.title } else { $m.name }
        $minV = $null
        if ($null -ne $m.minVersion) { $minV = ConvertTo-ModuleVersion ([string]$m.minVersion); if (-not $minV) { continue } }
        $pub = $null
        if ($m.published -is [bool]) { $pub = $m.published }
        $icon = ''
        if ($m.icon -is [string] -and $m.icon -match '^[A-Za-z0-9._/-]+\.(svg|png)$' -and $m.icon -notmatch '\.\.') { $icon = $m.icon }
        $seen[$id] = $true
        $out.Add([pscustomobject]@{ Id = $id; Name = $m.name; Title = $title; Repo = $m.repo; MinVersion = $minV; Published = $pub; Icon = $icon })
    }
    return $out.ToArray()
}

function Get-ReleaseInfo {
    <#
    .SYNOPSIS  Asks GitHub for each repo's latest published release. One request per repo, 10 second timeout.
    .OUTPUTS   One object per repo: Repo, Status ('published' | 'none' | 'error'), Tag, Url, Asset, AssetName, Sha, PublishedAt, Error.
    #>
    param([string[]]$Repos)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    foreach ($repo in @($Repos)) {
        $r = [pscustomobject]@{ Repo = $repo; Status = 'error'; Tag = ''; Url = ''; Asset = ''; AssetName = ''; Sha = ''; PublishedAt = ''; Error = '' }
        if ($repo -notmatch $script:RepoPattern) { $r.Error = 'bad repo name'; $r; continue }
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -TimeoutSec 10 `
                -Headers @{ 'User-Agent' = 'MediaLauncher'; 'Accept' = 'application/vnd.github+json' }
            $r.Status = 'published'
            $r.Tag = [string]$rel.tag_name
            $r.Url = [string]$rel.html_url
            $r.PublishedAt = [string]$rel.published_at
            $zip = @($rel.assets | Where-Object { [string]$_.name -match '\.zip$' }) | Select-Object -First 1
            if ($zip) {
                $r.Asset = [string]$zip.browser_download_url; $r.AssetName = [string]$zip.name
                $sha = @($rel.assets | Where-Object { [string]$_.name -eq ([string]$zip.name + '.sha256') }) | Select-Object -First 1
                if ($sha) { $r.Sha = [string]$sha.browser_download_url }
            }
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -eq 404) { $r.Status = 'none' } else { $r.Status = 'error'; $r.Error = $_.Exception.Message }
        }
        $r
    }
}

function Resolve-CatalogEntry {
    <#
    .SYNOPSIS  Decides whether a catalog entry is shown as available, and where to download it.
    .PARAMETER Result  This run's Get-ReleaseInfo answer for the entry's repo, or $null if none.
    .PARAMETER Cached  The last good answer saved from an earlier run, or $null.
    .OUTPUTS   Show, Source ('manual' | 'github' | 'cache' | 'fallback'), Version, Url, Asset, AssetName, Sha, PublishedAt, Reason
    #>
    param([Parameter(Mandatory)]$Entry, $Result, $Cached)
    $page = "https://github.com/$($Entry.Repo)/releases/latest"
    $o = [pscustomobject]@{ Show = $false; Source = ''; Version = ''; Url = $page; Asset = ''; AssetName = ''; Sha = ''; PublishedAt = ''; Reason = '' }
    $use = $null
    if ($Result -and $Result.Status -ne 'error') { $use = $Result; $o.Source = 'github' }
    elseif ($Cached -and $Cached.Status -ne 'error') { $use = $Cached; $o.Source = 'cache' }
    if ($use) {
        if ($use.Status -eq 'published') {
            $v = ConvertTo-ModuleVersion $use.Tag
            $o.Version = $(if ($v) { $v.ToString() } else { [string]$use.Tag })
            if ($use.Url -like "https://github.com/$($Entry.Repo)/*") { $o.Url = $use.Url }
            if ($use.Asset -like "https://github.com/$($Entry.Repo)/releases/download/*") {
                $o.Asset = $use.Asset; $o.AssetName = $use.AssetName
                if ([string]$use.Sha -like "https://github.com/$($Entry.Repo)/releases/download/*") { $o.Sha = [string]$use.Sha }
                else { $o.Sha = $o.Asset + '.sha256' }          # the release workflows publish <zip>.sha256 beside the zip
            }
            $o.PublishedAt = $use.PublishedAt
            if ($Entry.MinVersion -and (-not $v -or $v -lt $Entry.MinVersion)) { $o.Reason = "latest release is older than $($Entry.MinVersion)" }
            else { $o.Show = $true }
        } else { $o.Reason = 'no published release' }
    } else {
        $o.Source = 'fallback'
        $o.Reason = 'GitHub could not be reached'
    }
    # the catalog's own switch always wins: true enables, false hides
    if ($Entry.Published -eq $true) { $o.Show = $true; $o.Source = 'manual' }
    elseif ($Entry.Published -eq $false) { $o.Show = $false; $o.Source = 'manual'; $o.Reason = 'hidden in catalog.json' }
    return $o
}

Export-ModuleMember -Function ConvertTo-ModuleVersion, Read-Catalog, Get-ReleaseInfo, Resolve-CatalogEntry
