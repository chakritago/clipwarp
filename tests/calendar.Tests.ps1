$ErrorActionPreference = 'Stop'
$module = Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1'
Import-Module $module -Force
$root = Split-Path $PSScriptRoot -Parent

$failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) {
        $script:failures++
        Write-Host "FAIL: $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red
    } else { Write-Host "PASS: $Name" -ForegroundColor Green }
}

$popupPath = Join-Path $root 'clipwarp-calendar-popup.ps1'
$popupTokens = $null
$popupErrors = $null
$popupAst = [Management.Automation.Language.Parser]::ParseFile($popupPath, [ref]$popupTokens, [ref]$popupErrors)
Assert-Equal 0 $popupErrors.Count 'calendar popup script parses without errors'
$timeoutParameter = @($popupAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutSeconds' })[0]
Assert-Equal 3 ([int]$timeoutParameter.DefaultValue.SafeGetValue()) 'text and image popups default to a 3-second timeout'
$acceptRunAssignments = @($popupAst.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true) |
    Where-Object { $_.Left.Extent.Text -match 'AcceptButton' -and $_.Right.Extent.Text -match 'runButton' })
Assert-Equal 0 $acceptRunAssignments.Count 'command popup source does not assign runButton as AcceptButton'
$acceptCalAssignments = @($popupAst.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true) |
    Where-Object { $_.Left.Extent.Text -match 'AcceptButton' -and $_.Right.Extent.Text -match 'calButton' })
