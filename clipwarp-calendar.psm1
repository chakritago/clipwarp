function Get-ClipwarpPayloadKind {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [bool]$HasImage = $false,
        [bool]$TextIsExistingImagePath = $false
    )
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        if ($TextIsExistingImagePath) { return 'None' }
        return 'Text'
    }
    if ($HasImage) { return 'Image' }
    return 'None'
}

function New-ClipwarpCalendarUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [datetime]$LocalDate = (Get-Date)
    )
    $start = $LocalDate.Date.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    $end = $LocalDate.Date.AddDays(1).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    $encodedTitle = [Uri]::EscapeDataString($Title)
    "https://calendar.google.com/calendar/render?action=TEMPLATE&text=$encodedTitle&dates=$start%2F$end"
}

function Get-ClipwarpPopupLocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$PointerX,
        [Parameter(Mandatory = $true)][int]$PointerY,
        [Parameter(Mandatory = $true)][int]$PopupWidth,
        [Parameter(Mandatory = $true)][int]$PopupHeight,
        [Parameter(Mandatory = $true)][int]$WorkingLeft,
        [Parameter(Mandatory = $true)][int]$WorkingTop,
        [Parameter(Mandatory = $true)][int]$WorkingRight,
        [Parameter(Mandatory = $true)][int]$WorkingBottom,
        [int]$Gap = 12
    )
    $maxX = [Math]::Max($WorkingLeft, $WorkingRight - $PopupWidth)
    $maxY = [Math]::Max($WorkingTop, $WorkingBottom - $PopupHeight)
    $x = [Math]::Max($WorkingLeft, [Math]::Min($PointerX, $maxX))
    $below = $PointerY + [Math]::Max(0, $Gap)
    $y = if (($below + $PopupHeight) -le $WorkingBottom) {
        $below
    } else {
        $PointerY - [Math]::Max(0, $Gap) - $PopupHeight
    }
    $y = [Math]::Max($WorkingTop, [Math]::Min($y, $maxY))
    [pscustomobject]@{ X = [int]$x; Y = [int]$y }
}

function Get-ClipwarpPopupMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateRange(48, 768)][int]$Dpi)

    $scale = $Dpi / 96.0
    [pscustomobject]@{
        Width         = [int][Math]::Round(400 * $scale)
        Height        = [int][Math]::Round(156 * $scale)
        Gap           = [int][Math]::Round(12 * $scale)
        Padding       = [int][Math]::Round(20 * $scale)
        HeadingTop    = [int][Math]::Round(16 * $scale)
        HeadingHeight = [int][Math]::Round(25 * $scale)
        MessageTop    = [int][Math]::Round(47 * $scale)
        MessageHeight = [int][Math]::Round(44 * $scale)
        ButtonTop     = [int][Math]::Round(105 * $scale)
        ButtonHeight  = [int][Math]::Round(35 * $scale)
        CloseSize     = [int][Math]::Round(28 * $scale)
    }
}

function New-ClipwarpCalendarPopupArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PopupPath,
        [Parameter(Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$ImagePath,
        [Nullable[int]]$PointerX,
        [Nullable[int]]$PointerY
    )
    $titleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Title))
    $arguments = @('-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PopupPath + '"'), '-Kind', $Kind, '-TitleBase64', $titleBase64)
    if ($ImagePath) {
        $imageBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ImagePath))
        $arguments += @('-ImagePathBase64', $imageBase64)
    }
    if ($null -ne $PointerX -and $null -ne $PointerY) {
        $arguments += @('-PointerX', [Convert]::ToString($PointerX, [Globalization.CultureInfo]::InvariantCulture), '-PointerY', [Convert]::ToString($PointerY, [Globalization.CultureInfo]::InvariantCulture))
    }
    $arguments
}

function Start-ClipwarpCalendarPopup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$ImagePath,
        [Nullable[int]]$PointerX,
        [Nullable[int]]$PointerY,
        [string]$ScriptRoot = $PSScriptRoot
    )
    $popup = Join-Path $ScriptRoot 'clipwarp-calendar-popup.ps1'
    if (-not (Test-Path -LiteralPath $popup)) { return }
    $args = New-ClipwarpCalendarPopupArguments -PopupPath $popup -Kind $Kind -Title $Title -ImagePath $ImagePath -PointerX $PointerX -PointerY $PointerY
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
}

Export-ModuleMember -Function Get-ClipwarpPayloadKind, New-ClipwarpCalendarUrl, Get-ClipwarpPopupLocation, Get-ClipwarpPopupMetrics, New-ClipwarpCalendarPopupArguments, Start-ClipwarpCalendarPopup
