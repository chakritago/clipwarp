$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
if (-not (Get-Command -Name Start-ClipwarpGeminiSparkHandoff -Module clipwarp-calendar -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'ordinary Import-Module must export Start-ClipwarpGeminiSparkHandoff'
}
Write-Host 'PASS: ordinary Import-Module exports Start-ClipwarpGeminiSparkHandoff'

& (Get-Module clipwarp-calendar) {
    function Check($ok, $name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }

    $url = 'https://gemini.google.com/spark'
    Check ((New-ClipwarpGeminiSparkUrl) -ceq $url) 'exact Spark URL'

    # Test Find-ClipwarpGeminiSparkPage matching browser and title
    $validProc = [pscustomobject]@{ ProcessName='msedge'; MainWindowTitle='Google Gemini - Microsoft Edge'; MainWindowHandle=[IntPtr]1234 }
    $found = Find-ClipwarpGeminiSparkPage -Url 'any' -ProcessFinder { @($validProc) }
    Check ($found -eq $validProc) 'matching browser and title is discovered'

    $nonBrowser = [pscustomobject]@{ ProcessName='notepad'; MainWindowTitle='Gemini notes'; MainWindowHandle=[IntPtr]1234 }
    $foundNonBrowser = Find-ClipwarpGeminiSparkPage -Url 'any' -ProcessFinder { @($nonBrowser) }
    Check ($null -eq $foundNonBrowser) 'non-browser process is ignored'

    $nonGemini = [pscustomobject]@{ ProcessName='chrome'; MainWindowTitle='Google Search'; MainWindowHandle=[IntPtr]1234 }
    $foundNonGemini = Find-ClipwarpGeminiSparkPage -Url 'any' -ProcessFinder { @($nonGemini) }
    Check ($null -eq $foundNonGemini) 'browser with different title is ignored'

    $zeroHandle = [pscustomobject]@{ ProcessName='msedge'; MainWindowTitle='Gemini'; MainWindowHandle=[IntPtr]::Zero }
    $foundZero = Find-ClipwarpGeminiSparkPage -Url 'any' -ProcessFinder { @($zeroHandle) }
    Check ($null -eq $foundZero) 'process with zero MainWindowHandle is ignored'

    # Test Wait-ClipwarpGeminiSparkPage polling and retry
    $state = @{ Polls = 0 }
    $waited = Wait-ClipwarpGeminiSparkPage -Url 'test' -PageFinder {
        $state.Polls++
        if ($state.Polls -ge 3) { $validProc } else { $null }
    } -Delay { } -Attempts 5
    Check ($waited -eq $validProc -and $state.Polls -eq 3) 'wait retries until window appears'

    # Test Wait-ClipwarpGeminiSparkPage timeout failure
    $failed = $false
    try {
        Wait-ClipwarpGeminiSparkPage -Url 'test' -PageFinder { $null } -Delay { } -Attempts 3
    } catch {
        $failed = $true
    }
    Check $failed 'wait fails closed when window is not found'

    # Test Send-ClipwarpGeminiSparkMessage invokes window activation and key sending
    $sendState = @{ ActivatedPage=$null; SentMessage=$null }
    $fakePage = [pscustomobject]@{ MainWindowHandle=[IntPtr]5678 }
    $testMsg = " `tHello Gemini`r`n" + [char]0x4F60 + [char]0x0E01 + " line 2`n  "

    Send-ClipwarpGeminiSparkMessage -Page $fakePage -Message $testMsg `
        -WindowActivator { param($p) $sendState.ActivatedPage = $p } `
        -KeySender { param($m) $sendState.SentMessage = $m } `
        -Delay { }

    Check ($sendState.ActivatedPage -eq $fakePage) 'window activator receives target page'
    Check ($sendState.SentMessage -eq $testMsg) 'key sender receives exact original message'

    # Test Start-ClipwarpGeminiSparkHandoff full workflow
    $calls = New-Object Collections.Generic.List[object]
    Start-ClipwarpGeminiSparkHandoff -Message $testMsg `
        -ClipboardWriter { param($v) $calls.Add([pscustomobject]@{ Kind='clip'; Value=$v }) } `
        -BrowserStarter { param($v) $calls.Add([pscustomobject]@{ Kind='browser'; Value=$v }) } `
        -PageWaiter { param($u) $calls.Add([pscustomobject]@{ Kind='wait'; Value=$u }); $fakePage } `
        -Submitter { param($p, $m) $calls.Add([pscustomobject]@{ Kind='submit'; Page=$p; Message=$m }) }

    Check ($calls.Count -eq 4) 'handoff runs exactly 4 steps'
    Check ($calls[0].Kind -eq 'clip' -and $calls[0].Value -eq $testMsg) 'handoff writes clipboard first'
    Check ($calls[1].Kind -eq 'browser' -and $calls[1].Value -eq $url) 'handoff starts browser with Gemini Spark URL'
    Check ($calls[2].Kind -eq 'wait') 'handoff waits for page'
    Check ($calls[3].Kind -eq 'submit' -and $calls[3].Page -eq $fakePage -and $calls[3].Message -eq $testMsg) 'handoff submits page and message'

    # Test failure propagation
    $failed = $false
    try {
        Start-ClipwarpGeminiSparkHandoff -Message $testMsg -ClipboardWriter { throw 'clip err' }
    } catch {
        if ($_.Exception.Message -like '*clip err*') { $failed = $true }
    }
    Check $failed 'clipboard failure propagates'

    $failed = $false
    try {
        Start-ClipwarpGeminiSparkHandoff -Message $testMsg `
            -ClipboardWriter { } `
            -BrowserStarter { } `
            -PageWaiter { throw 'wait err' }
    } catch {
        if ($_.Exception.Message -like '*wait err*') { $failed = $true }
    }
    Check $failed 'waiter failure propagates'

    $failed = $false
    try {
        Start-ClipwarpGeminiSparkHandoff -Message $testMsg `
            -ClipboardWriter { } `
            -BrowserStarter { } `
            -PageWaiter { $fakePage } `
            -Submitter { throw 'submit err' }
    } catch {
        if ($_.Exception.Message -like '*submit err*') { $failed = $true }
    }
    Check $failed 'submitter failure propagates'
}