Assert-Equal 1 $acceptCalAssignments.Count 'calendar popup source preserves calButton as AcceptButton for non-command text'
$runClickHandler = @($popupAst.FindAll({ $args[0] -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
    Where-Object { $_.Expression.Extent.Text.Trim() -eq '$runButton' -and $_.Member.Extent.Text -eq 'Add_MouseClick' -and $_.Extent.Text -match 'Start-ClipwarpCommand' })
Assert-Equal 1 $runClickHandler.Count 'command popup source retains explicit runButton click handler'

$date = [datetime]::new(2026, 8, 31, 22, 15, 0, [DateTimeKind]::Local)
# Inspect source only: never start the watcher or access the system clipboard.
$watchSource = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-watch.ps1'))
$rawTextBranch = 'string meaningful = txt\.Trim\(\);\s*if \(meaningful\.Length > 0\)\s*\{\s*if \(meaningful == lastTextFingerprint && \(DateTime\.Now - lastTextAt\)\.TotalSeconds < 2\)\s*\{ lastHandledSequence = sequence; return; \}\s*LaunchTextPopup\(txt\);\s*lastTextFingerprint = meaningful;'
Assert-Equal $true ($watchSource -match $rawTextBranch) 'watcher passes raw txt to popup while retaining trimmed empty and fingerprint checks'
Assert-Equal $false ($watchSource -match 'LaunchTextPopup\(meaningful\)') 'watcher never sends normalized text to popup'

$rawCalendarText = " `t`r`nReview 2026-09-15 14:30`r`n`r`n  "
$rawEvent = ConvertFrom-ClipwarpCalendarText -Text $rawCalendarText -LocalDate $date
$trimmedEvent = ConvertFrom-ClipwarpCalendarText -Text $rawCalendarText.Trim() -LocalDate $date
foreach ($property in @('Title', 'IsTimed', 'Start', 'End', 'LocalDate', 'Location')) {
    Assert-Equal $trimmedEvent.$property $rawEvent.$property "raw calendar whitespace preserves parsed $property"
}
Assert-Equal $rawCalendarText $rawEvent.OriginalText 'calendar parsing retains raw surrounding whitespace and blank lines'
Assert-Equal $false (Test-ClipwarpCommandLine -Text $rawCalendarText) 'raw calendar text remains non-command text'
$rawCommandText = " `t`r`nPS C:\Users\Test> npm test`r`n`r`n  "
Assert-Equal $true (Test-ClipwarpCommandLine -Text $rawCommandText) 'command detection accepts raw surrounding whitespace and blank lines'
Assert-Equal 'npm test' (Get-ClipwarpCommandText -Text $rawCommandText) 'raw command cleanup still strips whitespace and prompt'
Assert-Equal $false (Test-ClipwarpCommandLine -Text " `t`r`n`r`n ") 'raw blank lines do not become a command'

# Handoff tests use injected operations only: no browser or system clipboard.
$temporaryUrl = 'https://chatgpt.com/?temporary-chat=true'
Assert-Equal $temporaryUrl (New-ClipwarpChatGptUrl) 'ChatGPT URL is exactly the temporary chat URL'
$handoffText = "  PS C:\Users\Test> echo 'hello'`r`nReview 2026-09-15 14:30`n" + ([string][char]0x4F60) * 5000 + '` & ?q=secret C:\private\image.png  '
$handoffCalls = New-Object Collections.Generic.List[object]
Start-ClipwarpChatGptHandoff -Message $handoffText -ClipboardWriter {
    param($value) $handoffCalls.Add([pscustomobject]@{ Kind='clipboard'; Value=$value })
} -BrowserStarter {
    param($value) $handoffCalls.Add([pscustomobject]@{ Kind='browser'; Value=$value })
} -PageWaiter { param($url) $handoffCalls.Add([pscustomobject]@{ Kind='wait'; Value=$url }); 'verified-page' } -Submitter {
    param($page, $message) $handoffCalls.Add([pscustomobject]@{ Kind='submit'; Value=$message; Page=$page })
}
Assert-Equal 4 $handoffCalls.Count 'handoff writes and opens exactly once'
Assert-Equal 'clipboard' $handoffCalls[0].Kind 'handoff writes before opening browser'
Assert-Equal $handoffText $handoffCalls[0].Value 'handoff preserves full multiline Unicode text and whitespace'
Assert-Equal 'browser' $handoffCalls[1].Kind 'handoff opens browser after writing'
Assert-Equal $temporaryUrl $handoffCalls[1].Value 'browser URL leaks neither message nor local image path'
Assert-Equal 'wait' $handoffCalls[2].Kind 'wait follows browser launch'
Assert-Equal $temporaryUrl $handoffCalls[2].Value 'wait targets exact temporary URL'
Assert-Equal 'submit' $handoffCalls[3].Kind 'submit follows verified page wait'
Assert-Equal 'verified-page' $handoffCalls[3].Page 'submit receives identified page'
Assert-Equal $handoffText $handoffCalls[3].Value 'submit preserves exact original message'
foreach ($stage in @('clipboard','browser','wait','submit')) {
    $order = New-Object Collections.Generic.List[string]
    try {
        Start-ClipwarpChatGptHandoff -Message $handoffText -ClipboardWriter { $order.Add('clipboard'); if ($stage -eq 'clipboard') { throw 'stop' } } -BrowserStarter { $order.Add('browser'); if ($stage -eq 'browser') { throw 'stop' } } -PageWaiter { $order.Add('wait'); if ($stage -eq 'wait') { throw 'stop' }; 'page' } -Submitter { $order.Add('submit'); throw 'stop' }
        throw 'Expected failure'
    } catch { Assert-Equal 'stop' $_.Exception.Message 'operation failure propagates' }
    $expected = @('clipboard','browser','wait','submit')
    Assert-Equal ($expected[0..([array]::IndexOf($expected,$stage))] -join ',') ($order -join ',') 'failure prevents all later actions'
}
$browserAfterFailure = New-Object Collections.Generic.List[string]
try {
    Start-ClipwarpChatGptHandoff -Message 'test' -ClipboardWriter { throw 'injected write failure' } -BrowserStarter { param($value) $browserAfterFailure.Add($value) }
    throw 'Expected injected write failure'
} catch { Assert-Equal 'injected write failure' $_.Exception.Message 'clipboard failure propagates' }
Assert-Equal 0 $browserAfterFailure.Count 'failed clipboard write does not open browser'

$chatHandler = @($popupAst.FindAll({ $args[0] -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
    Where-Object { $_.Expression.Extent.Text -eq '$chatGptButton' -and $_.Member.Extent.Text -eq 'Add_Click' })
Assert-Equal 1 $chatHandler.Count 'text popup has an explicit ChatGPT click handler'
$textBranch = $chatHandler[0].Parent
while ($textBranch -and $textBranch -isnot [Management.Automation.Language.IfStatementAst]) { $textBranch = $textBranch.Parent }
Assert-Equal '$Kind -eq ''Text''' $textBranch.Clauses[0].Item1.Extent.Text 'ChatGPT button is restricted to text popup'
$popupSource = [IO.File]::ReadAllText($popupPath)
Assert-Equal $true ($popupSource.Contains('$chatGptButton.Text = ''Open ChatGPT && Send (Temporary)''')) 'ChatGPT button has visible label'
Assert-Equal $true ($popupSource.Contains('$chatGptButton.AccessibleName = ''Open ChatGPT & Send (Temporary)''')) 'ChatGPT button has accessible name'
Assert-Equal $true ($popupSource.Contains('Sends full text to ChatGPT or Gemini Spark.')) 'popup explains automatic submission'
Assert-Equal $false ($popupSource -match 'AcceptButton\s*=\s*\$chatGptButton') 'handoff is not the form default action'
# Execute the actual extracted handler with a fake form and injected helper wrapper.
& {
    $Title = $handoffText
    $form = [pscustomobject]@{ Closed=$false }
    $form | Add-Member ScriptMethod Close { $this.Closed = $true }
    $calls = New-Object Collections.Generic.List[string]
    function Start-ClipwarpChatGptHandoff {
        param($Message)
        clipwarp-calendar\Start-ClipwarpChatGptHandoff -Message $Message -ClipboardWriter { param($value) $calls.Add($value) } -BrowserStarter { param($value) $calls.Add($value) } -PageWaiter { 'page' } -Submitter { param($page,$message) $calls.Add($message) }
    }
    & ([scriptblock]::Create($chatHandler[0].Arguments[0].ScriptBlock.Extent.Text.Trim().Substring(1).TrimEnd('}')))
    Assert-Equal 3 $calls.Count 'actual popup handler invokes injected handoff once'
    Assert-Equal $Title $calls[0] 'actual popup handler passes full original Title'
    Assert-Equal $temporaryUrl $calls[1] 'actual popup handler opens only temporary URL'
    Assert-Equal $Title $calls[2] 'actual popup handler submits original Title'
    Assert-Equal $true $form.Closed 'actual popup handler closes popup after handoff'
}
$moduleSource = [IO.File]::ReadAllText($module)
Assert-Equal $false (($popupSource + $moduleSource) -match '(?i)Invoke-WebRequest|Invoke-RestMethod') 'popup and handoff contain no HTTP submission'
Assert-Equal $true ($moduleSource.Contains('ClipwarpChatGptNative')) 'calendar module defines native automation helper'
Assert-Equal $true ($moduleSource.Contains('SendPasteAndEnter')) 'calendar module provides paste and enter submission'
Assert-Equal $true ($popupSource.Contains('[Windows.Forms.MessageBox]::Show')) 'handoff errors are user-visible'
Assert-Equal '239,187,191' (([IO.File]::ReadAllBytes($module))[0..2] -join ',') 'calendar module retains UTF-8 BOM for Windows PowerShell'

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
Assert-Equal $false ($popupArgs -contains '-TimeoutSeconds') 'image launcher inherits the popup timeout default'
Assert-Equal $true ($popupArgs -contains '-PointerX') 'popup arguments include captured pointer x'
Assert-Equal $true ($popupArgs -contains '321') 'popup arguments preserve pointer x value'
Assert-Equal $true ($popupArgs -contains '-PointerY') 'popup arguments include captured pointer y'
Assert-Equal $true ($popupArgs -contains '654') 'popup arguments preserve pointer y value'
Assert-Equal $true ($popupArgs -contains '-ImagePathBase64') 'image paths use a base64 argument instead of shell quoting'
Assert-Equal $false ($popupArgs -contains 'C:\shots\one image.png') 'raw image paths are not placed on the command line'

$fallbackArgs = New-ClipwarpCalendarPopupArguments -PopupPath 'C:\clipwarp\popup.ps1' -Kind Text -Title 'Agenda'
Assert-Equal $false ($fallbackArgs -contains '-TimeoutSeconds') 'text launcher inherits the popup timeout default'
Assert-Equal $true ($fallbackArgs -contains '-TitleBase64') 'normal short titles preserve command-line transport'
Assert-Equal $false ($fallbackArgs -contains '-PointerX') 'popup arguments omit coordinates when no event-time pointer was captured'
$nullPointerArgs = New-ClipwarpCalendarPopupArguments -PopupPath 'C:\clipwarp\popup.ps1' -Kind Text -Title 'Agenda' -PointerX $null -PointerY $null
Assert-Equal $false ($nullPointerArgs -contains '-PointerX') 'popup arguments preserve current-pointer fallback through the launcher'

$timed = ConvertFrom-ClipwarpCalendarText -Text 'Review 2026-09-15 14:30' -LocalDate $date
Assert-Equal 'Review' $timed.Title 'strict parser removes an explicit ISO date and time from the title'
Assert-Equal 'Review 2026-09-15 14:30' $timed.OriginalText 'strict parser retains the complete original clipboard text for details'
Assert-Equal ([datetime]::new(2026, 9, 15, 14, 30, 0, [DateTimeKind]::Local)) $timed.Start 'strict parser reads an explicit ISO date and 24-hour time'
Assert-Equal ([datetime]::new(2026, 9, 15, 15, 30, 0, [DateTimeKind]::Local)) $timed.End 'timed events default to one hour'
$timedUrl = New-ClipwarpCalendarUrl -Title $timed.Title -Start $timed.Start -End $timed.End
Assert-Equal 'https://calendar.google.com/calendar/render?action=TEMPLATE&text=Review&dates=20260915T143000%2F20260915T153000' $timedUrl 'timed URL uses local floating calendar time'

$range = ConvertFrom-ClipwarpCalendarText -Text 'Meeting 2026-09-15 14:00-15:30' -LocalDate $date
Assert-Equal 'Meeting' $range.Title 'strict range parser removes both times from title'
Assert-Equal ([datetime]'2026-09-15 15:30') $range.End 'strict range parser uses explicit end time'
$shortDefault = ConvertFrom-ClipwarpCalendarText -Text 'Standup 2026-09-15 09:00' -LocalDate $date -DefaultDurationMinutes 25
Assert-Equal ([datetime]'2026-09-15 09:25') $shortDefault.End 'single time uses configurable default duration'
$badRange = ConvertFrom-ClipwarpCalendarText -Text 'Meeting 2026-09-15 15:30-14:00' -LocalDate $date
Assert-Equal $false $badRange.IsTimed 'backwards explicit range preserves fallback behavior'
Assert-Equal 'Meeting 2026-09-15 15:30-14:00' $badRange.Title 'invalid range leaves copied title intact'

$payload = Format-ClipwarpCalendarPayload -Title ((('A' * 90) + "`r`n") + ('B' * 400)) -Details 'existing' -MaxTitleLength 80 -MaxUrlLength 600
Assert-Equal 80 $payload.Title.Length 'payload formatter limits normalized title'
Assert-Equal $true $payload.Details.StartsWith('existing') 'payload formatter preserves supplied details before overflow'
Assert-Equal $true $payload.Details.Contains('BBBB') 'payload formatter partitions title overflow into details'
$multilineOriginal = "First line`r`nSecond line with caf$([char]0x00E9) and $([char]::ConvertFromUtf32(0x1F680)) " + ('tail ' * 30)
$multilinePayload = Format-ClipwarpCalendarPayload -Title $multilineOriginal -MaxTitleLength 60
Assert-Equal $true ($multilinePayload.Title.Length -le 60) 'long multiline clipboard text gets a concise title'
Assert-Equal $false ($multilinePayload.Title -match "`r|`n") 'calendar title is single-line safe text'
Assert-Equal $multilineOriginal $multilinePayload.Details 'details preserve the complete original Unicode and multiline text'
$multilineUrl = New-ClipwarpCalendarUrl -Title $multilineOriginal -LocalDate $date
Assert-Equal $true ($multilineUrl.Length -le 1900) 'multiline details preserve the existing URL bound'
$encodedMultilineDetails = ($multilineUrl -split '&details=', 2)[1]
Assert-Equal $multilineOriginal ([Uri]::UnescapeDataString($encodedMultilineDetails)) 'Google Calendar URL details contain the complete original text when within the bound'
$boundedUrl = New-ClipwarpCalendarUrl -Title ('x' * 5000) -LocalDate $date
Assert-Equal $true ($boundedUrl.Length -le 1900) 'calendar URL is bounded for oversized copied text'
$surrogateSafeUrl = New-ClipwarpCalendarUrl -Title ('x' + (([char]::ConvertFromUtf32(0x1F680)) * 1000)) -LocalDate $date
Assert-Equal $true ($surrogateSafeUrl.Length -le 1900) 'calendar URL truncation never splits a Unicode surrogate pair'
Assert-Equal $false $surrogateSafeUrl.Contains('%EF%BF%BD') 'calendar URL truncation does not insert a Unicode replacement character'
$detailsUrl = New-ClipwarpCalendarUrl -Title 'Review' -LocalDate $date -Details 'Line 1 & 2'
Assert-Equal $true $detailsUrl.Contains('&details=Line%201%20%26%202') 'optional details are safely encoded'

Assert-Equal 'America/Los_Angeles' (Get-ClipwarpCalendarTimeZone -TimeZoneId 'Pacific Standard Time') 'Windows timezone maps to Google IANA ctz'
Assert-Equal 'Asia/Bangkok' (Get-ClipwarpCalendarTimeZone -TimeZoneId 'SE Asia Standard Time') 'Windows Bangkok timezone maps to Google IANA ctz'
Assert-Equal 'Europe/London' (Get-ClipwarpCalendarTimeZone -TimeZoneId 'Europe/London') 'IANA timezone passes through safely'
Assert-Equal $null (Get-ClipwarpCalendarTimeZone -TimeZoneId 'Unknown Zone') 'unknown timezone has safe no-ctz fallback'
$tzUrl = New-ClipwarpCalendarUrl -Title 'Review' -Start $timed.Start -End $timed.End -TimeZone 'Pacific Standard Time'
Assert-Equal $true $tzUrl.EndsWith('&ctz=America%2FLos_Angeles') 'timed URL includes mapped ctz'
$boundedTimedUrl = New-ClipwarpCalendarUrl -Title (([char]::ConvertFromUtf32(0x1F680)) * 1000) -Details (([char]::ConvertFromUtf32(0x1F4C5)) * 1000) -Start $timed.Start -End $timed.End -TimeZone 'SE Asia Standard Time'
Assert-Equal $true ($boundedTimedUrl.Length -le 1900) 'timed URL with Unicode details and ctz remains bounded'
Assert-Equal $true $boundedTimedUrl.EndsWith('&ctz=Asia%2FBangkok') 'bounded timed URL retains ctz'
$allDayTz = New-ClipwarpCalendarUrl -Title 'Review' -LocalDate $date -TimeZone 'Pacific Standard Time'
Assert-Equal $false $allDayTz.Contains('ctz=') 'all-day URL remains unchanged when timezone is supplied'

$imagePrivate = Get-ClipwarpImageCalendarDetails -ImagePath 'C:\private\shots\secret.png' -Mode Disabled
Assert-Equal $null $imagePrivate 'image details default keeps local path out of event'
Assert-Equal 'Image file: secret.png' (Get-ClipwarpImageCalendarDetails -ImagePath 'C:\private\shots\secret.png' -Mode Filename) 'filename mode exposes only safe leaf name'
Assert-Equal 'Image file: C:\private\shots\secret.png' (Get-ClipwarpImageCalendarDetails -ImagePath 'C:\private\shots\secret.png' -Mode FullPath) 'full-path mode is explicit'

$preview = Get-ClipwarpCalendarPreview -Event $range -MaxTitleLength 24
Assert-Equal $true $preview.Contains('Meeting') 'popup preview includes concise event title'
Assert-Equal $true $preview.Contains('2026-09-15') 'popup preview includes event date'
Assert-Equal $true $preview.Contains('14:00') 'popup preview includes event time'

$ics = Export-ClipwarpIcsEvent -Title 'Review\folder, plan; next' -Details "one`r`ntwo\three" -Start $timed.Start -End $timed.End -TimeZone 'America/Los_Angeles' -Uid 'fixed@example' -CreatedUtc ([datetime]'2026-01-02T03:04:05Z')
Assert-Equal $true $ics.Contains("UID:fixed@example`r`n") 'ICS includes deterministic UID'
Assert-Equal $true $ics.Contains("SUMMARY:Review\\folder\, plan\; next`r`n") 'ICS escapes backslashes and summary punctuation'
Assert-Equal $true $ics.Contains("DESCRIPTION:one\ntwo\\three`r`n") 'ICS escapes CRLF and backslashes in details'
Assert-Equal $true $ics.Contains("DTSTART;TZID=America/Los_Angeles:20260915T143000`r`n") 'ICS emits timezone-aware local DTSTART'
$icsAllDay = Export-ClipwarpIcsEvent -Title 'Day' -LocalDate $date -Uid 'day@example' -CreatedUtc ([datetime]'2026-01-02T03:04:05Z')
Assert-Equal $true $icsAllDay.Contains("DTSTART;VALUE=DATE:20260831`r`nDTEND;VALUE=DATE:20260901") 'ICS all-day end is exclusive'
$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('th-TH')
    $cultureIcs = Export-ClipwarpIcsEvent -Title 'Culture' -LocalDate ([datetime]'2026-08-31') -Uid 'culture@example' -CreatedUtc ([datetime]'2026-01-02T03:04:05Z')
    Assert-Equal $true $cultureIcs.Contains("DTSTART;VALUE=DATE:20260831") 'ICS dates are invariant under a non-Gregorian current culture'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
$foldedIcs = Export-ClipwarpIcsEvent -Title (([string][char]0x4F60) * 80) -LocalDate $date -Uid 'fold@example' -CreatedUtc ([datetime]'2026-01-02T03:04:05Z')
$tooWide = @($foldedIcs -split "`r`n" | Where-Object { [Text.Encoding]::UTF8.GetByteCount($_) -gt 75 })
Assert-Equal 0 $tooWide.Count 'ICS folds every content line at 75 UTF-8 octets'

$combiningIcs = Export-ClipwarpIcsEvent -Title ('A' + ([string][char]0x0301) * 80) -LocalDate $date -Uid 'combining@test' -CreatedUtc ([datetime]'2026-08-31T00:00:00Z')
$combiningTooWide = @($combiningIcs -split "`r`n" | Where-Object { [Text.Encoding]::UTF8.GetByteCount($_) -gt 75 })
Assert-Equal 0 $combiningTooWide.Count 'ICS folding bounds a single long combining sequence by UTF-8 octets'

$clipboardValue = $null
Set-ClipwarpClipboardText -Value 'C:\events\review.ics' -Writer { param($value) $script:clipboardValue = $value }
Assert-Equal 'C:\events\review.ics' $clipboardValue 'clipboard helper passes the exported path as text through an injected writer'

$staProbe = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-sta-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    $calendarModule = Get-Module clipwarp-calendar
    & $calendarModule {
        param($probePath)
        Invoke-ClipwarpStaClipboardWrite -Value $probePath -Writer {
            param($value)
            [IO.File]::WriteAllText($value, [Threading.Thread]::CurrentThread.GetApartmentState().ToString())
        }
    } $staProbe
    Assert-Equal 'STA' ([IO.File]::ReadAllText($staProbe)) 'real clipboard path marshals its writer onto an STA runspace'
} finally { Remove-Item -LiteralPath $staProbe -Force -ErrorAction SilentlyContinue }

$ambiguous = ConvertFrom-ClipwarpCalendarText -Text 'Review next Tuesday at 2' -LocalDate $date
Assert-Equal $false $ambiguous.IsTimed 'ambiguous natural language falls back to an all-day event'
Assert-Equal 'Review next Tuesday at 2' $ambiguous.Title 'fallback preserves the complete title'

$dated = ConvertFrom-ClipwarpCalendarText -Text 'Submit report 2026-09-20' -LocalDate $date
Assert-Equal $false $dated.IsTimed 'explicit ISO date without a time remains all-day'
Assert-Equal ([datetime]'2026-09-20') $dated.LocalDate 'explicit ISO date selects the all-day event date'
Assert-Equal 'Submit report' $dated.Title 'date-only parser removes the explicit date from the title'

$longTitle = ([string][char]0x4F60) * 5000
$transportRoot = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp title test ' + [guid]::NewGuid().ToString('N'))
try {
    $longArgs = New-ClipwarpCalendarPopupArguments -PopupPath 'C:\clipwarp\popup.ps1' -Kind Text -Title $longTitle -TransportDirectory $transportRoot
    Assert-Equal $true ($longArgs -contains '-TitleFileBase64') 'oversized titles use file transport'
    Assert-Equal $false ($longArgs -contains '-TitleBase64') 'oversized titles are not placed on the command line'
    $titleFileIndex = [array]::IndexOf($longArgs, '-TitleFileBase64')
    $titleFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($longArgs[$titleFileIndex + 1]))
    Assert-Equal $longTitle ([IO.File]::ReadAllText($titleFile, [Text.Encoding]::UTF8)) 'file transport preserves Unicode exactly'
} finally { if (Test-Path -LiteralPath $transportRoot) { Remove-Item -LiteralPath $transportRoot -Recurse -Force } }

# Meeting Link & Location tests
$meetText = 'Sync https://meet.google.com/abc-defg-hij 2026-09-15 14:00'
$meetParsed = ConvertFrom-ClipwarpCalendarText -Text $meetText -LocalDate $date
Assert-Equal 'https://meet.google.com/abc-defg-hij' $meetParsed.Location 'Google Meet URL is extracted as location'
Assert-Equal 'Sync' $meetParsed.Title 'Google Meet URL is stripped from event title'
Assert-Equal $meetText $meetParsed.OriginalText 'original text preserves full meeting URL for details'

$zoomText = 'Zoom review https://us02web.zoom.us/j/123456789 2026-09-15 14:00'
$zoomParsed = ConvertFrom-ClipwarpCalendarText -Text $zoomText -LocalDate $date
Assert-Equal 'https://us02web.zoom.us/j/123456789' $zoomParsed.Location 'Zoom URL is extracted as location'
Assert-Equal 'Zoom review' $zoomParsed.Title 'Zoom URL is stripped from event title'

$locUrl = New-ClipwarpCalendarUrl -Title 'Meet' -LocalDate $date -Location 'https://meet.google.com/abc-defg-hij'
Assert-Equal $true ($locUrl.Contains('&location=https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij')) 'calendar URL includes encoded location parameter'

$boundedLocUrl = New-ClipwarpCalendarUrl -Title 'Meet' -LocalDate $date -Details ('D' * 5000) -Location 'https://meet.google.com/abc-defg-hij'
Assert-Equal $true ($boundedLocUrl.Length -le 1900) 'calendar URL with location remains bounded under 1900 chars'
Assert-Equal $true ($boundedLocUrl.Contains('&location=')) 'bounded URL retains location'

$icsLoc = Export-ClipwarpIcsEvent -Title 'Meet' -LocalDate $date -Location 'https://meet.google.com/abc-defg-hij'
Assert-Equal $true ($icsLoc.Contains("LOCATION:https://meet.google.com/abc-defg-hij`r`n")) 'ICS includes LOCATION property'

# Thai date tests
$thaiAbbr = ConvertFrom-ClipwarpCalendarText -Text 'ประชุมทีม 15 ก.ย. 2569 14:30' -LocalDate $date
Assert-Equal $true $thaiAbbr.IsTimed 'Thai date with month abbreviation is recognized as timed'
Assert-Equal ([datetime]'2026-09-15 14:30') $thaiAbbr.Start 'Thai Buddhist Era 2569 is converted to 2026'
Assert-Equal 'ประชุมทีม' $thaiAbbr.Title 'Thai title is cleanly extracted'

$thaiFull = ConvertFrom-ClipwarpCalendarText -Text 'ประชุมใหญ่ 15 กันยายน 69 10:00' -LocalDate $date
Assert-Equal $true $thaiFull.IsTimed 'Thai date with full month and 2-digit BE year is recognized'
Assert-Equal ([datetime]'2026-09-15 10:00') $thaiFull.Start 'Thai 2-digit BE 69 is converted to 2026'
Assert-Equal 'ประชุมใหญ่' $thaiFull.Title 'Thai title with full month is cleanly extracted'

$thaiDayOnly = ConvertFrom-ClipwarpCalendarText -Text 'วันหยุด 15 ก.ย. 2569' -LocalDate $date
Assert-Equal $false $thaiDayOnly.IsTimed 'Thai date without time is all-day event'
Assert-Equal ([datetime]'2026-09-15') $thaiDayOnly.LocalDate 'Thai date selects correct all-day date'
Assert-Equal 'วันหยุด' $thaiDayOnly.Title 'Thai all-day title is clean'

# DD/MM/YYYY tests
$dmy = ConvertFrom-ClipwarpCalendarText -Text 'Sprint planning 15/09/2026 14:00-15:30' -LocalDate $date
Assert-Equal $true $dmy.IsTimed 'DD/MM/YYYY is recognized as timed'
Assert-Equal ([datetime]'2026-09-15 14:00') $dmy.Start 'DD/MM/YYYY start time is correct'
Assert-Equal ([datetime]'2026-09-15 15:30') $dmy.End 'DD/MM/YYYY end time is correct'
Assert-Equal 'Sprint planning' $dmy.Title 'DD/MM/YYYY title is clean'

$dmyBe = ConvertFrom-ClipwarpCalendarText -Text 'Review 15/09/2569 14:00' -LocalDate $date
Assert-Equal ([datetime]'2026-09-15 14:00') $dmyBe.Start 'DD/MM/YYYY with BE year converts to CE'

# AM/PM tests
$ampmSingle = ConvertFrom-ClipwarpCalendarText -Text 'Call client 15/09/2026 2:30 PM' -LocalDate $date
Assert-Equal ([datetime]'2026-09-15 14:30') $ampmSingle.Start '12-hour PM is converted to 24-hour'
Assert-Equal ([datetime]'2026-09-15 15:30') $ampmSingle.End '12-hour PM defaults to 1 hour duration'

$ampmRange = ConvertFrom-ClipwarpCalendarText -Text 'Interview 15/09/2026 10:00 AM - 11:30 AM' -LocalDate $date
Assert-Equal ([datetime]'2026-09-15 10:00') $ampmRange.Start 'AM range start is correct'
Assert-Equal ([datetime]'2026-09-15 11:30') $ampmRange.End 'AM range end is correct'

# พรุ่งนี้ (Tomorrow) tests
$tmrwTimed = ConvertFrom-ClipwarpCalendarText -Text 'วางแผนงาน พรุ่งนี้ 14:00-15:30' -LocalDate $date
Assert-Equal $true $tmrwTimed.IsTimed 'พรุ่งนี้ with time is timed event'
Assert-Equal ($date.Date.AddDays(1).AddHours(14)) $tmrwTimed.Start 'พรุ่งนี้ starts tomorrow at parsed time'
Assert-Equal ($date.Date.AddDays(1).AddHours(15).AddMinutes(30)) $tmrwTimed.End 'พรุ่งนี้ ends tomorrow at parsed end time'
Assert-Equal 'วางแผนงาน' $tmrwTimed.Title 'พรุ่งนี้ keyword is stripped from title'

$tmrwAllDay = ConvertFrom-ClipwarpCalendarText -Text 'ประชุมพรุ่งนี้' -LocalDate $date
Assert-Equal $false $tmrwAllDay.IsTimed 'พรุ่งนี้ without time is all-day event'
Assert-Equal ($date.Date.AddDays(1)) $tmrwAllDay.LocalDate 'พรุ่งนี้ date is tomorrow'
Assert-Equal 'ประชุม' $tmrwAllDay.Title 'attached พรุ่งนี้ is stripped from title'

# Time-only defaults to tomorrow
$timeOnly24 = ConvertFrom-ClipwarpCalendarText -Text 'ประชุม 14:00 น.' -LocalDate $date
Assert-Equal $true $timeOnly24.IsTimed 'time-only 24h is timed'
Assert-Equal ($date.Date.AddDays(1).AddHours(14)) $timeOnly24.Start 'time-only date defaults to tomorrow'
Assert-Equal 'ประชุม' $timeOnly24.Title 'time and น. stripped from title'

$timeOnly12 = ConvertFrom-ClipwarpCalendarText -Text 'Standup 10:00 AM' -LocalDate $date
Assert-Equal ($date.Date.AddDays(1).AddHours(10)) $timeOnly12.Start 'time-only 12h date defaults to tomorrow'

# Combined meeting link + พรุ่งนี้ + time
$combo = ConvertFrom-ClipwarpCalendarText -Text 'นัดคุย https://meet.google.com/xyz-uvwx-rst พรุ่งนี้ 10:30 AM' -LocalDate $date
Assert-Equal 'https://meet.google.com/xyz-uvwx-rst' $combo.Location 'combo extracts meeting URL'
Assert-Equal ($date.Date.AddDays(1).AddHours(10).AddMinutes(30)) $combo.Start 'combo starts tomorrow at 10:30'
Assert-Equal 'นัดคุย' $combo.Title 'combo cleans title of URL and date/time'

# Overnight time range test (crossing midnight)
$overnight = ConvertFrom-ClipwarpCalendarText -Text 'Deployment 15/09/2026 11:00 PM - 1:00 AM' -LocalDate $date
Assert-Equal $true $overnight.IsTimed 'overnight range is recognized as timed'
Assert-Equal ([datetime]'2026-09-15 23:00') $overnight.Start 'overnight start time is 23:00 on event date'
Assert-Equal ([datetime]'2026-09-16 01:00') $overnight.End 'overnight end time crosses to next day 01:00'

# Thai dot time without suffix test (e.g. 14.30)
$thaiDot = ConvertFrom-ClipwarpCalendarText -Text 'นัดคุย 15/09/2026 14.30' -LocalDate $date
Assert-Equal $true $thaiDot.IsTimed 'Thai dot format without suffix is recognized as timed'
Assert-Equal ([datetime]'2026-09-15 14:30') $thaiDot.Start 'Thai dot format time is correct'

# วันนี้ (Today) relative date test
$todayTimed = ConvertFrom-ClipwarpCalendarText -Text 'ประชุมด่วน วันนี้ 15:00' -LocalDate $date
Assert-Equal $true $todayTimed.IsTimed 'วันนี้ with time is timed event'
Assert-Equal ($date.Date.AddHours(15)) $todayTimed.Start 'วันนี้ starts today at parsed time'

# Invalid date guard test (e.g. Feb 31)
$invalidFeb = ConvertFrom-ClipwarpCalendarText -Text 'ประชุม 2026-02-31 14:30' -LocalDate $date
Assert-Equal $false $invalidFeb.IsTimed 'invalid date does not crash and falls back safely'

# Default start date is tomorrow for undated text & default URL
$undated = ConvertFrom-ClipwarpCalendarText -Text 'Meeting notes' -LocalDate $date
Assert-Equal ($date.Date.AddDays(1)) $undated.LocalDate 'undated text defaults start date to tomorrow'

$defaultUrl = New-ClipwarpCalendarUrl -Title 'Default start'
$tomorrowStr = ((Get-Date).Date.AddDays(1)).ToString('yyyyMMdd')
# CLI command detection tests
Assert-Equal $true (Test-ClipwarpCommandLine -Text "npm install -D tailwindcss") 'npm command is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text "git commit -m 'initial commit'") 'git command is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text "Get-Process | Stop-Process") 'PowerShell pipeline is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text "PS C:\Users\Admin> winget install Microsoft.PowerToys") 'Prompt-prefixed command is recognized'
Assert-Equal 'winget install Microsoft.PowerToys' (Get-ClipwarpCommandText -Text "PS C:\Users\Admin> winget install Microsoft.PowerToys") 'PS prompt is stripped from command'
Assert-Equal $true (Test-ClipwarpCommandLine -Text '$ git clone https://github.com/user/repo.git') 'Bash prompt prefixed command is recognized'
Assert-Equal 'git clone https://github.com/user/repo.git' (Get-ClipwarpCommandText -Text '$ git clone https://github.com/user/repo.git') 'Dollar prompt is stripped from command'
Assert-Equal $true (Test-ClipwarpCommandLine -Text '> docker run -d -p 80:80 nginx') 'Chevron prompt prefixed command is recognized'
Assert-Equal 'docker run -d -p 80:80 nginx' (Get-ClipwarpCommandText -Text '> docker run -d -p 80:80 nginx') 'Chevron prompt is stripped from command'
Assert-Equal $true (Test-ClipwarpCommandLine -Text 'pip install requests') 'pip command is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text 'cargo build --release') 'cargo command is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text 'dir /s /b') 'CMD builtin dir is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text 'curl -fsSL https://example.com') 'curl command is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text '$env:PATH += ";C:\tools"') 'PowerShell variable assignment is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text 'irm https://raw.githubusercontent.com/chakritago/clipwarp/main/install.ps1 | iex') 'irm install pipeline is recognized'
Assert-Equal $true (Test-ClipwarpCommandLine -Text '.\build.ps1 -Target Deploy') 'Local script invocation is recognized'
Assert-Equal $false (Test-ClipwarpCommandLine -Text 'Meeting tomorrow at 10:00 AM') 'Calendar meeting is not treated as command'
Assert-Equal $false (Test-ClipwarpCommandLine -Text 'นัดคุยงาน 15 ก.ย. 2569') 'Thai calendar text is not treated as command'
Assert-Equal $false (Test-ClipwarpCommandLine -Text 'Hello world this is a normal sentence.') 'Plain sentence is not treated as command'
Assert-Equal $false (Test-ClipwarpCommandLine -Text 'Sprint planning 14:00-15:30') 'Timed title is not treated as command'
Assert-Equal $false (Test-ClipwarpCommandLine -Text '   ') 'Whitespace is not treated as command'

