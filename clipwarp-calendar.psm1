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

function Start-ClipwarpCalendarPopup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$ImagePath,
        [string]$ScriptRoot = $PSScriptRoot
    )
    $popup = Join-Path $ScriptRoot 'clipwarp-calendar-popup.ps1'
    if (-not (Test-Path -LiteralPath $popup)) { return }
    $titleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Title))
    $args = @('-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $popup + '"'), '-Kind', $Kind, '-TitleBase64', $titleBase64)
    if ($ImagePath) { $args += @('-ImagePath', ('"' + ($ImagePath -replace '"', '\"') + '"')) }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
}

Export-ModuleMember -Function Get-ClipwarpPayloadKind, New-ClipwarpCalendarUrl, Start-ClipwarpCalendarPopup
