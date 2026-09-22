$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
if (-not (Get-Command -Name Start-ClipwarpGeminiSparkHandoff -Module clipwarp-calendar -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'ordinary Import-Module must export Start-ClipwarpGeminiSparkHandoff'
}
Write-Host 'PASS: ordinary Import-Module exports Start-ClipwarpGeminiSparkHandoff'
& (Get-Module clipwarp-calendar) {
    function Check($ok,$name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }
    function Fails($action,$name) { $failed=$false; try { & $action } catch { $failed=$true }; Check $failed $name }
    $url='https://gemini.google.com/spark'
    Check ((New-ClipwarpGeminiSparkUrl) -ceq $url) 'exact Spark URL'
    function Fixture {
        [pscustomobject]@{ Url=$url; Id='doc1'; Visible=$true; Browser=$true; Login=$false; Document=$null
            Composers=@([pscustomobject]@{ Id='edit1'; Text=''; Writable=$true; Element=$null; Pattern=$null })
            Sends=@([pscustomobject]@{ Id='send1'; Supported=$true; Enabled=$true; Element=$null; Pattern=$null }) }
    }
    $page=Fixture
    Check ((Find-ClipwarpGeminiSparkPage -DocumentReader { $page }).Id -eq 'doc1') 'discovery fixture'
    foreach ($wrong in @('https://chatgpt.com/spark','https://gemini.google.com.evil/spark','https://gemini.google.com/spark?x=1','https://gemini.google.com/spark/','http://gemini.google.com/spark','https://gemini.google.com/app','https://gemini.google.com/spark#x')) {
        $page=Fixture; $page.Url=$wrong
        Check ($null -eq (Find-ClipwarpGeminiSparkPage -DocumentReader { $page })) "isolates $wrong"
    }
    $page=Fixture; $page.Visible=$false
    Check ($null -eq (Find-ClipwarpGeminiSparkPage -DocumentReader { $page })) 'hidden document ignored'
    $page=Fixture; $page.Browser=$false
    Check ($null -eq (Find-ClipwarpGeminiSparkPage -DocumentReader { $page })) 'non browser ignored'
    $page=Fixture
    Fails { Find-ClipwarpGeminiSparkPage -DocumentReader { $page; $page } } 'ambiguous documents rejected'
    $poll=@{ Count=0 }
    $result=Wait-ClipwarpGeminiSparkPage -PageFinder { $poll.Count++; if ($poll.Count -eq 3) { $page } } -Delay {} -Attempts 3
    Check ($result.Id -eq 'doc1' -and $poll.Count -eq 3) 'bounded discovery polling'
    Fails { Wait-ClipwarpGeminiSparkPage -PageFinder {} -Delay {} -Attempts 2 } 'discovery timeout'
    $poll=@{ Count=0 }
    $result=Wait-ClipwarpGeminiSparkPage -PageFinder {
        $poll.Count++; $p=Fixture; $p.Sends[0].Enabled=$false
        if ($poll.Count -eq 1) { $p.Composers=@(); $p.Sends=@() }
        if ($poll.Count -eq 2) { $p.Sends=@() }
        $p
    } -Delay {} -Attempts 3
    Check ($poll.Count -eq 3 -and -not $result.Sends[0].Enabled) 'waits for controls after document; disabled supported send is ready'
    foreach ($mode in @('missing','readonly','unreadable','unsupported','ambiguous','changed')) {
        $poll=@{ Count=0 }
        Fails {
            Wait-ClipwarpGeminiSparkPage -PageFinder {
                $poll.Count++; $p=Fixture
                switch ($mode) {
                    missing { $p.Composers=@() }
                    readonly { $p.Composers[0].Writable=$false }
                    unreadable { $p.Composers[0].Text=$null }
                    unsupported { $p.Sends[0].Supported=$false }
                    ambiguous { $p.Sends += $p.Sends[0] }
                    changed { if ($poll.Count -eq 1) { $p.Sends=@() } else { $p.Id='doc2' } }
                }
                $p
            } -Delay {} -Attempts 2
        } "readiness fails closed: $mode"
        Check ($poll.Count -le 2) "bounded readiness: $mode"
    }
    $message=" `tHello`r`n" + [char]0x4F60 + [char]0x0E01 + [char]::ConvertFromUtf32(0x1F600) + "e" + [char]0x0301 + "`n  "
    foreach ($mode in @('success','delayed','latepage','latecomposer','latesend','latetext','draft','login','composers','sends','missingcomposer','missingsend','unsupported','unsupportedsend','readonly','disabled','pagechange','urlchange','composerchange','sendchange','postchange','normalize','casechange','unverified','invokeerror')) {
        $page=Fixture; $state=@{ Invokes=0; Reads=0 }; $calls=New-Object Collections.Generic.List[string]
        switch ($mode) {
            draft { $page.Composers[0].Text=' ' }
            login { $page.Login=$true }
            composers { $page.Composers += $page.Composers[0] }
            sends { $page.Sends += $page.Sends[0] }
            readonly { $page.Composers[0].Writable=$false }
            disabled { $page.Sends[0].Enabled=$false }
            missingcomposer { $page.Composers=@() }
            missingsend { $page.Sends=@() }
            unsupported { $page.Composers[0].Text=$null; $page.Composers[0].Writable=$false }
            unsupportedsend { $page.Sends[0].Supported=$false }
        }
        if ($mode -in @('delayed','latepage','latecomposer','latesend','latetext')) { $page.Sends[0].Enabled=$false }
        $action={
            Start-ClipwarpGeminiSparkHandoff -Message $message -ClipboardWriter { param($v) Check ([string]::Equals($v,$message,[StringComparison]::Ordinal)) 'clipboard exact'; $calls.Add('clipboard') } -BrowserStarter { param($u) Check ($u -ceq $url) 'browser exact URL'; $calls.Add('browser') } -PageWaiter { $calls.Add('wait'); $page } -Submitter {
                param($p,$m)
                Send-ClipwarpGeminiSparkMessage -Page $p -Message $m -SnapshotReader {
                    param($p) $state.Reads++
                    if ($state.Reads -eq 3) {
                        switch ($mode) {
                            delayed { $page.Sends[0].Enabled=$true }
                            latepage { $page.Id='doc2' }
                            latecomposer { $page.Composers[0].Id='edit2' }
                            latesend { $page.Sends[0].Id='send2' }
                            latetext { $page.Composers[0].Text='changed' }
                        }
                    }
                    if ($state.Reads -gt 1) {
                        switch ($mode) {
                            pagechange { $page.Id='doc2' }
                            urlchange { $page.Url='https://chatgpt.com/' }
                            composerchange { $page.Composers[0].Id='edit2' }
                            sendchange { $page.Sends[0].Id='send2' }
                        }
                    }
                    if ($mode -eq 'postchange' -and $state.Reads -gt 2) { $page.Id='doc2' }
                    $page
                } -TextSetter {
                    param($c,$v) $calls.Add('fill'); Check ([string]::Equals($v,$message,[StringComparison]::Ordinal)) 'fill exact'
                    $page.Composers[0].Text=$v
                    if ($mode -eq 'normalize') { $page.Composers[0].Text=$v.Trim() }
                    if ($mode -eq 'casechange') { $page.Composers[0].Text=$v.ToUpperInvariant() }
                } -SendInvoker {
                    param($s) $calls.Add('invoke'); $state.Invokes++
                    if ($mode -eq 'invokeerror') { throw 'failed' }
                    if ($mode -ne 'unverified') { $page.Composers[0].Text='' }
                } -Delay { $calls.Add('verify') } -Attempts 2
            }
        }
        if ($mode -in @('success','delayed')) {
            & $action
            $order=if ($mode -eq 'delayed') { 'clipboard,browser,wait,fill,verify,invoke,verify' } else { 'clipboard,browser,wait,fill,invoke,verify' }
            Check (($calls -join ',') -eq $order) "ordered handoff through verification: $mode"
            Check ($state.Invokes -eq 1) 'exactly one invoke'
        } else {
            $failure=$null
            try { & $action } catch { $failure=$_.Exception.Message }
            Check ($null -ne $failure) "fails closed: $mode"
            $expected=if ($mode -in @('unverified','invokeerror','postchange')) { 1 } else { 0 }
            Check ($state.Invokes -eq $expected) "no retry or unsafe invoke: $mode"
            if ($mode -eq 'unverified') { Check ($state.Reads -eq 4) 'verification is bounded' }
            if ($mode -eq 'disabled') {
                Check ($state.Reads -eq 3) 'disabled pre-send polling is bounded'
                Check ($failure -like '*pre-send readiness timed out*Nothing was sent*') 'clear disabled timeout error'
            }
        }
    }
}
$popup=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar-popup.ps1'))
if ($popup -notmatch '\$geminiButton.AccessibleName = ''Send to Gemini Spark''') { throw 'accessible Gemini button missing' }
if ($popup -notmatch 'Start-ClipwarpGeminiSparkHandoff -Message \$Title') { throw 'original title wiring missing' }
if ($popup -match 'AcceptButton = \$geminiButton') { throw 'Gemini must not be default' }
if ($popup -notmatch '\$geminiButton.Add_MouseClick') { throw 'deliberate mouse activation required' }
# Execute only the extracted handler against fakes; never construct/show a popup.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($popup,[ref]$tokens,[ref]$errors)
$handler=$ast.Find({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$geminiButton' -and $n.Member.Value -eq 'Add_MouseClick' },$true)
if ($null -eq $handler) { throw 'Gemini click handler missing' }
$ancestor=$handler.Parent
while ($ancestor -and -not ($ancestor -is [Management.Automation.Language.IfStatementAst] -and $ancestor.Clauses[0].Item1.Extent.Text -eq '$Kind -eq ''Text''')) { $ancestor=$ancestor.Parent }
if (-not $ancestor) { throw 'Gemini button must be text-only' }
Add-Type -AssemblyName System.Windows.Forms
$record=New-Object Collections.Generic.List[string]
$form=New-Object psobject
$form | Add-Member ScriptMethod Hide { $record.Add('hide') }
$form | Add-Member ScriptMethod Close { $record.Add('close') }
$timer=New-Object psobject
$timer | Add-Member ScriptMethod Stop { $record.Add('stop') }
$geminiButton=[pscustomobject]@{ Enabled=$true }
$Title="  original`r`n" + [char]0x0E01 + "`t "
function Start-ClipwarpGeminiSparkHandoff { param($Message) if (-not [string]::Equals($Message,$Title,[StringComparison]::Ordinal)) { throw 'handler changed text' }; $record.Add('handoff') }
$callback=[scriptblock]::Create($handler.Arguments[0].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
$_=[pscustomobject]@{ Button=[Windows.Forms.MouseButtons]::Right }
& $callback
if ($record.Count) { throw 'right click must not submit' }
$_=[pscustomobject]@{ Button=[Windows.Forms.MouseButtons]::Left }
& $callback
if (($record -join ',') -ne 'stop,hide,handoff,close' -or $geminiButton.Enabled) { throw 'popup handoff sequence incorrect' }
Write-Host 'PASS: fake popup handler preserves original text and stops timer'
# Check scaled row placement and bottom clearance without a real window.
foreach ($dpi in @(96,120,144,192,384)) {
    $m=Get-ClipwarpPopupMetrics -Dpi $dpi
    $scale=$m.Width/400.0
    $gap=[int][Math]::Round(8*$scale)
    $bottom=$m.ButtonTop + 3*$m.ButtonHeight + 2*$gap + [int][Math]::Round(24*$scale)
    if ($bottom -gt ($m.Height + [int][Math]::Round(112*$scale))) { throw "Gemini layout clips at DPI $dpi" }
}
Write-Host 'PASS: scaled text popup accommodates Gemini row and hint'
