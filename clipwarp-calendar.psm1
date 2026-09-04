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

function Format-ClipwarpCalendarPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [AllowEmptyString()][string]$Details,
        [ValidateRange(1, 1000)][int]$MaxTitleLength = 120,
        [ValidateRange(256, 8192)][int]$MaxUrlLength = 1900,
        [int]$UrlOverhead = 160
    )
    $original = $Title
    $clean = ($Title -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'Clipboard event' }
    $eventTitle = $clean
    if ($clean.Length -gt $MaxTitleLength) {
        $cut = $MaxTitleLength
        if ($cut -gt 0 -and $cut -lt $clean.Length -and [char]::IsHighSurrogate($clean[$cut - 1]) -and [char]::IsLowSurrogate($clean[$cut])) { $cut-- }
        $eventTitle = $clean.Substring(0, $cut).TrimEnd()
    }
    $isLongText = $clean.Length -gt $MaxTitleLength -or $original -match "`r|`n"
    $parts = @($Details, $(if ($isLongText) { $original })) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $eventDetails = ($parts -join "`n`n")
    [pscustomobject]@{ Title=$eventTitle; Details=if($eventDetails){$eventDetails}else{$null}; WasTruncated=($clean.Length -gt $MaxTitleLength) }
}

function Get-ClipwarpCalendarTimeZone {
    [CmdletBinding()]
    param([string]$TimeZoneId = [TimeZoneInfo]::Local.Id)
    if ([string]::IsNullOrWhiteSpace($TimeZoneId)) { return $null }
    if ($TimeZoneId -match '^[A-Za-z]+(?:[_+-][A-Za-z0-9]+)*(?:/[A-Za-z0-9_+-]+)+$') { return $TimeZoneId }
    $map = @{
        'Dateline Standard Time'='Etc/GMT+12'; 'UTC'='Etc/UTC'; 'Pacific Standard Time'='America/Los_Angeles'
        'Mountain Standard Time'='America/Denver'; 'Central Standard Time'='America/Chicago'; 'Eastern Standard Time'='America/New_York'
        'Atlantic Standard Time'='America/Halifax'; 'GMT Standard Time'='Europe/London'; 'W. Europe Standard Time'='Europe/Berlin'
        'Central Europe Standard Time'='Europe/Budapest'; 'Romance Standard Time'='Europe/Paris'; 'India Standard Time'='Asia/Kolkata'
        'SE Asia Standard Time'='Asia/Bangkok'; 'China Standard Time'='Asia/Shanghai'; 'Tokyo Standard Time'='Asia/Tokyo'; 'AUS Eastern Standard Time'='Australia/Sydney'
        'New Zealand Standard Time'='Pacific/Auckland'
    }
    if ($map.ContainsKey($TimeZoneId)) { $map[$TimeZoneId] } else { $null }
}

function New-ClipwarpCalendarUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [datetime]$LocalDate = (Get-Date),
        [Nullable[datetime]]$Start,
        [Nullable[datetime]]$End,
        [AllowEmptyString()][string]$Details,
        [string]$TimeZone
    )
    if ($PSBoundParameters.ContainsKey('Start')) {
        $startValue = [datetime]$Start
        $startText = $startValue.ToString('yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $endValue = if ($PSBoundParameters.ContainsKey('End') -and ([datetime]$End) -gt $startValue) { [datetime]$End } else { $startValue.AddHours(1) }
        $endText = $endValue.ToString('yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    } else {
        $startText = $LocalDate.Date.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
        $endText = $LocalDate.Date.AddDays(1).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    }
    $payload = Format-ClipwarpCalendarPayload -Title $Title -Details $Details -UrlOverhead 170
    $baseUrl = "https://calendar.google.com/calendar/render?action=TEMPLATE&text=$([Uri]::EscapeDataString($payload.Title))&dates=$startText%2F$endText"
    $suffix = ''
    if ($PSBoundParameters.ContainsKey('Start') -and $TimeZone) {
        $ctz = Get-ClipwarpCalendarTimeZone -TimeZoneId $TimeZone
        if ($ctz) { $suffix = '&ctz=' + [Uri]::EscapeDataString($ctz) }
    }
    $safeDetails = $payload.Details
    while ($safeDetails -and ($baseUrl.Length + 9 + [Uri]::EscapeDataString($safeDetails).Length + $suffix.Length) -gt 1900) {
        $remove = 1
        if ($safeDetails.Length -gt 1 -and [char]::IsLowSurrogate($safeDetails[$safeDetails.Length - 1]) -and [char]::IsHighSurrogate($safeDetails[$safeDetails.Length - 2])) { $remove = 2 }
        $safeDetails = $safeDetails.Substring(0,$safeDetails.Length-$remove).TrimEnd()
    }
    $baseUrl + $(if($safeDetails){'&details='+[Uri]::EscapeDataString($safeDetails)}else{''}) + $suffix
}

function ConvertFrom-ClipwarpCalendarText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text, [datetime]$LocalDate = (Get-Date), [ValidateRange(1,1440)][int]$DefaultDurationMinutes = 60)
    $trimmed = $Text.Trim()
    $m = [regex]::Match($trimmed, '(?<!\d)(?<date>\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01]))[ T](?<time>(?:[01]\d|2[0-3]):[0-5]\d)(?:-(?<end>(?:[01]\d|2[0-3]):[0-5]\d))?(?!\d)')
    if ($m.Success) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(($m.Groups['date'].Value + ' ' + $m.Groups['time'].Value), 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
            $title = ($trimmed.Remove($m.Index, $m.Length) -replace '^[\s\-–—,:]+|[\s\-–—,:]+$', '').Trim()
            if ([string]::IsNullOrWhiteSpace($title)) { $title = $trimmed }
            $end = $parsed.AddMinutes($DefaultDurationMinutes)
            if ($m.Groups['end'].Success) {
                $candidate = [datetime]::MinValue
                [void][datetime]::TryParseExact(($m.Groups['date'].Value + ' ' + $m.Groups['end'].Value), 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$candidate)
                if ($candidate -le $parsed) { return [pscustomobject]@{ Title=$trimmed; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$LocalDate.Date } }
                $end = $candidate
            }
            return [pscustomobject]@{ Title=$title; OriginalText=$Text; IsTimed=$true; Start=$parsed; End=$end }
        }
    }
    $dateMatch = [regex]::Match($trimmed, '(?<!\d)(?<date>\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01]))(?![\dT])')
    if ($dateMatch.Success) {
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParseExact($dateMatch.Groups['date'].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsedDate)) {
            $title = ($trimmed.Remove($dateMatch.Index, $dateMatch.Length) -replace '^[\s\-–—,:]+|[\s\-–—,:]+$', '').Trim()
            if ([string]::IsNullOrWhiteSpace($title)) { $title = $trimmed }
            return [pscustomobject]@{ Title=$title; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$parsedDate.Date }
        }
    }
    [pscustomobject]@{ Title=$trimmed; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$LocalDate.Date }
}

