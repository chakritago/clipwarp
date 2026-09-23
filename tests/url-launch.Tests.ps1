$ErrorActionPreference = 'Stop'
# Replace only the OS process boundary in an in-memory module. Never launch a browser.
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
public static class ClipwarpUrlLaunchProbe {
    public static Action<ProcessStartInfo> OnStart;
    public static object Start(ProcessStartInfo info) { OnStart(info); return null; }
}
"@
$source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1'))
$source = $source.Replace('[Diagnostics.Process]::Start(', '[ClipwarpUrlLaunchProbe]::Start(')
$module = New-Module -Name ClipwarpUrlTests -ScriptBlock ([scriptblock]::Create($source))
& $module {
    function Check($ok, $name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }
    $calls = New-Object Collections.Generic.List[string]
    $state = @{ PrimaryFails=$true; FallbackFails=$false; Url='https://gemini.google.com/spark' }
    [ClipwarpUrlLaunchProbe]::OnStart = {
        param($info)
        $calls.Add('primary')
        Check ($info.FileName -ceq $state.Url) 'primary preserves exact URL'
        Check $info.UseShellExecute 'primary uses shell URL association'
        if ($state.PrimaryFails) { throw 'The system cannot find the file specified.' }
        Check ($info.Verb -ceq 'open') 'primary explicitly opens URL'
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $ErrorAction, $WindowStyle)
        $calls.Add('fallback')
        Check ($FilePath -ceq (Join-Path $env:WINDIR 'System32\rundll32.exe')) 'fallback uses absolute OS handler'
        Check ($ArgumentList.Count -eq 2 -and $ArgumentList[0] -ceq 'url.dll,FileProtocolHandler' -and $ArgumentList[1] -ceq $state.Url) 'fallback preserves exact URL as separate argument'
        Check ($ErrorAction -eq 'Stop') 'fallback errors terminate'
        Check ($WindowStyle -eq 'Hidden') 'fallback helper stays hidden'
        if ($state.FallbackFails) { throw 'private process failure details' }
    }
    function Start-Sleep { param($Milliseconds) $calls.Add("delay:$Milliseconds") }
    $message = "  private message`r`nC:\private\image.png  "
    foreach ($target in @('GeminiSpark','ChatGpt')) {
        if ($target -eq 'ChatGpt') { $state.Url='https://chatgpt.com/?temporary-chat=true' }
        foreach ($mode in @('recovery','primary','failure')) {
            $calls.Clear()
            $state.PrimaryFails = $mode -ne 'primary'
            $state.FallbackFails = $mode -eq 'failure'
            $errorMessage = $null
            try {
                & "Start-Clipwarp${target}Handoff" -Message $message -ClipboardWriter {
                    param($v) Check ($v -ceq $message) 'clipboard text unchanged'; $calls.Add('clipboard')
                } -PageWaiter {
                    param($u) Check ($u -ceq $state.Url) 'wait URL unchanged'; $calls.Add('wait'); 'page'
                } -Submitter {
                    param($p,$m) Check ($p -ceq 'page' -and $m -ceq $message) 'submission unchanged'; $calls.Add('submit')
                }
            } catch { $errorMessage=$_.Exception.Message }
            if ($mode -eq 'failure') {
                Check ($errorMessage -like '*Unable to open*HTTPS URL*' -and $errorMessage -notlike '*private*') 'all strategies fail clearly without private details'
                Check (($calls -join ',') -ceq 'clipboard,primary,fallback') "$target launch failure prevents wait and send"
            } else {
                Check ($null -eq $errorMessage) "$target $mode launch succeeds after simulated primary result"
                $expected='clipboard,primary'
                if ($mode -eq 'recovery') { $expected+=',fallback' }
                $expected+=',wait'
                if ($target -eq 'GeminiSpark') { $expected+=',delay:2500' }
                if ($target -eq 'ChatGpt') { $expected+=',delay:2500' }
                $expected+=',submit'
                Check (($calls -join ',') -ceq $expected) "$target $mode handoff ordering and no unnecessary fallback"
            }
        }
    }
    foreach ($url in @('http://gemini.google.com/spark','https://gemini.google.com/spark/','https://gemini.google.com/spark?x=1','https://gemini.google.com/spark#x','https://gemini.google.com.evil/spark','https://GEMINI.google.com/spark','https://chatgpt.com/','https://gemini.google.com/spark" & calc')) {
        $calls.Clear(); $failed=$false
        try { Open-ClipwarpExternalUrl -Url $url } catch { $failed=$true }
        Check ($failed -and $calls.Count -eq 0) 'non-allowlisted URL rejected before any launch'
    }
    [ClipwarpUrlLaunchProbe]::OnStart=$null
}