# Start-ClipwarpCommand deterministic launch argument tests
$testCmd = "echo 'hello world'"
$expectedClean = "echo 'hello world'"
Assert-Equal $expectedClean (Get-ClipwarpCommandText -Text $testCmd) 'command text cleanup preserves simple command'
$promptCmd = "PS C:\Users\Test> npm test"
Assert-Equal 'npm test' (Get-ClipwarpCommandText -Text $promptCmd) 'command text cleanup strips powershell prompt'
$unicodeCmd = "Write-Host 'สวัสดี'"
$unicodeClean = Get-ClipwarpCommandText -Text $unicodeCmd
$unicodeB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($unicodeClean))
$decodedUnicode = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($unicodeB64))
Assert-Equal $unicodeCmd $decodedUnicode 'unicode command transport preserves characters through base64 encoding'
$multilineCmd = "Write-Host Line1`r`nWrite-Host Line2"
$multilineClean = Get-ClipwarpCommandText -Text $multilineCmd
$multilineB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($multilineClean))
$decodedMultiline = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($multilineB64))
Assert-Equal $multilineCmd $decodedMultiline 'multiline command transport preserves CRLF through base64 encoding'

# ProcessStartInfo decision helper tests
$mockWithWt = { param($name) if ($name -eq 'wt.exe') { [pscustomobject]@{ Source = 'C:\WindowsApps\wt.exe' } } else { $null } }
$mockWithoutWt = { param($name) $null }

