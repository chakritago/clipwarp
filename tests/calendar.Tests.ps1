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

$below = Get-ClipwarpPopupLocation -PointerX 500 -PointerY 300 -PopupWidth 380 -PopupHeight 150 -WorkingLeft 0 -WorkingTop 0 -WorkingRight 1920 -WorkingBottom 1040
Assert-Equal 500 $below.X 'popup aligns with the event-time pointer x coordinate'
Assert-Equal 312 $below.Y 'popup opens directly below the pointer with a small gap'

$clamped = Get-ClipwarpPopupLocation -PointerX 1900 -PointerY 1000 -PopupWidth 380 -PopupHeight 150 -WorkingLeft 0 -WorkingTop 0 -WorkingRight 1920 -WorkingBottom 1040
Assert-Equal 1540 $clamped.X 'popup clamps to the monitor right edge'
Assert-Equal 838 $clamped.Y 'popup moves above the pointer with a gap when it cannot fit below'

$negativeMonitor = Get-ClipwarpPopupLocation -PointerX -1200 -PointerY 850 -PopupWidth 380 -PopupHeight 150 -WorkingLeft -1920 -WorkingTop 0 -WorkingRight 0 -WorkingBottom 1040
Assert-Equal -1200 $negativeMonitor.X 'popup supports monitors with negative coordinates'
Assert-Equal 862 $negativeMonitor.Y 'popup remains below the pointer inside a secondary monitor working area'

$upperMonitor = Get-ClipwarpPopupLocation -PointerX 200 -PointerY -880 -PopupWidth 400 -PopupHeight 156 -WorkingLeft 0 -WorkingTop -1080 -WorkingRight 1920 -WorkingBottom -40
Assert-Equal 200 $upperMonitor.X 'popup supports a monitor above the primary display'
Assert-Equal -868 $upperMonitor.Y 'popup uses the selected monitor working-area origin'

$oversized = Get-ClipwarpPopupLocation -PointerX -500 -PointerY -500 -PopupWidth 1400 -PopupHeight 1000 -WorkingLeft -1280 -WorkingTop -900 -WorkingRight 0 -WorkingBottom 0
Assert-Equal -1280 $oversized.X 'oversized popup anchors to the working-area left edge'
Assert-Equal -900 $oversized.Y 'oversized popup anchors to the working-area top edge'

$scaled = Get-ClipwarpPopupMetrics -Dpi 144
Assert-Equal 600 $scaled.Width '150 percent DPI scales popup width to physical pixels'
Assert-Equal 234 $scaled.Height '150 percent DPI scales popup height to physical pixels'
Assert-Equal 18 $scaled.Gap '150 percent DPI scales the cursor gap to physical pixels'

$popupArgs = New-ClipwarpCalendarPopupArguments -PopupPath 'C:\Program Files\clipwarp\popup.ps1' -Kind Image -Title 'Quarterly review' -ImagePath 'C:\shots\one image.png' -PointerX 321 -PointerY 654
Assert-Equal $true ($popupArgs -contains '-PointerX') 'popup arguments include captured pointer x'
Assert-Equal $true ($popupArgs -contains '321') 'popup arguments preserve pointer x value'
Assert-Equal $true ($popupArgs -contains '-PointerY') 'popup arguments include captured pointer y'
Assert-Equal $true ($popupArgs -contains '654') 'popup arguments preserve pointer y value'
Assert-Equal $true ($popupArgs -contains '-ImagePathBase64') 'image paths use a base64 argument instead of shell quoting'
Assert-Equal $false ($popupArgs -contains 'C:\shots\one image.png') 'raw image paths are not placed on the command line'

$fallbackArgs = New-ClipwarpCalendarPopupArguments -PopupPath 'C:\clipwarp\popup.ps1' -Kind Text -Title 'Agenda'
Assert-Equal $false ($fallbackArgs -contains '-PointerX') 'popup arguments omit coordinates when no event-time pointer was captured'
$nullPointerArgs = New-ClipwarpCalendarPopupArguments -PopupPath 'C:\clipwarp\popup.ps1' -Kind Text -Title 'Agenda' -PointerX $null -PointerY $null
Assert-Equal $false ($nullPointerArgs -contains '-PointerX') 'popup arguments preserve current-pointer fallback through the launcher'

if ($failures) { throw "$failures calendar test(s) failed" }
Write-Host 'All calendar tests passed.' -ForegroundColor Cyan
