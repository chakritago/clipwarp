$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    # Never fall through to desktop discovery when the injection seam is absent.
    $finderParameters = (Get-Command Find-ClipwarpChatGptPage).Parameters
    if (-not $finderParameters.ContainsKey('WindowFinder') -or -not $finderParameters.ContainsKey('ProcessFinder')) { throw 'RED: discovery requires injectable window/process fixtures' }
    $failures = @()
    function Check($ok, $name) { if (-not $ok) { throw $name } }
    function Element($type, $id, $name, $pattern) {
        $e = [pscustomobject]@{ Current=[pscustomobject]@{ ControlType=$type; AutomationId=$id; Name=$name; IsEnabled=$true; IsOffscreen=$false; ProcessId=123 }; Pattern=$pattern; Elements=@() }
        $e | Add-Member ScriptMethod TryGetCurrentPattern { param($p,$output) $output.Value=$this.Pattern; return ($null -ne $this.Pattern) }
        $e | Add-Member ScriptMethod FindAll { param($scope,$condition) return $this.Elements }
        $e
    }
    $url = New-ClipwarpChatGptUrl
    $decomposed = 'e' + [char]0x301
    $composed = [string][char]0xE9
    foreach ($scenario in @('match','wrong URL','no match','multiple','Unicode URL','null URL','success','no clear','post page change','post missing controls','null cleared','Unicode message','draft')) {
        try {
            $state = @{ Sends=0; Delays=0; Written=$null }
            $value = [pscustomobject]@{ Current=[pscustomobject]@{ Value=''; IsReadOnly=$false } }
            if ($scenario -eq 'draft') { $value.Current.Value='draft' }
            $value | Add-Member ScriptMethod SetValue { param($text) $state.Written=$text; $this.Current.Value=$text; if ($scenario -eq 'Unicode message') { $this.Current.Value=$composed } }
            $invoke = [pscustomobject]@{}
            $invoke | Add-Member ScriptMethod Invoke { $state.Sends++ }
            $composer = Element ([Windows.Automation.ControlType]::Edit) 'prompt-textarea' 'Message ChatGPT' $value
            $send = Element ([Windows.Automation.ControlType]::Button) '' 'Send prompt' $invoke
            $document = Element ([Windows.Automation.ControlType]::Document) '' 'ChatGPT' ([pscustomobject]@{ Current=[pscustomobject]@{ Value=$url } })
            $document.Elements=@($composer,$send)
            $window = Element ([Windows.Automation.ControlType]::Window) '' 'ChatGPT' $null
            $window.Elements=@($document)
            $windows=@($window)
            $target=$url
            switch ($scenario) {
                'wrong URL' { $document.Pattern.Current.Value=$url+'#wrong' }
                'null URL' { $document.Pattern.Current.Value=$null }
                'no match' { $windows=@() }
                'multiple' { $window.Elements=@($document,$document) }
                'Unicode URL' { $target=$url+$decomposed; $document.Pattern.Current.Value=$url+$composed }
            }
            $finder = { param($u) Find-ClipwarpChatGptPage -Url $target -WindowFinder { $windows } -ProcessFinder { param($id) [pscustomobject]@{ ProcessName='chrome' } } }
            if ($scenario -in @('match','wrong URL','no match','multiple','Unicode URL','null URL')) {
                $errorText=$null; $found=$null
                try { $found=& $finder } catch { $errorText=$_.Exception.Message }
                if ($scenario -eq 'multiple') { Check ($errorText -like '*Multiple temporary*') 'ambiguous discovery must throw' }
                else {
                    Check ($null -eq $errorText) "discovery error: $errorText"
                    if ($scenario -eq 'match') { Check ([object]::ReferenceEquals($found,$document)) 'must return the matching Document object' }
                    else { Check ($null -eq $found) 'non-exact document must be rejected' }
                }
            } else {
                $page=Wait-ClipwarpChatGptPage $url -PageFinder $finder -Delay { throw 'unexpected readiness delay' } -Attempts 1
                $message=" `t`r`noriginal " + $decomposed + "`nlast  `r`n"
                if ($scenario -eq 'Unicode message') { $message=$decomposed }
                $errorText=$null
                try {
                    Send-ClipwarpChatGptMessage $page $message -PageFinder $finder -PageComparer { param($a,$b) [object]::ReferenceEquals($a,$b) } -VerificationAttempts 3 -Delay {
                        $state.Delays++
                        if ($state.Sends -gt 0) {
                            switch ($scenario) {
                                'success' { if ($state.Delays -eq 2) { $value.Current.Value='' } }
                                'post page change' { $document.Pattern.Current.Value=$url+'#changed' }
                                'post missing controls' { $document.Elements=@() }
                                'null cleared' { $value.Current.Value=$null }
                            }
                        }
                    }
                } catch { $errorText=$_.Exception.Message }
                if ($scenario -eq 'success') {
                    Check ($null -eq $errorText) "success failed: $errorText"
                    Check ([string]::Equals($state.Written,$message,[StringComparison]::Ordinal)) 'full original message must be written'
                    Check ($state.Delays -eq 2) 'success must wait to observe clearing'
                } else { Check ($null -ne $errorText) 'must fail closed' }
                if ($scenario -in @('draft','Unicode message')) { Check ($state.Sends -eq 0) 'must not invoke' }
                else {
                    Check ($state.Sends -eq 1) 'must invoke exactly once without retry'
                    if ($scenario -ne 'success') { Check ($errorText -like '*could not confirm submission*') "clear verification error required: $errorText" }
                }
                if ($scenario -in @('no clear','post missing controls','null cleared')) { Check ($state.Delays -le 3) 'verification must be bounded' }
            }
            Write-Host "PASS: $scenario"
        } catch { $failures += "$scenario : $_"; Write-Host "FAIL: $scenario : $_" }
    }
    if ($failures.Count) { throw ($failures -join "`n") }
}
