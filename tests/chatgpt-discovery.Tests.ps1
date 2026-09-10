$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    foreach ($processName in @('msedge','chrome','notepad')) {
        $fake = [pscustomobject]@{ProcessName=$processName; MainWindowTitle='ChatGPT'; MainWindowHandle=[IntPtr]1234; Url='https://chatgpt.com/?temporary-chat=true'}
        $page = Find-ClipwarpChatGptPage -Url 'https://chatgpt.com/?temporary-chat=true' -ProcessFinder { $fake }
        if ($null -ne $page) { throw 'An unverified process/title must not prove browser page identity' }
    }
    $failed=$false
    try { Wait-ClipwarpChatGptPage -Url 'test' -PageFinder { $null } -Delay {} -Attempts 2 } catch { $failed=$true }
    if (-not $failed) { throw 'No verified page must fail closed' }
    Write-Host 'PASS: process/title discovery never authorizes browser automation'
}