$wtInfo = New-ClipwarpCommandProcessStartInfo -CommandText 'npm test' -CommandLookup $mockWithWt
Assert-Equal 'wt.exe' $wtInfo.FileName 'launcher decision prefers wt.exe when available'
Assert-Equal 'wt' $wtInfo.Launcher 'launcher note property reports wt'
Assert-Equal $true ($wtInfo.Arguments.Contains('powershell.exe -NoExit -ExecutionPolicy Bypass -EncodedCommand')) 'wt arguments encapsulate powershell invocation'
Assert-Equal $false $wtInfo.CreateNoWindow 'wt CreateNoWindow is false for window visibility'
Assert-Equal $true $wtInfo.UseShellExecute 'wt UseShellExecute is true for detachment'
Assert-Equal ([System.Diagnostics.ProcessWindowStyle]::Normal) $wtInfo.WindowStyle 'wt WindowStyle is Normal'

$psInfo = New-ClipwarpCommandProcessStartInfo -CommandText 'npm test' -CommandLookup $mockWithoutWt
Assert-Equal 'powershell.exe' $psInfo.FileName 'launcher decision falls back to powershell.exe when wt.exe is missing'
Assert-Equal 'powershell' $psInfo.Launcher 'launcher note property reports powershell'
Assert-Equal $true ($psInfo.Arguments.StartsWith('-NoExit -ExecutionPolicy Bypass -EncodedCommand')) 'powershell arguments use encoded command'
Assert-Equal $false $psInfo.CreateNoWindow 'powershell CreateNoWindow is false for window visibility'
Assert-Equal $true $psInfo.UseShellExecute 'powershell UseShellExecute is true for detachment'
Assert-Equal ([System.Diagnostics.ProcessWindowStyle]::Normal) $psInfo.WindowStyle 'powershell WindowStyle is Normal'
Assert-Equal 5 $psInfo.ArgumentList.Count 'powershell ArgumentList has expected token count'
Assert-Equal '-EncodedCommand' $psInfo.ArgumentList[3] 'powershell ArgumentList uses safe encoded transport'