function Get-ClipwarpImageCalendarDetails {
    [CmdletBinding()]
    param([string]$ImagePath, [ValidateSet('Disabled','Filename','FullPath')][string]$Mode = 'Disabled')
    if (-not $ImagePath -or $Mode -eq 'Disabled') { return $null }
    $value = if ($Mode -eq 'Filename') { [IO.Path]::GetFileName($ImagePath) } else { $ImagePath }
    'Image file: ' + $value
}

function Get-ClipwarpCalendarPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Event, [ValidateRange(8,120)][int]$MaxTitleLength = 48)
    $title = [string]$Event.Title
    if ($title.Length -gt $MaxTitleLength) { $title = $title.Substring(0,$MaxTitleLength-1).TrimEnd() + [char]0x2026 }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Event.IsTimed) { return "$title - $($Event.Start.ToString('yyyy-MM-dd HH:mm', $culture))-$($Event.End.ToString('HH:mm', $culture))" }
    "$title - $($Event.LocalDate.ToString('yyyy-MM-dd', $culture)) (all day)"
}

function ConvertTo-ClipwarpIcsText([string]$Value) {
    if ($null -eq $Value) { return '' }
    (($Value -replace '\\','\\') -replace ';','\;' -replace ',','\,' -replace "`r?`n",'\n')
}

function ConvertTo-ClipwarpIcsFoldedLine([string]$Line) {
    $result = New-Object Collections.Generic.List[string]
    $current = ''; $limit = 75
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $length = 1
        if ([char]::IsHighSurrogate($Line[$index]) -and ($index + 1) -lt $Line.Length -and [char]::IsLowSurrogate($Line[$index + 1])) { $length = 2 }
        $part = $Line.Substring($index, $length)
        if ($length -eq 2) { $index++ }
        if ($current.Length -and [Text.Encoding]::UTF8.GetByteCount($current + $part) -gt $limit) {
            $result.Add($current); $current = ' '; $limit = 75
        }
        $current += $part
    }
    $result.Add($current)
    $result -join "`r`n"
}

