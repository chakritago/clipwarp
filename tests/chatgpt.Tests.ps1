$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
# All elements and operations are fakes. Never enumerate desktop UI or use the clipboard.
& (Get-Module clipwarp-calendar) {
    function Check($condition, $name) { if (-not $condition) { throw $name }; Write-Host "PASS: $name" }
    # Load and inspect the exact framework APIs without touching AutomationElement.RootElement.
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Check ($null -ne [Windows.Automation.Automation].GetMethod('Compare', [type[]]@([Windows.Automation.AutomationElement],[Windows.Automation.AutomationElement]))) 'UIA identity API exists'
    function New-FakeElement($id, $name, $type, $pattern) {
        $element = [pscustomobject]@{ Current=[pscustomobject]@{ AutomationId=$id; Name=$name; ControlType=$type; IsOffscreen=$false; IsEnabled=$true }; Pattern=$pattern }
        $element | Add-Member ScriptMethod TryGetCurrentPattern { param($id,$output) $output.Value=$this.Pattern; return ($null -ne $this.Pattern) }
        return $element
    }
    $valuePattern = [pscustomobject]@{ Current=[pscustomobject]@{ IsReadOnly=$false; Value='' } }
    $composer = New-FakeElement 'prompt-textarea' 'Message ChatGPT' ([Windows.Automation.ControlType]::Edit) $valuePattern
    $send = New-FakeElement '' 'Send prompt' ([Windows.Automation.ControlType]::Button) ([pscustomobject]@{})
    $fakePage = [pscustomobject]@{ Elements=@($composer,$send) }
    $fakePage | Add-Member ScriptMethod FindAll { param($scope,$condition) return $this.Elements }
    Check ($null -ne (Get-ClipwarpChatGptControls $fakePage)) 'known composer and send patterns are identified'
    $fakePage.Elements=@($composer,$send,$composer)
    Check ($null -eq (Get-ClipwarpChatGptControls $fakePage)) 'ambiguous composers rejected'
    $fakePage.Elements=@($composer,$send)
    $send.Current.IsOffscreen=$true
    Check ($null -eq (Get-ClipwarpChatGptControls $fakePage)) 'hidden send rejected'
    $send.Current.IsOffscreen=$false
    $valuePattern.Current.IsReadOnly=$true
    Check ($null -eq (Get-ClipwarpChatGptControls $fakePage)) 'read-only composer rejected'
    $valuePattern.Current.IsReadOnly=$false
    $send.Pattern=$null
    Check ($null -eq (Get-ClipwarpChatGptControls $fakePage)) 'missing invoke pattern rejected'
    $send.Pattern=[pscustomobject]@{}
    $login = New-FakeElement '' 'Log in' ([Windows.Automation.ControlType]::Button) $null
    $fakePage.Elements=@($composer,$send,$login)
    try { Get-ClipwarpChatGptControls $fakePage; throw 'unexpected success' }
    catch { Check ($_.Exception.Message -like '*login screen*') 'visible login blocks available composer' }
    $state = @{ Polls=0; Delays=0 }
    $page = Wait-ClipwarpChatGptPage 'exact-url' -PageFinder {
        param($url)
        Check ($url -ceq 'exact-url') 'wait preserves target URL'
        $state.Polls++
        if ($state.Polls -eq 3) { 'page' }
    } -ControlFinder { 'controls' } -Delay { $state.Delays++ } -Attempts 3
    Check ($page -ceq 'page' -and $state.Delays -eq 2) 'wait retries until controls are ready'
    foreach ($scenario in @('missing page','missing controls','login')) {
        $state.Delays=0
        try {
            Wait-ClipwarpChatGptPage 'url' -PageFinder { if ($scenario -ne 'missing page') { 'page' } } -ControlFinder {
                if ($scenario -eq 'login') { throw 'login shown' }
            } -Delay { $state.Delays++ } -Attempts 2
            throw 'unexpected success'
        } catch { Check ($_.Exception.Message -ne 'unexpected success') "$scenario fails closed" }
        if ($scenario -eq 'login') { Check ($state.Delays -eq 0) 'login stops immediately' }
        else { Check ($state.Delays -eq 2) 'readiness wait is bounded' }
    }
    $message = " `t`r`n" + [char]0x4F60 + [char]0x597D + "`nlast line  `r`n"
    foreach ($scenario in @('success','draft','changed page','missing controls','normalized','disabled','write failure','invoke failure')) {
        $state = @{ Writes=0; Sends=0; Delays=0 }
        $value = [pscustomobject]@{ Current=[pscustomobject]@{ Value='' } }
        if ($scenario -eq 'draft') { $value.Current.Value='draft' }
        $value | Add-Member ScriptMethod SetValue {
            param($text)
            $state.Writes++
            if ($scenario -eq 'write failure') { throw 'write failed' }
            $this.Current.Value = $text
            if ($scenario -eq 'normalized') { $this.Current.Value=$text.Trim() }
        }
        $invoke = [pscustomobject]@{}
        $invoke | Add-Member ScriptMethod Invoke {
            $state.Sends++; $value.Current.Value=''
            if ($scenario -eq 'invoke failure') { throw 'invoke failed' }
        }
        $controls = [pscustomobject]@{ Value=$value; Button=[pscustomobject]@{ Current=[pscustomobject]@{ IsEnabled=($scenario -ne 'disabled') } }; Invoke=$invoke }
        $failed=$false
        try {
            Send-ClipwarpChatGptMessage 'page' $message -PageFinder { if ($scenario -eq 'changed page') { 'other' } else { 'page' } } -PageComparer { param($a,$b) $a -ceq $b } -ControlFinder { if ($scenario -ne 'missing controls') { $controls } } -Delay { $state.Delays++ }
        } catch { $failed=$true }
        Check ($failed -eq ($scenario -ne 'success')) "$scenario reports expected outcome"
        $expectedSends=0
        if ($scenario -in @('success','invoke failure')) { $expectedSends=1 }
        Check ($state.Sends -eq $expectedSends) "$scenario never sends unexpectedly or retries send"
        if ($scenario -eq 'success') { Check ($value.Current.Value -ceq '') 'submission clears composer' }
        if ($scenario -in @('draft','changed page','missing controls')) { Check ($state.Writes -eq 0) "$scenario prevents fill" }
        if ($scenario -eq 'disabled') { Check ($state.Delays -eq 20) 'disabled send wait is bounded' }
    }
}