$aliasInfo = Get-ClipwarpCommandProcessStartInfo -CommandText 'npm test' -CommandLookup $mockWithoutWt
Assert-Equal 'powershell.exe' $aliasInfo.FileName 'Get- alias returns matching process start info'

$forcedPs = New-ClipwarpCommandProcessStartInfo -CommandText 'npm test' -Launcher 'powershell' -CommandLookup $mockWithWt
Assert-Equal 'powershell.exe' $forcedPs.FileName 'explicit launcher override bypasses preferred wt'

$emptyInfo = New-ClipwarpCommandProcessStartInfo -CommandText '   '
Assert-Equal $null $emptyInfo 'empty command text produces null process start info'

$nonExistentDir = Join-Path ([IO.Path]::GetTempPath()) ('nonexistent-' + [guid]::NewGuid().ToString('N'))
$fallbackDirInfo = New-ClipwarpCommandProcessStartInfo -CommandText 'npm test' -WorkingDirectory $nonExistentDir -CommandLookup $mockWithoutWt
Assert-Equal $env:USERPROFILE $fallbackDirInfo.WorkingDirectory 'invalid working directory safely falls back to USERPROFILE'

# Start-ClipwarpCommand fallback decision tests with injected process starter
$wtOnlyCalls = @()
$mockStarterSuccess = { param($psi) $script:wtOnlyCalls += $psi.FileName; return $true }
Start-ClipwarpCommand -CommandText 'npm test' -CommandLookup $mockWithWt -ProcessStarter $mockStarterSuccess
Assert-Equal 1 $wtOnlyCalls.Count 'successful preferred launcher only launches once'
Assert-Equal 'wt.exe' $wtOnlyCalls[0] 'successful preferred launcher selects wt.exe'

