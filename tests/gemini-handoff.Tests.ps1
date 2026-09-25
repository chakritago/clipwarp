$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    function Check($ok,$name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }
    function Window($handle=42,$title='Google Gemini - Microsoft Edge',$process='msedge') {
        [pscustomobject]@{ MainWindowHandle=[IntPtr]$handle; MainWindowTitle=$title; ProcessName=$process; ProcessId=7; ProcessStarted=123; Visible=$true }
    }
    $page = Window
    $message = " `tHello`r`n" + [char]0x4F60 + [char]0x0E01 + [char]::ConvertFromUtf32(0x1F680) + "`n  "
    $events = New-Object Collections.Generic.List[string]
    $state = @{}
    function Reset {
        $events.Clear(); $state.Clear()
        $state.Activate=$true; $state.Foreground=[IntPtr]42; $state.Window=$page
        $state.Clipboard=$message; $state.Focused=$false; $state.Reads=0; $state.ReadyAfter=1
        $state.TargetId='composer'; $state.FailAt=''; $state.AfterPaste=''; $state.DuringRead=''; $state.ClipboardReads=0
    }
    $send = @{
        Page=$page; Message=$message
        WindowFinder={ $state.Window }
        WindowActivator={ param($p) $events.Add('activate'); $state.Activate }
        TargetReader={ $state.Reads++; if ($state.Reads -ge $state.ReadyAfter) { [pscustomobject]@{ Id=$state.TargetId; Focused=$state.Focused } } }
        ComposerFocuser={ param($target) $events.Add('focus'); $state.Focused=$true }
        ForegroundReader={ $state.Foreground }
        ClipboardReader={
            $events.Add('read-clipboard'); $state.ClipboardReads++
            switch ($state.DuringRead) {
                'focus' { $state.Focused=$false }
                'foreground' { $state.Foreground=[IntPtr]999 }
                'composer' { $state.TargetId='replacement' }
                'window' { $state.Window=Window 43 }
            }
            $state.Clipboard
        }
        Delay={ param($ms) $events.Add("delay:$ms") }
        KeySender={
            param($action,$p)
            Check ($p.MainWindowHandle -eq 42) 'keys receive exact HWND'
            $events.Add($action)
            if ($state.FailAt -eq $action) { throw 'fake key failure' }
            if ($action -eq 'Paste') {
                switch ($state.AfterPaste) {
                    'window' { $state.Window=Window 43 }
                    'focus' { $state.Foreground=[IntPtr]999 }
                    'composer' { $state.TargetId='replacement' }
                    'clipboard' { $state.Clipboard=$message.Trim() }
                    'composer-focus' { $state.Focused=$false }
                }
            }
        }
    }
    # Run every regression before reporting RED so both race gaps are exercised.
    $regressions=New-Object Collections.Generic.List[string]
    foreach ($change in @('focus','foreground','composer','window')) {
        Reset; $state.DuringRead=$change; $failed=$false
        try { Send-ClipwarpGeminiSparkMessage @send } catch { $failed=$true }
        if (-not ($failed -and 'Paste' -notin $events -and 'Enter' -notin $events)) { $regressions.Add("$change during clipboard read allowed input") }
    }
    Reset; $state.AfterPaste='clipboard'; $failed=$false
    try { Send-ClipwarpGeminiSparkMessage @send } catch { $failed=$true }
    if (-not ($failed -and @($events | Where-Object { $_ -eq 'Paste' }).Count -eq 1 -and 'Enter' -notin $events)) { $regressions.Add('clipboard change after Paste allowed Enter') }
    Check ($regressions.Count -eq 0) ("clipboard race regressions: " + ($regressions -join '; '))
    Reset; $state.Activate=$false; $failed=$false
    try { Send-ClipwarpGeminiSparkMessage @send } catch { $failed=$_.Exception.Message -like '*activate*' }
    Check ($failed -and 'Paste' -notin $events -and 'Enter' -notin $events) 'RED regression now GREEN: failed activation prevents paste/send'
    Reset
    Start-ClipwarpGeminiSparkHandoff -Message $message -ClipboardWriter {
        param($v) Check ([string]::Equals($v,$message,[StringComparison]::Ordinal)) 'exact multiline Unicode whitespace'; $events.Add('clipboard')
    } -BrowserStarter {
        param($u) Check ($u -ceq 'https://gemini.google.com/spark') 'exact Spark URL'; $events.Add('browser')
    } -PageWaiter { $events.Add('wait'); $page } -Delay { param($ms) $events.Add("delay:$ms") } -Submitter {
        param($p,$m) Check ([string]::Equals($m,$message,[StringComparison]::Ordinal)) 'original text reaches submit'
        Send-ClipwarpGeminiSparkMessage @send
    }
    Check (($events -join ',') -ceq 'clipboard,browser,wait,delay:2500,activate,delay:300,focus,delay:300,read-clipboard,Paste,delay:600,read-clipboard,Enter') 'clipboard/browser/wait/activate/focus/paste/Enter order and exactly one send'
    Reset; $state.ReadyAfter=3
    Send-ClipwarpGeminiSparkMessage @send
    Check (@($events | Where-Object { $_ -eq 'delay:250' }).Count -eq 2 -and @($events | Where-Object { $_ -eq 'Enter' }).Count -eq 1) 'delayed hydration waits without repeating input'
    foreach ($failure in @('window','owner','generation','foreground','clipboard','composer','timeout','Paste','Enter')) {
        Reset
        switch ($failure) {
            'window' { $state.Window=Window 43 }
            'owner' { $state.Window=Window; $state.Window.ProcessId=8 }
            'generation' { $state.Window=Window; $state.Window.ProcessStarted=456 }
            'foreground' { $state.Foreground=[IntPtr]999 }
            'clipboard' { $state.Clipboard=$message.Trim() }
            'composer' { $send.ComposerFocuser={ $state.Focused=$false } }
            'timeout' { $state.ReadyAfter=100 }
            default { $state.FailAt=$failure }
        }
        $failed=$false
        try { Send-ClipwarpGeminiSparkMessage @send -Attempts 3 } catch { $failed=$true }
        Check $failed "$failure propagates failure"
        $pastes=0; $enters=0
        if ($failure -in @('Paste','Enter')) { $pastes=1 }
        if ($failure -eq 'Enter') { $enters=1 }
        Check (@($events | Where-Object { $_ -eq 'Paste' }).Count -eq $pastes -and @($events | Where-Object { $_ -eq 'Enter' }).Count -eq $enters) "$failure never retries or types elsewhere"
        $send.ComposerFocuser={ param($target) $events.Add('focus'); $state.Focused=$true }
    }
    foreach ($change in @('window','focus','composer','composer-focus','clipboard')) {
        Reset; $state.AfterPaste=$change; $failed=$false
        try { Send-ClipwarpGeminiSparkMessage @send } catch { $failed=$true }
        Check ($failed -and @($events | Where-Object { $_ -eq 'Paste' }).Count -eq 1 -and 'Enter' -notin $events) "$change after paste prevents Enter"
    }
    $poll = @{ Count=0 }
    $found = Wait-ClipwarpGeminiSparkPage -Attempts 5 -Delay { } -PageFinder {
        $poll.Count++
        $windows = @((Window 3 'Gemini notes' 'notepad'), (Window 4 'Gemini - PowerShell' 'pwsh'), (Window 5 'Research about Gemini - Google Chrome' 'chrome'))
        if ($poll.Count -eq 2) { $windows += Window 42 'Loading...' }
        if ($poll.Count -ge 3) { $windows += Window 43 'Spark - Google Chrome' 'chrome' }
        Find-ClipwarpGeminiSparkPage -ProcessFinder { $windows }
    }
    Check ($poll.Count -eq 3 -and $found.MainWindowHandle -eq 43) 'delayed title and replacement HWND discovered past false positives'
    foreach ($browser in @('chrome','msedge','firefox','brave','opera','vivaldi','arc','zen','chromium')) {
        $found = Find-ClipwarpGeminiSparkPage -ProcessFinder { Window 42 'Gemini - profile' $browser }
        Check ($found.MainWindowHandle -eq 42) "$browser supported"
    }
    foreach ($invalid in @('hidden','zero','owner','title')) {
        $candidate=Window
        switch ($invalid) {
            'hidden' { $candidate.Visible=$false }
            'zero' { $candidate.MainWindowHandle=[IntPtr]::Zero }
            'owner' { $candidate.ProcessId=0 }
            'title' { $candidate.MainWindowTitle='Gemini notes' }
        }
        Check ($null -eq (Find-ClipwarpGeminiSparkPage -ProcessFinder { $candidate })) "$invalid window rejected"
    }
    $failed=$false
    try { Find-ClipwarpGeminiSparkPage -ProcessFinder { (Window 42); (Window 43) } } catch { $failed=$true }
    Check $failed 'ambiguous windows fail closed'
    $clip = @{ Writes=0; Value=$null; Existing=$message.Trim() }
    Set-ClipwarpGeminiClipboardText -Value $message -Reader { $clip.Existing } -Writer { param($v) $clip.Writes++; $clip.Value=$v }
    Check ($clip.Writes -eq 1 -and [string]::Equals($clip.Value,$message,[StringComparison]::Ordinal)) 'whitespace difference written exactly'
    $clip.Existing=$message
    Set-ClipwarpGeminiClipboardText -Value $message -Reader { $clip.Existing } -Writer { throw 'must not rewrite identical clipboard' }
    $clip.Existing=$message.Replace("`r`n","`n")
    Set-ClipwarpGeminiClipboardText -Value $message -Reader { $clip.Existing } -Writer { param($v) $clip.Writes++; $clip.Value=$v }
    Check ($clip.Writes -eq 2 -and [string]::Equals($clip.Value,$message,[StringComparison]::Ordinal)) 'line endings not normalized'
    foreach ($stage in @('clipboard','browser','wait','submit')) {
        $calls=New-Object Collections.Generic.List[string]; $failed=$false
        try {
            Start-ClipwarpGeminiSparkHandoff -Message $message -Delay { } -ClipboardWriter {
                $calls.Add('clipboard'); if ($stage -eq 'clipboard') { throw 'fake clipboard' }
            } -BrowserStarter {
                $calls.Add('browser'); if ($stage -eq 'browser') { throw 'fake browser' }
            } -PageWaiter {
                $calls.Add('wait'); if ($stage -eq 'wait') { throw 'fake wait' }; $page
            } -Submitter { $calls.Add('submit'); throw 'fake submit' }
        } catch { $failed=$_.Exception.Message -eq "fake $stage" }
        $expected=@('clipboard','browser','wait','submit'); $last=[array]::IndexOf($expected,$stage)
        Check ($failed -and ($calls -join ',') -eq ($expected[0..$last] -join ',')) "$stage failure stops subsequent stages"
    }
}
