$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$watch = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-watch.ps1'))
$popup = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-calendar-popup.ps1'))
function Assert-Popup([bool]$OK,[string]$Description) {
    if (-not $OK) { throw "Popup regression: $Description" }
    Write-Host "PASS: $Description"
}
Assert-Popup ($watch.Contains('public bool ShowTestPopup()') -and $watch.Contains('Test Clipboard Popup')) 'tray popup test is available and does not require copying'
Assert-Popup ($watch.Contains('LaunchImagePopup(mPath)') -and $watch.Contains('private bool LaunchImagePopup')) 'successful managed image conversion triggers a popup'
Assert-Popup ($watch.Contains('private bool LaunchTextPopup(string title)') -and $watch.Contains('text copy -> popup launched')) 'text copies use explicit popup launch reporting'
Assert-Popup ($watch.Contains('popup disabled in settings') -and $watch.Contains('Get-ClipwarpCalendarEnabled')) 'disabled popup setting is visibly diagnosable'
Assert-Popup ($watch.Contains('ObserveEvent(nowMs)') -and $watch.Contains('ObserveContent(contentFp, nowMs)')) 'clipboard storm is counted once per notification'
Assert-Popup ($watch.Contains('StormRemainingMs(nowMs)+150') -and $watch.Contains('debounce.Start();')) 'storm pauses schedule deferred reinspection'
Assert-Popup ($popup.Contains('[int]$TimeoutSeconds = 12') -and $popup.Contains('WaitOne(1500)')) 'popup remains visible longer and waits for previous window'
Assert-Popup ($popup.Contains('clipwarp-popup-error.log') -and $popup.Contains('ScriptLineNumber') -and -not $popup.Contains('WriteAllText($diag, $Title')) 'startup errors report location without copied text'
$inspectStart = $watch.IndexOf('private void Inspect()')
$inspectEnd = $watch.IndexOf('private string PointerArguments()', $inspectStart)
Assert-Popup ($inspectStart -ge 0 -and $inspectEnd -gt $inspectStart) 'watcher inspection function found'
$inspect = $watch.Substring($inspectStart,$inspectEnd-$inspectStart)
Assert-Popup ($inspect.IndexOf('string txt = null;') -lt $inspect.IndexOf('ClipboardBurstGuard.Verdict burstVerdict') -and
    $inspect.IndexOf('string txt = null;') -lt $inspect.IndexOf('if (convFails >= 3)')) 'text copy remains eligible despite image failure and burst budgets'
Assert-Popup (-not $inspect.Contains('meaningful == lastTextFingerprint')) 'fresh repeated copies do not silently suppress popups'
$parseErrors = $null; $tokens = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp-watch.ps1'),[ref]$tokens,[ref]$parseErrors)
Assert-Popup (@($parseErrors).Count -eq 0) 'watcher PowerShell syntax parses'
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp-calendar-popup.ps1'),[ref]$tokens,[ref]$parseErrors)
Assert-Popup (@($parseErrors).Count -eq 0) 'popup PowerShell syntax parses'
Write-Host 'PASS: clipboard-popup regressions (static + policy tests, no physical desktop asserted)'