$popup = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar-popup.ps1'))
if ($popup -notmatch '\$geminiButton.AccessibleName = ''Send to Gemini Spark''') { throw 'accessible Gemini button missing' }
if ($popup -notmatch 'Start-ClipwarpGeminiSparkHandoff -Message \$Title') { throw 'original title wiring missing' }
if ($popup -match 'AcceptButton = \$geminiButton') { throw 'Gemini must not be default' }
if ($popup -notmatch '\$geminiButton.Add_MouseClick') { throw 'deliberate mouse activation required' }

# Execute only the extracted handler against fakes; never construct/show a popup.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($popup, [ref]$tokens, [ref]$errors)
$handler = $ast.Find({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$geminiButton' -and $n.Member.Value -eq 'Add_MouseClick' }, $true)
if ($null -eq $handler) { throw 'Gemini click handler missing' }
$ancestor = $handler.Parent
while ($ancestor -and -not ($ancestor -is [Management.Automation.Language.IfStatementAst] -and $ancestor.Clauses[0].Item1.Extent.Text -eq '$Kind -eq ''Text''')) { $ancestor = $ancestor.Parent }
if (-not $ancestor) { throw 'Gemini button must be text-only' }
Add-Type -AssemblyName System.Windows.Forms
$record = New-Object Collections.Generic.List[string]
$form = New-Object psobject
$form | Add-Member ScriptMethod Hide { $record.Add('hide') }
$form | Add-Member ScriptMethod Close { $record.Add('close') }
$timer = New-Object psobject
$timer | Add-Member ScriptMethod Stop { $record.Add('stop') }
$geminiButton = [pscustomobject]@{ Enabled = $true }
$Title = "  original`r`n" + [char]0x0E01 + "`t "
function Start-ClipwarpGeminiSparkHandoff { param($Message) if (-not [string]::Equals($Message, $Title, [StringComparison]::Ordinal)) { throw 'handler changed text' }; $record.Add('handoff') }
$callback = [scriptblock]::Create($handler.Arguments[0].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
$_ = [pscustomobject]@{ Button = [Windows.Forms.MouseButtons]::Right }
& $callback
if ($record.Count) { throw 'right click must not submit' }
$_ = [pscustomobject]@{ Button = [Windows.Forms.MouseButtons]::Left }
& $callback
if (($record -join ',') -ne 'stop,hide,handoff,close' -or $geminiButton.Enabled) { throw 'popup handoff sequence incorrect' }
Write-Host 'PASS: fake popup handler preserves original text and stops timer'

# Check scaled row placement and bottom clearance without a real window.
foreach ($dpi in @(96, 120, 144, 192, 384)) {
    $m = Get-ClipwarpPopupMetrics -Dpi $dpi
    $scale = $m.Width / 400.0
    $gap = [int][Math]::Round(8 * $scale)
    $bottom = $m.ButtonTop + 3 * $m.ButtonHeight + 2 * $gap + [int][Math]::Round(24 * $scale)
    if ($bottom -gt ($m.Height + [int][Math]::Round(112 * $scale))) { throw "Gemini layout clips at DPI $dpi" }
}
Write-Host 'PASS: scaled text popup accommodates Gemini row and hint'
