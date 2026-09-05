$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-support.psm1') -Force

$failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { $script:failures++; Write-Host "FAIL: $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red }
    else { Write-Host "PASS: $Name" -ForegroundColor Green }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $config = Join-Path $temp 'clipwarp.json'
    Assert-Equal $true (Get-ClipwarpCalendarEnabled -ConfigPath $config) 'missing config preserves enabled default'
    [IO.File]::WriteAllText($config, '{broken', [Text.Encoding]::UTF8)
    Assert-Equal $true (Get-ClipwarpCalendarEnabled -ConfigPath $config) 'corrupt config safely preserves enabled default'
    [void](Set-ClipwarpCalendarEnabled -Enabled $false -ConfigPath $config)
    Assert-Equal $false (Get-ClipwarpCalendarEnabled -ConfigPath $config) 'calendar can be disabled persistently'
    [void](Set-ClipwarpCalendarEnabled -Enabled $true -ConfigPath $config)
    Assert-Equal $true (Get-ClipwarpCalendarEnabled -ConfigPath $config) 'calendar can be re-enabled persistently'
    [void](Set-ClipwarpCalendarImageDetails -Mode Filename -ConfigPath $config)
    Assert-Equal 'Filename' (Get-ClipwarpCalendarImageDetails -ConfigPath $config) 'image-details filename mode persists'
    [void](Set-ClipwarpCalendarDefaultDuration -Minutes 45 -ConfigPath $config)
    Assert-Equal 45 (Get-ClipwarpCalendarDefaultDuration -ConfigPath $config) 'default duration persists'
    Assert-Equal $true (Get-ClipwarpCalendarEnabled -ConfigPath $config) 'config updates preserve calendar enabled setting'

    $titles = Join-Path $temp 'titles'; New-Item -ItemType Directory -Path $titles | Out-Null
    $oldTitle = Join-Path $titles 'clipwarp-title-11111111111111111111111111111111.txt'
    $newTitle = Join-Path $titles 'clipwarp-title-22222222222222222222222222222222.txt'
    $unrelatedTitle = Join-Path $titles 'notes.txt'
    [IO.File]::WriteAllText($oldTitle, 'old'); [IO.File]::WriteAllText($newTitle, 'new'); [IO.File]::WriteAllText($unrelatedTitle, 'keep')
    (Get-Item $oldTitle).LastWriteTimeUtc = [datetime]'2026-01-01Z'; (Get-Item $newTitle).LastWriteTimeUtc = [datetime]'2026-01-03Z'
    $cleanup = Clear-ClipwarpCalendarTitleFiles -Directory $titles -BeforeUtc ([datetime]'2026-01-02Z') -MaximumFiles 10
    Assert-Equal 1 $cleanup.RemovedCount 'orphan cleanup removes only old managed title files'
    Assert-Equal $true (Test-Path -LiteralPath $unrelatedTitle) 'orphan cleanup never deletes arbitrary files'
    Assert-Equal $true (Test-Path -LiteralPath $newTitle) 'orphan cleanup preserves recent managed title files'

    $out = Join-Path $temp 'images'; New-Item -ItemType Directory -Path $out | Out-Null
    foreach ($name in @('clip-20260101-000000-000.png','clip-20260103-000000-000.jpg','clip-20260102-000000-000.gif','unrelated.png')) {
        [IO.File]::WriteAllBytes((Join-Path $out $name), [byte[]](1,2,3))
    }
    (Get-Item (Join-Path $out 'clip-20260101-000000-000.png')).LastWriteTime = [datetime]'2026-01-01'
    (Get-Item (Join-Path $out 'clip-20260102-000000-000.gif')).LastWriteTime = [datetime]'2026-01-02'
    (Get-Item (Join-Path $out 'clip-20260103-000000-000.jpg')).LastWriteTime = [datetime]'2026-01-03'
    $history = @(Get-ClipwarpHistory -OutDir $out -Limit 2)
    Assert-Equal 2 $history.Count 'history output is bounded'
    Assert-Equal 'clip-20260103-000000-000.jpg' $history[0].Name 'history order is newest first'
    Assert-Equal 'clip-20260102-000000-000.gif' $history[1].Name 'history ordering is deterministic'
    Assert-Equal (Join-Path $out 'clip-20260103-000000-000.jpg') (Get-ClipwarpRecopyTarget -OutDir $out).FullName 'recopy defaults to newest managed image'
    Assert-Equal (Join-Path $out 'clip-20260102-000000-000.gif') (Get-ClipwarpRecopyTarget -OutDir $out -Index 2).FullName 'recopy accepts a stable history index'
    $invalidIndex = $false; try { [void](Get-ClipwarpRecopyTarget -OutDir $out -Index 99) } catch { $invalidIndex = $true }
    Assert-Equal $true $invalidIndex 'recopy rejects an out-of-range history index'
    $outside = Join-Path $temp 'clip-outside.png'; [IO.File]::WriteAllBytes($outside, [byte[]](1))
    $rejected = $false; try { [void](Get-ClipwarpRecopyTarget -OutDir $out -Path $outside) } catch { $rejected = $true }
    Assert-Equal $true $rejected 'recopy rejects a path outside explicit OutDir'
    $removed = @(Clear-ClipwarpHistory -OutDir $out -Before ([datetime]'2026-01-02T12:00:00'))
    Assert-Equal 2 $removed.Count 'clean removes only matching files before cutoff'
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $out 'unrelated.png')) 'clean preserves unrelated files'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $out 'clip-20260101-000000-000.png')) 'clean removes old managed files'

    Assert-Equal 'auto' (Get-ClipwarpTargetMode -ConfigPath $config) 'missing config preserves targetMode default auto'
    Set-ClipwarpTargetMode -Mode chatgpt -ConfigPath $config | Out-Null
    Assert-Equal 'chatgpt' (Get-ClipwarpTargetMode -ConfigPath $config) 'targetMode persists chatgpt setting'
    Set-ClipwarpTargetMode -Mode auto -ConfigPath $config | Out-Null
    Assert-Equal 'auto' (Get-ClipwarpTargetMode -ConfigPath $config) 'targetMode persists auto setting'

    $doctor = @(Test-ClipwarpEnvironment -ScriptRoot $root -ConfigPath $config -OutDir $out -ProfilePaths @((Join-Path $temp 'missing-profile.ps1')) -StartupPath (Join-Path $temp 'missing.lnk') -PidPath (Join-Path $temp 'missing.pid'))
    Assert-Equal $true ($doctor.Count -ge 6) 'doctor returns a useful diagnostic set'
    Assert-Equal $false (($doctor | Where-Object Name -eq 'Repository URL').MutatesState) 'doctor diagnostics are explicitly read-only'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }

if ($failures) { throw "$failures management test(s) failed" }
Write-Host 'All management tests passed.' -ForegroundColor Cyan