$fallbackCalls = @()
$mockStarterFailWt = {
    param($psi)
    $script:fallbackCalls += $psi.FileName
    if ($psi.FileName -eq 'wt.exe') { return $false }
    return $true
}
Start-ClipwarpCommand -CommandText 'npm test' -CommandLookup $mockWithWt -ProcessStarter $mockStarterFailWt
Assert-Equal 2 $fallbackCalls.Count 'failed preferred launcher triggers fallback attempt'
Assert-Equal 'wt.exe' $fallbackCalls[0] 'failed preferred launcher is attempted first'
Assert-Equal 'powershell.exe' $fallbackCalls[1] 'failed preferred launcher falls back to powershell.exe'

$directPsCalls = @()
$mockStarterPs = { param($psi) $script:directPsCalls += $psi.FileName; return $true }
Start-ClipwarpCommand -CommandText 'npm test' -CommandLookup $mockWithoutWt -ProcessStarter $mockStarterPs
Assert-Equal 1 $directPsCalls.Count 'missing wt directly launches powershell'
Assert-Equal 'powershell.exe' $directPsCalls[0] 'missing wt launches powershell.exe'

if ($failures) { throw "$failures calendar test(s) failed" }
Write-Host 'All calendar tests passed.' -ForegroundColor Cyan

if ([IO.File]::ReadAllText($popupPath) -notmatch 'SuppressKeyPress = \$true') { throw 'Popup must suppress Enter before focused Run can activate' }

$keyboardRunHandlers = @($popupAst.FindAll({ $args[0] -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
    Where-Object { $_.Expression.Extent.Text.Trim() -eq '$runButton' -and $_.Member.Extent.Text -eq 'Add_Click' })
if ($keyboardRunHandlers.Count) { throw 'Run must not use keyboard/default-button Click activation' }
