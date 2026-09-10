$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-support.psm1') -Force
function Assert($Value,$Message){if(-not $Value){throw $Message};Write-Host "PASS: $Message"}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-config-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$children=@()
try {
    $p=Join-Path $temp 'config.json'
    Assert ((Get-ClipwarpConfigStatus $p).Status -eq 'missing') 'missing config uses defaults'
    [IO.File]::WriteAllText($p,'{"version":1,"calendar":{"enabled":false},"custom":{"keep":"yes"}}')
    Set-ClipwarpTargetMode dual $p | Out-Null
    $c=Get-ClipwarpConfig $p
    Assert (-not $c.actions.enabled -and -not $c.actions.calendar -and -not $c.actions.chatgpt -and -not $c.actions.runCommand) 'legacy disabled calendar migrates all previously disabled actions off'
    Set-ClipwarpActionEnabled chatgpt $true $p
    Set-ClipwarpActionEnabled enabled $true $p
    Assert ((Get-ClipwarpActionEnabled chatgpt $p) -and -not (Get-ClipwarpCalendarEnabled $p)) 'independent actions do not reenable calendar'
    Assert ((Get-ClipwarpConfig $p).custom.keep -eq 'yes') 'unknown fields survive RMW'
    Set-ClipwarpPaused $true $p
    Assert (Test-Path ($p+'.bak')) 'atomic update stores validated prior configuration'
    [IO.File]::WriteAllText($p,'{broken')
    Assert ((Get-ClipwarpConfigStatus $p).Status -eq 'backup') 'corrupt primary uses validated backup'
    Set-ClipwarpTargetMode text $p | Out-Null
    Assert (@(Get-ChildItem -LiteralPath $temp -Filter '*.corrupt-*').Count -eq 1) 'recovered writes preserve corrupt evidence'
    Assert (-not (Get-ClipwarpCalendarEnabled $p)) 'backup recovery preserves disabled calendar'
    $bad=Join-Path $temp 'bad.json'
    foreach($json in @('{broken','{"paused":"false"}','{"paused":false,"paused":true}','{"calendar":null}','{"version":99}','{"retention":{"maxBytes":-1}}','{"actions":{"enabled":null}}')){
        [IO.File]::WriteAllText($bad,$json)
        $s=Get-ClipwarpConfigStatus $bad
        Assert (-not $s.IsUsable -and $s.Paused -and -not $s.ActionsEnabled) 'invalid JSON/schema fails closed'
        $threw=$false;try{Set-ClipwarpPaused $false $bad}catch{$threw=$true}
        Assert ($threw -and [IO.File]::ReadAllText($bad) -eq $json) 'setter refuses corrupt overwrite'
    }
    $lock=New-Object IO.FileStream($p,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Assert ((Get-ClipwarpConfigStatus $p).Status -eq 'backup') 'unreadable primary uses validated backup' } finally {$lock.Dispose()}
    Set-ClipwarpTargetMode auto $p | Out-Null
    Set-ClipwarpTargetOverride chrome.exe text $p
    $decision=Get-ClipwarpTargetExplanation -ProcessName CHROME -WindowTitle 'page' -ConfigPath $p
    Assert ($decision.Mode -eq 'text' -and $decision.MatchedRule -eq 'config.targetOverrides.chrome') 'process override is exact case-insensitive and explainable'
    Assert ((Get-ClipwarpTargetExplanation -ProcessName chrome -TargetMode web -ConfigPath $p).Mode -eq 'image-only') 'explicit argument outranks process override'
    Assert ((Get-ClipwarpTargetExplanation -ProcessName chrome -WindowTitle 'unknown language' -WindowClass '#32770' -HasFilePickerControls $true -ConfigPath (Join-Path $temp 'missing.json')).MatchedRule -eq 'target.filePickerControls') 'child-control evidence is shared classification input'
    $shared=Join-Path $temp 'concurrent.json'
    $engine=(Get-Process -Id $PID).Path
    foreach($entry in @(@('paused','$true'),@('targetMode',"'dual'"),@('calendar.defaultDurationMinutes','45'),@('retentionDays','12'))){
        $code="Import-Module '$($root.Replace("'","''"))/clipwarp-support.psm1'; 1..12 | ForEach-Object { Set-ClipwarpConfigProperty -Name '$($entry[0])' -Value $($entry[1]) -ConfigPath '$shared' }"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $children+=Start-Process -FilePath $engine -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -PassThru -WindowStyle Hidden
    }
    foreach($child in $children){Assert ($child.WaitForExit(60000)) 'config writer completes in bounded time';Assert ($child.ExitCode -eq 0) 'config writer succeeds'}
    $c=Get-ClipwarpConfig $shared
    Assert ($c.paused -and $c.targetMode -eq 'dual' -and $c.calendar.defaultDurationMinutes -eq 45 -and $c.retentionDays -eq 12) 'concurrent setters do not lose unrelated updates'
    Assert (@(Get-ChildItem $temp -Filter '.clipwarp-config-*.tmp').Count -eq 0) 'atomic writes leave no temp artifacts'
} finally {
    foreach($child in $children){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'All config tests passed.'