function Export-ClipwarpIcsEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Title, [string]$Details, [datetime]$LocalDate=(Get-Date), [Nullable[datetime]]$Start, [Nullable[datetime]]$End, [string]$TimeZone, [string]$Uid=([guid]::NewGuid().ToString('N')+'@clipwarp.local'), [datetime]$CreatedUtc=[datetime]::UtcNow, [string]$Path)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $lines = @('BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//clipwarp//Calendar Event//EN','CALSCALE:GREGORIAN','BEGIN:VEVENT',('UID:'+ (ConvertTo-ClipwarpIcsText $Uid)),('DTSTAMP:'+$CreatedUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssZ', $culture)),('SUMMARY:'+(ConvertTo-ClipwarpIcsText $Title)))
    if ($Details) { $lines += 'DESCRIPTION:' + (ConvertTo-ClipwarpIcsText $Details) }
    if ($PSBoundParameters.ContainsKey('Start')) {
        $finish = if ($PSBoundParameters.ContainsKey('End') -and ([datetime]$End) -gt ([datetime]$Start)) {[datetime]$End}else{([datetime]$Start).AddHours(1)}
        $tz = Get-ClipwarpCalendarTimeZone -TimeZoneId $TimeZone
        $prefix = if($tz){';TZID='+$tz}else{''}
        $lines += 'DTSTART'+$prefix+':'+([datetime]$Start).ToString('yyyyMMddTHHmmss', $culture)
        $lines += 'DTEND'+$prefix+':'+$finish.ToString('yyyyMMddTHHmmss', $culture)
    } else {
        $lines += 'DTSTART;VALUE=DATE:'+$LocalDate.Date.ToString('yyyyMMdd', $culture)
        $lines += 'DTEND;VALUE=DATE:'+$LocalDate.Date.AddDays(1).ToString('yyyyMMdd', $culture)
    }
    $lines += @('END:VEVENT','END:VCALENDAR')
    $content = (($lines | ForEach-Object { ConvertTo-ClipwarpIcsFoldedLine $_ }) -join "`r`n")+"`r`n"
    if ($Path) { [IO.File]::WriteAllText($Path,$content,(New-Object Text.UTF8Encoding($false))); Get-Item -LiteralPath $Path } else { $content }
}

function Invoke-ClipwarpStaClipboardWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Value,
        [scriptblock]$Writer = { param($value); Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Clipboard]::SetText($value) }
    )
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $powershell = [powershell]::Create()
    try {
        $runspace.Open()
        $powershell.Runspace = $runspace
        [void]$powershell.AddScript("`$ErrorActionPreference = 'Stop'; & { $($Writer.ToString()) } `$args[0]").AddArgument($Value)
        [void]$powershell.Invoke()
        if ($powershell.HadErrors) {
            $failure = $powershell.Streams.Error | Select-Object -First 1
            throw "Clipboard write failed: $failure"
        }
    } finally {
        $powershell.Dispose()
        if ($runspace.RunspaceStateInfo.State -ne 'BeforeOpen') { $runspace.Close() }
        $runspace.Dispose()
    }
}

function Set-ClipwarpClipboardText {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Value, [scriptblock]$Writer)
    if ($Writer) { & $Writer $Value; return }
    Invoke-ClipwarpStaClipboardWrite -Value $Value
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
        [Nullable[int]]$PointerY,
        [string]$TransportDirectory = ([IO.Path]::GetTempPath()),
        [int]$FileThreshold = 6000
    )
    $arguments = @('-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PopupPath + '"'), '-Kind', $Kind)
    $titleBytes = [Text.Encoding]::UTF8.GetBytes($Title)
    if ($titleBytes.Length -gt $FileThreshold) {
        if (-not (Test-Path -LiteralPath $TransportDirectory)) { New-Item -ItemType Directory -Path $TransportDirectory -Force -ErrorAction Stop | Out-Null }
        $titleFile = Join-Path $TransportDirectory ('clipwarp-title-' + [guid]::NewGuid().ToString('N') + '.txt')
        try { [IO.File]::WriteAllText($titleFile, $Title, (New-Object Text.UTF8Encoding($false))) }
        catch { Remove-Item -LiteralPath $titleFile -Force -ErrorAction SilentlyContinue; throw }
        $titleFileBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($titleFile))
        $arguments += @('-TitleFileBase64', $titleFileBase64)
    } else {
        $arguments += @('-TitleBase64', [Convert]::ToBase64String($titleBytes))
    }
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
    if ($script:ClipwarpCalendarPopupProcess) {
        try { if (-not $script:ClipwarpCalendarPopupProcess.HasExited) { $script:ClipwarpCalendarPopupProcess.Kill(); [void]$script:ClipwarpCalendarPopupProcess.WaitForExit(1000) } } catch {}
        try { $script:ClipwarpCalendarPopupProcess.Dispose() } catch {}
        $script:ClipwarpCalendarPopupProcess = $null
    }
    $args = New-ClipwarpCalendarPopupArguments -PopupPath $popup -Kind $Kind -Title $Title -ImagePath $ImagePath -PointerX $PointerX -PointerY $PointerY
    try { $script:ClipwarpCalendarPopupProcess = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args -PassThru -ErrorAction Stop }
    catch {
        $fileIndex = [array]::IndexOf($args, '-TitleFile')
        if ($fileIndex -ge 0) {
            Remove-Item -LiteralPath $args[$fileIndex + 1] -Force -ErrorAction SilentlyContinue
        } else {
            $fileIndex = [array]::IndexOf($args, '-TitleFileBase64')
            if ($fileIndex -ge 0) {
                try { $titleFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($args[$fileIndex + 1])); Remove-Item -LiteralPath $titleFile -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        throw
    }
}

Export-ModuleMember -Function Get-ClipwarpPayloadKind, Format-ClipwarpCalendarPayload, Get-ClipwarpCalendarTimeZone, New-ClipwarpCalendarUrl, ConvertFrom-ClipwarpCalendarText, Get-ClipwarpImageCalendarDetails, Get-ClipwarpCalendarPreview, Export-ClipwarpIcsEvent, Set-ClipwarpClipboardText, Get-ClipwarpPopupLocation, Get-ClipwarpPopupMetrics, New-ClipwarpCalendarPopupArguments, Start-ClipwarpCalendarPopup
