$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$clipwarp = Join-Path $root 'clipwarp.ps1'
$failures = 0
$engine = (Get-Process -Id $PID).Path
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { $script:failures++; Write-Host "FAIL: $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red }
    else { Write-Host "PASS: $Name" -ForegroundColor Green }
}
function Invoke-ClipwarpExitCode([string]$Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $engine
    $start.Arguments = '-NoProfile -File "' + $clipwarp + '" ' + $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    [void]$process.StandardOutput.ReadToEnd(); [void]$process.StandardError.ReadToEnd()
    $process.WaitForExit(); $code = $process.ExitCode; $process.Dispose(); $code
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-cli-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $originalUserProfile = $env:USERPROFILE
    $env:USERPROFILE = $temp
    & $engine -NoProfile -File $clipwarp calendar status *> $null
    Assert-Equal 0 $LASTEXITCODE 'calendar status is a safe successful command'
    & $engine -NoProfile -File $clipwarp calendar image-details status *> $null
    Assert-Equal 0 $LASTEXITCODE 'calendar image-details status is a safe successful command'
    & $engine -NoProfile -File $clipwarp calendar duration status *> $null
    Assert-Equal 0 $LASTEXITCODE 'calendar duration status is a safe successful command'
    Assert-Equal $true ((Invoke-ClipwarpExitCode 'calendar duration 0') -ne 0) 'calendar duration rejects an out-of-range value'

    $images = Join-Path $temp 'images'
    New-Item -ItemType Directory -Path $images | Out-Null
    & $engine -NoProfile -File $clipwarp history -OutDir $images *> $null
    Assert-Equal 0 $LASTEXITCODE 'history is a safe successful command'
    & $engine -NoProfile -File $clipwarp clean -OutDir $images -Before '2000-01-01' *> $null
    Assert-Equal 0 $LASTEXITCODE 'clean accepts an empty managed test directory'
    & $engine -NoProfile -File $clipwarp target status *> $null
    Assert-Equal 0 $LASTEXITCODE 'target status is a safe successful command'
    & $engine -NoProfile -File $clipwarp doctor -OutDir $images *> $null
    Assert-Equal 0 $LASTEXITCODE 'doctor is a safe successful command'

    $timedPath = Join-Path $temp 'timed.ics'
    $output = & $clipwarp calendar export -Title 'Review 2026-09-15 14:30-15:45' -Details 'Agenda' -Path $timedPath -TimeZone 'SE Asia Standard Time' 2>&1
    Assert-Equal 0 $LASTEXITCODE 'calendar export timed path exits successfully'
    $timedIcs = [IO.File]::ReadAllText($timedPath)
    Assert-Equal $true $timedIcs.Contains("SUMMARY:Review`r`n") 'calendar export parses the title before writing ICS'
    Assert-Equal $true $timedIcs.Contains("DTSTART;TZID=Asia/Bangkok:20260915T143000`r`nDTEND;TZID=Asia/Bangkok:20260915T154500") 'calendar export passes explicit range and timezone to ICS'

    $datedPath = Join-Path $temp 'dated.ics'
    & $clipwarp calendar export -Title 'Holiday 2026-09-20' -Path $datedPath *> $null
    Assert-Equal 0 $LASTEXITCODE 'calendar export all-day path exits successfully'
    Assert-Equal $true ([IO.File]::ReadAllText($datedPath).Contains("SUMMARY:Holiday`r`nDTSTART;VALUE=DATE:20260920")) 'calendar export retains explicit date-only all-day fallback'

    Assert-Equal $true ((Invoke-ClipwarpExitCode ('calendar export -Path "' + (Join-Path $temp 'missing.ics') + '"')) -ne 0) 'calendar export rejects a missing title'
    Assert-Equal 1 (Invoke-ClipwarpExitCode 'calendar nonsense') 'calendar rejects an unknown action with usage status'
    Assert-Equal 0 (Invoke-ClipwarpExitCode 'help') 'help is a safe successful command'
} finally {
    $env:USERPROFILE = $originalUserProfile
    Remove-Item -LiteralPath $temp -Recurse -Force
}

if ($failures) { throw "$failures CLI test(s) failed" }
Write-Host 'All CLI tests passed.' -ForegroundColor Cyan
