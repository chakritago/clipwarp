$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    function Check($ok,$name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }
    $calls = New-Object Collections.Generic.List[string]
    $text = "  private`r`n" + [char]::ConvertFromUtf32(0x1F680)
    $result = Start-ClipwarpChatGptHandoff -Message $text -ExpectedSequence 123 -ClipboardWriter {
        param($value,$expected)
        Check ($value -ceq $text -and $expected -eq 123) 'guarded copy receives exact snapshot and sequence'
        $calls.Add('copy'); return 124
    } -BrowserStarter { param($url); Check ($url -eq 'https://chatgpt.com/?temporary-chat=true') 'URL contains no message'; $calls.Add('open') } -PageWaiter { throw 'must not wait' } -Submitter { throw 'must not submit' }
    Check (($calls -join ',') -eq 'copy,open') 'only explicit copy and open occur'
    Check ($result.Status -eq 'manual-required' -and $result.Copied -and $result.Opened -and -not $result.Sent) 'manual result never claims sent'
    $result = Start-ClipwarpChatGptHandoff -Message $text -ClipboardWriter { throw 'must not copy' } -BrowserStarter { throw 'must not open' }
    Check ($result.Status -eq 'cancelled') 'unknown sequence fails closed'
    $result = Start-ClipwarpChatGptHandoff -Message $text -ExpectedSequence 123 -ClipboardWriter { throw 'clipboard-changed' } -BrowserStarter { throw 'must not open' }
    Check ($result.Status -eq 'cancelled' -and -not $result.Opened) 'newer copy cancels browser handoff'
    $result = Start-ClipwarpChatGptHandoff -Message $text -ExpectedSequence 123 -ClipboardWriter { 124 } -BrowserStarter { throw 'private text must not escape' }
    Check ($result.Status -eq 'failed' -and $result.Copied -and -not $result.Opened -and $result.Reason -eq 'browser-open-failed') 'partial failure retains copy state without error content'
    $result = Send-ClipwarpChatGptMessage -Page ([pscustomobject]@{MainWindowHandle=123}) -Message $text -WindowActivator { throw 'must not activate' } -KeySender { throw 'must not send' } -Delay { throw 'must not delay' }
    Check ($result.Status -eq 'manual-required' -and -not $result.Sent) 'legacy send entrypoint fails closed'
    $source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1'))
    Check ($source -notmatch 'keybd_event|SendPasteAndEnter|SetForegroundWindow|AttachThreadInput') 'no global keyboard or activation native APIs remain'
    Initialize-ClipwarpActionClipboard
    Check ($null -ne ('ClipwarpTransport.ClipboardWriter' -as [type])) 'native writer compiles without calling clipboard APIs'
}
