<#
.SYNOPSIS  Checks the module.json rules in core\MediaLauncher.Manifest.psm1. Run: powershell -File tests\Test-Manifest.ps1
.NOTES     Builds throwaway module folders under the temp folder and removes them afterwards. Exit code 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'core\MediaLauncher.Manifest.psm1') -Force

$script:Failed = 0
$script:Passed = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:Passed++ } else { $script:Failed++; Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('launcher-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function New-TestModule {
    param([string]$Name, [hashtable]$Override = @{}, [string[]]$Remove = @(), [string]$Version = '1.2.3')
    $d = Join-Path $tmp $Name
    foreach ($sub in 'ui', 'modules', (Join-Path 'ui' 'img')) { New-Item -ItemType Directory -Path (Join-Path $d $sub) -Force | Out-Null }
    Set-Content -Path (Join-Path $d 'VERSION') -Value $Version
    Set-Content -Path (Join-Path $d 'Start-Test.bat') -Value '@echo off'
    Set-Content -Path (Join-Path $d 'modules\Test.Host.psm1') -Value '# test'
    Set-Content -Path (Join-Path $d 'ui\index.html') -Value '<!doctype html>'
    Set-Content -Path (Join-Path $d 'ui\img\icon.svg') -Value '<svg/>'
    $m = [ordered]@{
        contract = 1; id = 'testmodule'; name = 'Test'; title = 'Test Module'; versionFile = 'VERSION'; icon = 'ui/img/icon.svg'
        backend = 'modules/Test.Host.psm1'; ui = 'ui'; entry = 'index.html'; standalone = 'Start-Test.bat'
    }
    foreach ($k in $Override.Keys) { $m[$k] = $Override[$k] }
    foreach ($k in $Remove) { $m.Remove($k) }
    Set-Content -Path (Join-Path $d 'module.json') -Value ($m | ConvertTo-Json -Depth 5)
    return $d
}

try {
    # --- relative paths
    foreach ($ok in 'ui', 'modules/A.Host.psm1', 'ui\img\x.svg', 'a..b/c.txt') { Check "relpath ok: $ok" (Test-ModuleRelPath $ok) }
    foreach ($bad in '', ' ', '..', '../x', '..\x', 'a/../b', 'ui/..', '/abs', '\abs', '\\srv\share', 'C:\x', 'c:x', 'a:b', 'x*y', 'a|b') {
        Check "relpath bad: '$bad'" (-not (Test-ModuleRelPath $bad))
    }

    # --- a good module
    $good = New-TestModule 'Good'
    $r = Read-ModuleManifest -Folder $good
    Check 'good module is ok' $r.Ok $r.Reason
    Check 'good module id' ($r.Id -eq 'testmodule')
    Check 'good module version' ($r.Version -eq '1.2.3')
    Check 'good module backend path is inside' ($r.Paths['backend'].StartsWith([IO.Path]::GetFullPath($good)))
    Check 'unknown fields are ignored' ((Read-ModuleManifest -Folder (New-TestModule 'Extra' @{ futureField = 'x' })).Ok)

    # --- each broken case: folder name, override, removed fields, version, expected words in the reason
    $cases = @(
        @{ N = 'NoContract';   R = @('contract');                    W = 'contract' },
        @{ N = 'Contract0';    O = @{ contract = 0 };                W = 'contract' },
        @{ N = 'ContractStr';  O = @{ contract = '1' };              W = 'contract' },
        @{ N = 'Contract2';    O = @{ contract = 2 };                W = 'newer MediaLauncher' },
        @{ N = 'IdUpper';      O = @{ id = 'ALPHA' };                  W = 'id' },
        @{ N = 'IdShort';      O = @{ id = 'n' };                    W = 'id' },
        @{ N = 'IdDigit';      O = @{ id = '1nba' };                 W = 'id' },
        @{ N = 'IdReserved';   O = @{ id = 'launcher' };             W = 'reserved' },
        @{ N = 'NameLong';     O = @{ name = 'Thirteen chars' };     W = 'name' },
        @{ N = 'TitleEmpty';   O = @{ title = '' };                  W = 'title' },
        @{ N = 'BackendUp';    O = @{ backend = '../evil.psm1' };    W = 'backend' },
        @{ N = 'BackendAbs';   O = @{ backend = 'C:\evil.psm1' };    W = 'backend' },
        @{ N = 'BackendUnc';   O = @{ backend = '\\srv\evil.psm1' }; W = 'backend' },
        @{ N = 'BackendType';  O = @{ backend = 'modules/x.ps1' };   W = 'wrong file type' },
        @{ N = 'BackendMiss';  O = @{ backend = 'modules/No.psm1' }; W = 'not found' },
        @{ N = 'IconType';     O = @{ icon = 'ui/img/icon.gif' };    W = 'wrong file type' },
        @{ N = 'UiMissing';    O = @{ ui = 'web' };                  W = 'not found' },
        @{ N = 'EntryUp';      O = @{ entry = '../module.json' };      W = 'entry' },
        @{ N = 'EntryMissing'; O = @{ entry = 'other.html' };        W = 'entry' },
        @{ N = 'BatType';      O = @{ standalone = 'Start.cmd' };    W = 'wrong file type' },
        @{ N = 'BadVersion';   V = 'v1';                             W = 'version' },
        @{ N = 'BadSource';    O = @{ dataSources = @(@{ name = 'X'; terms = 'http://x' }) }; W = 'dataSources' }
    )
    foreach ($c in $cases) {
        $o = if ($c.O) { $c.O } else { @{} }
        $rm = if ($c.R) { $c.R } else { @() }
        $v = if ($c.V) { $c.V } else { '1.2.3' }
        $res = Read-ModuleManifest -Folder (New-TestModule $c.N $o $rm $v)
        Check "broken: $($c.N)" ((-not $res.Ok) -and $res.Reason -like "*$($c.W)*") $res.Reason
    }

    # --- not JSON, missing file
    $nj = Join-Path $tmp 'NotJson'; New-Item -ItemType Directory -Path $nj | Out-Null; Set-Content (Join-Path $nj 'module.json') '{ nope'
    Check 'not json' (-not (Read-ModuleManifest -Folder $nj).Ok)
    $nf = Join-Path $tmp 'NoFile'; New-Item -ItemType Directory -Path $nf | Out-Null
    Check 'no module.json' (-not (Read-ModuleManifest -Folder $nf).Ok)

    # --- scanning: duplicates, exclusion, folders without module.json are skipped
    $scan = Join-Path $tmp 'scan'; New-Item -ItemType Directory -Path $scan | Out-Null
    $script:tmpSaved = $tmp; $tmp = $scan
    $a = New-TestModule 'A-First'
    $b = New-TestModule 'B-Second'
    $l = New-TestModule 'MediaLauncher' @{ id = 'other' }
    New-Item -ItemType Directory -Path (Join-Path $scan 'Plain') | Out-Null
    $tmp = $script:tmpSaved
    $found = @(Find-Modulees -ScanFolders @($scan) -Exclude @($l))
    Check 'scan finds two (launcher excluded, plain skipped)' ($found.Count -eq 2) "found $($found.Count)"
    Check 'first keeps the id' ($found[0].Ok -and $found[0].Folder -like '*A-First')
    Check 'duplicate id is broken' ((-not $found[1].Ok) -and $found[1].Reason -like '*already uses*') $found[1].Reason
    Check 'missing scan folder is ignored' (@(Find-Modulees -ScanFolders @((Join-Path $tmp 'nope'))).Count -eq 0)
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed) { exit 1 } else { exit 0 }
