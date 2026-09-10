$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-support.psm1') -Force
function Assert($Value,$Message){if(-not $Value){throw $Message};Write-Host "PASS: $Message"}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-storage-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$owned=@()
try {
    $out=Join-Path $temp 'images';$config=Join-Path $temp 'config.json'
    1..6 | ForEach-Object {
        $o=New-ClipwarpManagedImageFile $out
        $owned+=$o;$o.Stream.Write([byte[]](1,2,3,4),0,4);$o.Stream.Dispose()
        [IO.File]::SetLastWriteTimeUtc($o.Path,[datetime]::UtcNow.AddDays(-$_))
    }
    Assert (@($owned.Path | Select-Object -Unique).Count -eq 6) 'exclusive managed creation produces unique names'
    [IO.File]::WriteAllText((Join-Path $out 'clip-user-notes.png'),'keep')
    [void][IO.Directory]::CreateDirectory((Join-Path $out 'nested'))
    [IO.File]::WriteAllText((Join-Path $out 'nested/clip-20260101-000000-000.png'),'keep')
    Assert (@(Get-ClipwarpHistory $out -Limit 2).Count -eq 2) 'history is bounded'
    Assert (@(Get-ClipwarpHistory $out -Limit 100).Count -eq 6) 'history excludes arbitrary prefixed and nested files'
    Assert (@(Get-ClipwarpRetentionPreview $out $config).Count -eq 0) 'retention is opt-in'
    Set-ClipwarpRetentionPolicy -Enabled $true -MaxCount 2 -ConfigPath $config
    $preview=@(Get-ClipwarpRetentionPreview $out $config)
    Assert ($preview.Count -eq 4 -and $preview[0].Reason -eq 'count') 'count cap selects oldest excess files'
    Invoke-ClipwarpRetention $out $config -WhatIf | Out-Null
    Assert (@(Get-ClipwarpHistory $out -Limit 100).Count -eq 6) 'retention WhatIf is read-only'
    Set-ClipwarpRetentionPolicy -Enabled $true -MaxBytes 8 -ConfigPath $config
    Assert (@(Get-ClipwarpRetentionPreview $out $config).Count -eq 4) 'byte cap retains newest fitting images'
    Set-ClipwarpRetentionPolicy -Enabled $true -MaxAgeDays 3 -ConfigPath $config
    Assert (@(Get-ClipwarpRetentionPreview $out $config -NowUtc ([datetime]::UtcNow.AddSeconds(-5))).Count -eq 3) 'age cap selects expired images'
    Assert (@(Get-ClipwarpRetentionPreview $out $config -ExcludePath $owned[5].Path).Count -eq 3) 'active references are excluded from cleanup'
    $threw=$false;try{Invoke-ClipwarpRetention $out $config -MaximumFiles 2 | Out-Null}catch{$threw=$true}
    Assert ($threw -and @(Get-ClipwarpHistory $out -Limit 100).Count -eq 6) 'scan cap aborts before deletion'
    $o=New-ClipwarpManagedImageFile $out;$owned+=$o
    Remove-ClipwarpOwnedImageFile $o -WhatIf
    Assert (Test-Path $o.Path) 'owned cleanup WhatIf preserves file and stream'
    Remove-ClipwarpOwnedImageFile $o
    Assert (-not(Test-Path $o.Path)) 'aborted owned image is removed'
    $owned[0].Published=$true
    Remove-ClipwarpOwnedImageFile $owned[0]
    Assert (Test-Path $owned[0].Path) 'published operation is never aborted-cleaned'
    Invoke-ClipwarpRetention $out $config -ExcludePath $owned[0].Path | Out-Null
    Assert (Test-Path (Join-Path $out 'clip-user-notes.png')) 'cleanup preserves unrelated prefix files'
    Assert (Test-Path (Join-Path $out 'nested/clip-20260101-000000-000.png')) 'cleanup never recurses'
    # Directory junction fixture (no admin rights required on Windows).
    $junction=Join-Path $temp 'junction'
    New-Item -ItemType Junction -Path $junction -Target $out | Out-Null
    try {$threw=$false;try{Get-ClipwarpHistory $junction | Out-Null}catch{$threw=$true};Assert $threw 'history rejects reparse-point ancestors'} finally {[IO.Directory]::Delete($junction)}
    $metadata=Join-Path $temp 'clipwarp-installed.json'
    [IO.File]::WriteAllText($metadata,'{"version":"test-v2","commit":"abc123","source":"local","clipboard":"do not expose"}')
    $m=Get-ClipwarpInstalledMetadata $temp
    Assert ($m.Version -eq 'test-v2' -and ($m | ConvertTo-Json) -notmatch 'do not expose') 'doctor metadata exposes only origin/version fields'
} finally {
    foreach($o in $owned){$o.Stream.Dispose()}
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'All storage tests passed.'
