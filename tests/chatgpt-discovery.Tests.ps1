$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    function Check($ok, $name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }

    # Test Find-ClipwarpChatGptPage matching browser and title
    $validProc = [pscustomobject]@{ ProcessName='msedge'; MainWindowTitle='ChatGPT: Chat, Work'; MainWindowHandle=[IntPtr]1234 }
    $found = Find-ClipwarpChatGptPage -Url 'any' -ProcessFinder { @($validProc) }
    Check ($found -eq $validProc) 'matching browser and title is discovered'

    $nonBrowser = [pscustomobject]@{ ProcessName='notepad'; MainWindowTitle='ChatGPT notes'; MainWindowHandle=[IntPtr]1234 }
    $foundNonBrowser = Find-ClipwarpChatGptPage -Url 'any' -ProcessFinder { @($nonBrowser) }
    Check ($null -eq $foundNonBrowser) 'non-browser process is ignored'

    $nonChatGpt = [pscustomobject]@{ ProcessName='chrome'; MainWindowTitle='Google Search'; MainWindowHandle=[IntPtr]1234 }
    $foundNonChatGpt = Find-ClipwarpChatGptPage -Url 'any' -ProcessFinder { @($nonChatGpt) }
    Check ($null -eq $foundNonChatGpt) 'browser with different title is ignored'

    $zeroHandle = [pscustomobject]@{ ProcessName='msedge'; MainWindowTitle='ChatGPT'; MainWindowHandle=[IntPtr]::Zero }
    $foundZero = Find-ClipwarpChatGptPage -Url 'any' -ProcessFinder { @($zeroHandle) }
    Check ($null -eq $foundZero) 'process with zero MainWindowHandle is ignored'

    # Test Wait-ClipwarpChatGptPage polling and retry
    $state = @{ Polls = 0 }
    $waited = Wait-ClipwarpChatGptPage -Url 'test' -PageFinder {
        $state.Polls++
        if ($state.Polls -ge 3) { $validProc } else { $null }
    } -Delay { } -Attempts 5
    Check ($waited -eq $validProc -and $state.Polls -eq 3) 'wait retries until window appears'

    # Test Wait-ClipwarpChatGptPage timeout failure
    $failed = $false
    try {
        Wait-ClipwarpChatGptPage -Url 'test' -PageFinder { $null } -Delay { } -Attempts 3
    } catch {
        $failed = $true
    }
    Check $failed 'wait fails closed when window is not found'
}
