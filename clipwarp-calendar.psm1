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
        [datetime]$LocalDate = ((Get-Date).Date.AddDays(1)),
        [Nullable[datetime]]$Start,
        [Nullable[datetime]]$End,
        [AllowEmptyString()][string]$Details,
        [string]$TimeZone,
        [AllowEmptyString()][string]$Location
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
    if (-not [string]::IsNullOrWhiteSpace($Location)) {
        $baseUrl += '&location=' + [Uri]::EscapeDataString($Location.Trim())
    }
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

    # 1. Detect Location / Meeting URLs (Zoom, Google Meet, Teams, Webex)
    $location = $null
    $urlRegex = '(?<url>https?://(?:(?:[a-zA-Z0-9-]+\.)?zoom\.us/[^\s"''<>]+|meet\.google\.com/[^\s"''<>]+|teams\.(?:microsoft|live)\.com/[^\s"''<>]+|[a-zA-Z0-9-]+\.webex\.com/[^\s"''<>]+))'
    $urlMatch = [regex]::Match($trimmed, $urlRegex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $work = $trimmed
    if ($urlMatch.Success) {
        $location = $urlMatch.Groups['url'].Value.TrimEnd('.,;:!?)')
        $work = ($work.Remove($urlMatch.Index, $urlMatch.Length))
    }

    # 2. Date parsing
    $hasExplicitDate = $false
    $parsedDate = $LocalDate.Date

    # 2a. Tomorrow / พรุ่งนี้
    $tmrwMatch = [regex]::Match($work, '(?:พรุ่งนี้|\b(?:tomorrow|tmrw)\b)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($tmrwMatch.Success) {
        $hasExplicitDate = $true
        $parsedDate = $LocalDate.Date.AddDays(1)
        $work = $work.Remove($tmrwMatch.Index, $tmrwMatch.Length)
    }

    # 2b. ISO Date: YYYY-MM-DD
    if (-not $hasExplicitDate) {
        $isoMatch = [regex]::Match($work, '(?<!\d)(?<year>\d{4})-(?<month>0[1-9]|1[0-2])-(?<day>0[1-9]|[12]\d|3[01])(?!\d)')
        if ($isoMatch.Success) {
            $hasExplicitDate = $true
            $parsedDate = [datetime]::new([int]$isoMatch.Groups['year'].Value, [int]$isoMatch.Groups['month'].Value, [int]$isoMatch.Groups['day'].Value, 0, 0, 0, [DateTimeKind]::Local)
            $work = $work.Remove($isoMatch.Index, $isoMatch.Length)
        }
    }

    # 2c. Thai Date: e.g. 15 ก.ย. 2569, 15 กันยายน 2569, 15 ก.ย. 69
    if (-not $hasExplicitDate) {
        $thaiMonths = @{
            'ม.ค.'=1; 'มค'=1; 'มกราคม'=1; 'ก.พ.'=2; 'กพ'=2; 'กุมภาพันธ์'=2
            'มี.ค.'=3; 'มีค'=3; 'มีนาคม'=3; 'เม.ย.'=4; 'เมย'=4; 'เมษายน'=4
            'พ.ค.'=5; 'พค'=5; 'พฤษภาคม'=5; 'มิ.ย.'=6; 'มิย'=6; 'มิถุนายน'=6
            'ก.ค.'=7; 'กค'=7; 'กรกฎาคม'=7; 'ส.ค.'=8; 'สค'=8; 'สิงหาคม'=8
            'ก.ย.'=9; 'กย'=9; 'กันยายน'=9; 'ต.ค.'=10; 'ตค'=10; 'ตุลาคม'=10
            'พ.ย.'=11; 'พย'=11; 'พฤศจิกายน'=11; 'ธ.ค.'=12; 'ธค'=12; 'ธันวาคม'=12
        }
        $thaiDatePattern = '(?<!\d)(?<day>0?[1-9]|[12]\d|3[01])\s*(?<month>ม\.ค\.|ก\.พ\.|มี\.ค\.|เม\.ย\.|พ\.ค\.|มิ\.ย\.|ก\.ค\.|ส\.ค\.|ก\.ย\.|ต\.ค\.|พ\.ย\.|ธ\.ค\.|มกราคม|กุมภาพันธ์|มีนาคม|เมษายน|พฤษภาคม|มิถุนายน|กรกฎาคม|สิงหาคม|กันยายน|ตุลาคม|พฤศจิกายน|ธันวาคม|มค|กพ|มีค|เมย|พค|มิย|กค|สค|กย|ตค|พย|ธค)\.?\s*(?<year>\d{4}|\d{2})?(?!\d)'
        $thaiMatch = [regex]::Match($work, $thaiDatePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($thaiMatch.Success) {
            $day = [int]$thaiMatch.Groups['day'].Value
            $mKey = $thaiMatch.Groups['month'].Value
            $month = $thaiMonths[$mKey]
            $year = $LocalDate.Year
            if ($thaiMatch.Groups['year'].Success) {
                $yVal = [int]$thaiMatch.Groups['year'].Value
                if ($thaiMatch.Groups['year'].Value.Length -eq 4) {
                    $year = if ($yVal -ge 2400) { $yVal - 543 } else { $yVal }
                } elseif ($thaiMatch.Groups['year'].Value.Length -eq 2) {
                    $year = if ($yVal -ge 50) { 2500 + $yVal - 543 } else { 2000 + $yVal }
                }
            }
            try {
                $parsedDate = [datetime]::new($year, $month, $day, 0, 0, 0, [DateTimeKind]::Local)
                $hasExplicitDate = $true
                $work = $work.Remove($thaiMatch.Index, $thaiMatch.Length)
            } catch {}
        }
    }

    # 2d. DD/MM/YYYY or DD-MM-YYYY
    if (-not $hasExplicitDate) {
        $dmyMatch = [regex]::Match($work, '(?<!\d)(?<day>0?[1-9]|[12]\d|3[01])[\/\-\.](?<month>0?[1-9]|1[0-2])[\/\-\.](?<year>\d{4}|\d{2})(?!\d)')
        if ($dmyMatch.Success) {
            $day = [int]$dmyMatch.Groups['day'].Value
            $month = [int]$dmyMatch.Groups['month'].Value
            $yVal = [int]$dmyMatch.Groups['year'].Value
            $year = if ($dmyMatch.Groups['year'].Value.Length -eq 4) {
                if ($yVal -ge 2400) { $yVal - 543 } else { $yVal }
            } else {
                if ($yVal -ge 50) { 2500 + $yVal - 543 } else { 2000 + $yVal }
            }
            try {
                $parsedDate = [datetime]::new($year, $month, $day, 0, 0, 0, [DateTimeKind]::Local)
                $hasExplicitDate = $true
                $work = $work.Remove($dmyMatch.Index, $dmyMatch.Length)
            } catch {}
        }
    }

    # 3. Time parsing
    $hasTime = $false
    $start = $null
    $end = $null

    # 3a. 12-hour Range: e.g. 10:00 AM - 11:30 AM, 10 - 11:30 AM, 2:00 PM - 3:30 PM
    $t12rPattern = '(?<!\d)(?<shour>1[0-2]|0?[1-9])(?::(?<smin>[0-5]\d))?\s*(?<sampm>[AaPp][Mm])?\s*(?:[-–—]|to|ถึง)\s*(?<ehour>1[0-2]|0?[1-9])(?::(?<emin>[0-5]\d))?\s*(?<eampm>[AaPp][Mm])(?!\w)'
    $t12r = [regex]::Match($work, $t12rPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($t12r.Success) {
        $sh = [int]$t12r.Groups['shour'].Value
        $sm = if ($t12r.Groups['smin'].Success) { [int]$t12r.Groups['smin'].Value } else { 0 }
        $eh = [int]$t12r.Groups['ehour'].Value
        $em = if ($t12r.Groups['emin'].Success) { [int]$t12r.Groups['emin'].Value } else { 0 }
        $eampm = $t12r.Groups['eampm'].Value.ToUpperInvariant()
        $sampm = if ($t12r.Groups['sampm'].Success) { $t12r.Groups['sampm'].Value.ToUpperInvariant() } else { $eampm }
        if ($sampm -eq 'PM' -and $sh -lt 12) { $sh += 12 } elseif ($sampm -eq 'AM' -and $sh -eq 12) { $sh = 0 }
        if ($eampm -eq 'PM' -and $eh -lt 12) { $eh += 12 } elseif ($eampm -eq 'AM' -and $eh -eq 12) { $eh = 0 }
        $targetDate = if ($hasExplicitDate) { $parsedDate } else { $LocalDate.Date.AddDays(1) }
        $startCandidate = $targetDate.AddHours($sh).AddMinutes($sm)
        $endCandidate = $targetDate.AddHours($eh).AddMinutes($em)
        if ($endCandidate -gt $startCandidate) {
            $hasTime = $true
            $start = $startCandidate
            $end = $endCandidate
            $work = $work.Remove($t12r.Index, $t12r.Length)
        } else {
            return [pscustomobject]@{ Title=$trimmed; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$LocalDate.Date; Location=$location }
        }
    }

    # 3b. 24-hour Range: e.g. 14:00-15:30, 14.00 - 15.30 น.
    if (-not $hasTime) {
        $t24rPattern = '(?<!\d)(?<shour>[01]\d|2[0-3])[:.](?<smin>[0-5]\d)\s*(?:น\.?)?\s*(?:[-–—]|to|ถึง)\s*(?<ehour>[01]\d|2[0-3])[:.](?<emin>[0-5]\d)(?:\s*น\.?)?(?!\d)'
        $t24r = [regex]::Match($work, $t24rPattern)
        if ($t24r.Success) {
            $sh = [int]$t24r.Groups['shour'].Value
            $sm = [int]$t24r.Groups['smin'].Value
            $eh = [int]$t24r.Groups['ehour'].Value
            $em = [int]$t24r.Groups['emin'].Value
            $targetDate = if ($hasExplicitDate) { $parsedDate } else { $LocalDate.Date.AddDays(1) }
            $startCandidate = $targetDate.AddHours($sh).AddMinutes($sm)
            $endCandidate = $targetDate.AddHours($eh).AddMinutes($em)
            if ($endCandidate -gt $startCandidate) {
                $hasTime = $true
                $start = $startCandidate
                $end = $endCandidate
                $work = $work.Remove($t24r.Index, $t24r.Length)
            } else {
                return [pscustomobject]@{ Title=$trimmed; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$LocalDate.Date; Location=$location }
            }
        }
    }

    # 3c. 12-hour Single: e.g. 2:30 PM, 10 AM, 11:45 am
    if (-not $hasTime) {
        $t12sPattern = '(?<!\d)(?<hour>1[0-2]|0?[1-9])(?::(?<min>[0-5]\d))?\s*(?<ampm>[AaPp][Mm])(?!\w)'
        $t12s = [regex]::Match($work, $t12sPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($t12s.Success) {
            $h = [int]$t12s.Groups['hour'].Value
            $m = if ($t12s.Groups['min'].Success) { [int]$t12s.Groups['min'].Value } else { 0 }
            $ampm = $t12s.Groups['ampm'].Value.ToUpperInvariant()
            if ($ampm -eq 'PM' -and $h -lt 12) { $h += 12 } elseif ($ampm -eq 'AM' -and $h -eq 12) { $h = 0 }
            $targetDate = if ($hasExplicitDate) { $parsedDate } else { $LocalDate.Date.AddDays(1) }
            $hasTime = $true
            $start = $targetDate.AddHours($h).AddMinutes($m)
            $end = $start.AddMinutes($DefaultDurationMinutes)
            $work = $work.Remove($t12s.Index, $t12s.Length)
        }
    }

    # 3d. 24-hour Single: e.g. 14:30, 14:30 น., 14.30 น.
    if (-not $hasTime) {
        $t24sPattern = '(?<!\d)(?:(?<hour>[01]\d|2[0-3]):(?<min>[0-5]\d)(?:\s*น\.?)?|(?<hour>[01]\d|2[0-3])\.(?<min>[0-5]\d)\s*น\.?)(?!\d)'
        $t24s = [regex]::Match($work, $t24sPattern)
        if ($t24s.Success) {
            $h = [int]$t24s.Groups['hour'].Value
            $m = [int]$t24s.Groups['min'].Value
            $targetDate = if ($hasExplicitDate) { $parsedDate } else { $LocalDate.Date.AddDays(1) }
            $hasTime = $true
            $start = $targetDate.AddHours($h).AddMinutes($m)
            $end = $start.AddMinutes($DefaultDurationMinutes)
            $work = $work.Remove($t24s.Index, $t24s.Length)
        }
    }

    # 4. Clean title
    $title = ($work -replace '\s+', ' ') -replace '^[\s\-–—,:]+|[\s\-–—,:]+$', ''
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $trimmed
    }

    if ($hasTime) {
        return [pscustomobject]@{ Title=$title; OriginalText=$Text; IsTimed=$true; Start=$start; End=$end; LocalDate=$targetDate; Location=$location }
    } elseif ($hasExplicitDate) {
        return [pscustomobject]@{ Title=$title; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$parsedDate; Location=$location }
    } else {
        return [pscustomobject]@{ Title=$trimmed; OriginalText=$Text; IsTimed=$false; Start=$null; End=$null; LocalDate=$LocalDate.Date.AddDays(1); Location=$location }
    }
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
    $text = if ($Event.IsTimed) {
        "$title - $($Event.Start.ToString('yyyy-MM-dd HH:mm', $culture))-$($Event.End.ToString('HH:mm', $culture))"
    } else {
        "$title - $($Event.LocalDate.ToString('yyyy-MM-dd', $culture)) (all day)"
    }
    if ($Event.Location) {
        $loc = [string]$Event.Location
        if ($loc.Length -gt 35) { $loc = $loc.Substring(0, 32) + '...' }
        $text += " [$loc]"
    }
    return $text
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
    param([Parameter(Mandatory=$true)][string]$Title, [string]$Details, [datetime]$LocalDate=((Get-Date).Date.AddDays(1)), [Nullable[datetime]]$Start, [Nullable[datetime]]$End, [string]$TimeZone, [string]$Uid=([guid]::NewGuid().ToString('N')+'@clipwarp.local'), [datetime]$CreatedUtc=[datetime]::UtcNow, [string]$Path, [AllowEmptyString()][string]$Location)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $lines = @('BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//clipwarp//Calendar Event//EN','CALSCALE:GREGORIAN','BEGIN:VEVENT',('UID:'+ (ConvertTo-ClipwarpIcsText $Uid)),('DTSTAMP:'+$CreatedUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssZ', $culture)),('SUMMARY:'+(ConvertTo-ClipwarpIcsText $Title)))
    if ($Location) { $lines += 'LOCATION:' + (ConvertTo-ClipwarpIcsText $Location) }
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

function Get-ClipwarpCommandText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    $clean = $Text.Trim()
    $clean = $clean -replace '^(?:PS\s+[A-Za-z]:\\[^>]*>|PS\s*>|[A-Za-z]:\\[^>]*>|\$\s+|>\s*|#\s+)', ''
    $clean.Trim()
}

function Test-ClipwarpCommandLine {
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $cmd = Get-ClipwarpCommandText -Text $Text
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }

    $firstLine = ($cmd -split "`r?`n")[0].Trim()
    if ([string]::IsNullOrWhiteSpace($firstLine)) { return $false }

    # 1. PowerShell Verb-Noun Cmdlet (e.g. Get-Process, Install-Module, Set-ExecutionPolicy)
    if ($firstLine -match '^(?:[A-Za-z]+-[A-Za-z0-9]+)(?:\s+.*|$)$') { return $true }

    # 2. Variable assignment or script invocation ($var = ..., $var += ..., & "...", .\script.ps1)
    if ($firstLine -match '^(?:\$[A-Za-z0-9_:]+\s*[-+]?=|&\s+["'']?|\.\\[A-Za-z0-9_-]+)') { return $true }

    # 3. Known CLI tools & commands
    $knownCli = @(
        'git', 'gh', 'npm', 'pnpm', 'yarn', 'bun', 'npx',
        'docker', 'docker-compose', 'kubectl', 'helm',
        'pip', 'pip3', 'python', 'python3', 'py', 'node', 'deno',
        'cargo', 'rustc', 'go', 'dotnet', 'javac', 'java',
        'winget', 'choco', 'scoop',
        'powershell', 'pwsh', 'cmd', 'wsl', 'bash', 'sh',
        'irm', 'iwr', 'iex', 'icm',
        'curl', 'wget', 'ssh', 'scp', 'ping', 'tracert', 'ipconfig', 'netstat', 'nslookup',
        'dir', 'ls', 'cd', 'cat', 'type', 'mkdir', 'rmdir', 'del', 'rm', 'cp', 'mv', 'echo',
        'cls', 'clear', 'findstr', 'grep', 'tasklist', 'taskkill', 'code'
    )
    $pattern = '^(?:' + (($knownCli | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?:\.exe)?(?:\s+.*|$)'
    if ($firstLine -match $pattern) { return $true }

    # 4. Pipelines or redirects
    if ($firstLine -match '\s+\|\s+' -or $firstLine -match '\s+>>?\s+') { return $true }

    # 5. Command with CLI flag patterns (e.g. command with -v, --help, -Force)
    if ($firstLine -match '^\w+(?:\.\w+)?\s+(?:--?[a-zA-Z0-9_-]+)') { return $true }

    return $false
}

function Start-ClipwarpCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandText,
        [string]$WorkingDirectory = $env:USERPROFILE
    )

    $clean = Get-ClipwarpCommandText -Text $CommandText
    if ([string]::IsNullOrWhiteSpace($clean)) { return }

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($clean)
    $b64 = [Convert]::ToBase64String($bytes)

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'wt.exe'
        $psi.Arguments = "-d `"$WorkingDirectory`" powershell.exe -NoExit -ExecutionPolicy Bypass -EncodedCommand $b64"
        $psi.UseShellExecute = $true
        try {
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            return
        } catch { }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoExit -ExecutionPolicy Bypass -EncodedCommand $b64"
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

Export-ModuleMember -Function Get-ClipwarpPayloadKind, Format-ClipwarpCalendarPayload, Get-ClipwarpCalendarTimeZone, New-ClipwarpCalendarUrl, ConvertFrom-ClipwarpCalendarText, Get-ClipwarpImageCalendarDetails, Get-ClipwarpCalendarPreview, Export-ClipwarpIcsEvent, Set-ClipwarpClipboardText, Get-ClipwarpPopupLocation, Get-ClipwarpPopupMetrics, New-ClipwarpCalendarPopupArguments, Start-ClipwarpCalendarPopup, Get-ClipwarpCommandText, Test-ClipwarpCommandLine, Start-ClipwarpCommand
