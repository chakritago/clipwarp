# Run a noninteractive Windows Forms Settings smoke check in an STA child process.
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Windows CI only' }
$root=Split-Path $PSScriptRoot -Parent
$gui=Join-Path $root 'clipwarp-rightlang-settings.ps1'
$program=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if(-not (Test-Path -LiteralPath $program)){throw 'Windows PowerShell missing'}
$process=New-Object Diagnostics.Process
$process.StartInfo=New-Object Diagnostics.ProcessStartInfo
$process.StartInfo.FileName=$program
$process.StartInfo.Arguments='-NoProfile -Sta -ExecutionPolicy Bypass -File "'+$gui+'" -SelfTest'
$process.StartInfo.UseShellExecute=$false
$process.StartInfo.CreateNoWindow=$true
$process.StartInfo.RedirectStandardOutput=$true
$process.StartInfo.RedirectStandardError=$true
[void]$process.Start()
$output=$process.StandardOutput.ReadToEnd()
$errors=$process.StandardError.ReadToEnd()
if(-not $process.WaitForExit(15000)) {
    try{$process.Kill()}catch{}
    throw 'Settings UI smoke test exceeded 15s timeout'
}
if($process.ExitCode -ne 0 -or $output -notmatch 'PASS: Thai Settings 2.0') {
    throw "Settings GUI smoke test failed: code=$($process.ExitCode) stdout=$output stderr=$errors"
}
Write-Host $output
Write-Host 'PASS: Settings 2.0 Windows STA GUI smoke test'
