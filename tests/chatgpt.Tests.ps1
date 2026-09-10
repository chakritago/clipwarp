$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    function Check($ok, $name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }

    # Test Send-ClipwarpChatGptMessage invokes window activation and key sending
    $state = @{ ActivatedPage=$null; SentMessage=$null }
    $fakePage = [pscustomobject]@{ MainWindowHandle=[IntPtr]5678 }
    $testMsg = "Hello ChatGPT `r`n" + [char]0x4F60 + " line 2"

    Send-ClipwarpChatGptMessage -Page $fakePage -Message $testMsg `
        -WindowActivator { param($p) $state.ActivatedPage = $p } `
        -KeySender { param($m) $state.SentMessage = $m } `
        -Delay { }

    Check ($state.ActivatedPage -eq $fakePage) 'window activator receives target page'
    Check ($state.SentMessage -eq $testMsg) 'key sender receives exact original message'

    # Test Start-ClipwarpChatGptHandoff full workflow
    $calls = New-Object Collections.Generic.List[object]
    Start-ClipwarpChatGptHandoff -Message $testMsg `
        -ClipboardWriter { param($v) $calls.Add([pscustomobject]@{ Kind='clip'; Value=$v }) } `
        -BrowserStarter { param($v) $calls.Add([pscustomobject]@{ Kind='browser'; Value=$v }) } `
        -PageWaiter { param($u) $calls.Add([pscustomobject]@{ Kind='wait'; Value=$u }); $fakePage } `
        -Submitter { param($p, $m) $calls.Add([pscustomobject]@{ Kind='submit'; Page=$p; Message=$m }) }

    Check ($calls.Count -eq 4) 'handoff runs exactly 4 steps'
    Check ($calls[0].Kind -eq 'clip' -and $calls[0].Value -eq $testMsg) 'handoff writes clipboard first'
    Check ($calls[1].Kind -eq 'browser' -and $calls[1].Value -eq 'https://chatgpt.com/?temporary-chat=true') 'handoff starts browser with temporary chat URL'
    Check ($calls[2].Kind -eq 'wait') 'handoff waits for page'
    Check ($calls[3].Kind -eq 'submit' -and $calls[3].Page -eq $fakePage -and $calls[3].Message -eq $testMsg) 'handoff submits page and message'

    # Test failure propagation
    $failed = $false
    try {
        Start-ClipwarpChatGptHandoff -Message $testMsg -ClipboardWriter { throw 'clip err' }
    } catch {
        if ($_.Exception.Message -like '*clip err*') { $failed = $true }
    }
    Check $failed 'clipboard failure propagates'

    $failed = $false
    try {
        Start-ClipwarpChatGptHandoff -Message $testMsg `
            -ClipboardWriter { } `
            -BrowserStarter { } `
            -PageWaiter { throw 'wait err' }
    } catch {
        if ($_.Exception.Message -like '*wait err*') { $failed = $true }
    }
    Check $failed 'waiter failure propagates'

    $failed = $false
    try {
        Start-ClipwarpChatGptHandoff -Message $testMsg `
            -ClipboardWriter { } `
            -BrowserStarter { } `
            -PageWaiter { $fakePage } `
            -Submitter { throw 'submit err' }
    } catch {
        if ($_.Exception.Message -like '*submit err*') { $failed = $true }
    }
    Check $failed 'submitter failure propagates'
}
