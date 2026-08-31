$ErrorActionPreference = 'Stop'
$module = Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1'
Import-Module $module -Force

$failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) {
        $script:failures++
        Write-Host "FAIL: $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red
    } else { Write-Host "PASS: $Name" -ForegroundColor Green }
}

$date = [datetime]::new(2026, 8, 31, 22, 15, 0, [DateTimeKind]::Local)
$textUrl = New-ClipwarpCalendarUrl -Title 'Plan A & B / review' -LocalDate $date
Assert-Equal 'https://calendar.google.com/calendar/render?action=TEMPLATE&text=Plan%20A%20%26%20B%20%2F%20review&dates=20260831%2F20260901' $textUrl 'URL safely encodes title and uses exclusive next-day end'

$dstDate = [datetime]::new(2026, 3, 8, 1, 30, 0, [DateTimeKind]::Local)
$dstUrl = New-ClipwarpCalendarUrl -Title 'DST' -LocalDate $dstDate
Assert-Equal $true ($dstUrl.EndsWith('dates=20260308%2F20260309')) 'all-day dates use local calendar days across DST'

Assert-Equal 'Text' (Get-ClipwarpPayloadKind -Text "  Team sync `r`n") 'meaningful plain text is classified'
Assert-Equal 'None' (Get-ClipwarpPayloadKind -Text " `t`r`n") 'whitespace-only text is ignored'
Assert-Equal 'None' (Get-ClipwarpPayloadKind -Text 'C:\Temp\shot.png' -TextIsExistingImagePath $true) 'existing image path/self rewrite is ignored'
Assert-Equal 'Image' (Get-ClipwarpPayloadKind -HasImage $true) 'pure image is classified'
Assert-Equal 'Text' (Get-ClipwarpPayloadKind -Text 'caption' -HasImage $true) 'rich copy with meaningful text is treated as text'

if ($failures) { throw "$failures calendar test(s) failed" }
Write-Host 'All calendar tests passed.' -ForegroundColor Cyan
