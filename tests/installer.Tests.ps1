$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$engine=(Get-Process -Id $PID).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-install-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$script:count=0
function Assert($condition,[string]$message) { if (-not $condition) { throw "FAIL: $message" }; $script:count++; Write-Host "PASS: $message" }
function Run([string]$Script,[string[]]$Arguments,[switch]$Fail) {
    # Windows PowerShell turns native stderr into NativeCommandError records;
    # expected child failures must be judged by exit status, not parent EAP.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $engine -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments *> (Join-Path $temp 'output.txt')
    } finally { $ErrorActionPreference = $previousPreference }
    if ($Fail) { Assert ($LASTEXITCODE -ne 0) 'command rejected unsafe/invalid request' }
    elseif ($LASTEXITCODE -ne 0) { throw [IO.File]::ReadAllText((Join-Path $temp 'output.txt')) }
}
try {
    $source=Join-Path $temp 'source'; $root=Join-Path $temp 'installed'; [void][IO.Directory]::CreateDirectory($source)
    . (Join-Path $repo 'install.ps1') -LibraryOnly
    foreach ($name in Get-ClipwarpReleaseInventory) {
        if ($name -in @('install.ps1','uninstall.ps1')) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $source $name) }
        elseif ($name -match '\.cs$') { [IO.File]::WriteAllText((Join-Path $source $name),'// isolated fixture, not production helper') }
        else { [IO.File]::WriteAllText((Join-Path $source $name),'# isolated fixture') }
    }
    $profile=Join-Path $temp 'profiles\profile.ps1'; [void][IO.Directory]::CreateDirectory((Split-Path $profile -Parent)); [IO.File]::WriteAllText($profile,"# personal profile`r`n",[Text.Encoding]::Unicode)
    Run (Join-Path $repo 'new-release-manifest.ps1') @('-SourceRoot',$source,'-Commit',('a'*40))
    $manifest=[IO.File]::ReadAllText((Join-Path $source 'release-manifest.json')) | ConvertFrom-Json
    Assert ($manifest.files.Count -eq 10 -and 'clipwarp-policy.cs' -in $manifest.files.name -and 'clipwarp-image.cs' -in $manifest.files.name) 'fixed inventory includes both shared helpers'
    Run (Join-Path $repo 'install.ps1') @('-SourceRoot',$source,'-InstallRoot',$root,'-ProfilePaths',$profile,'-WhatIf')
    Assert (-not [IO.Directory]::Exists($root)) 'install WhatIf creates no directory'
    Run (Join-Path $repo 'install.ps1') @('-SourceRoot',$source,'-InstallRoot',$root,'-ProfilePaths',$profile,'-NoWatcher')
    $active=[IO.File]::ReadAllText((Join-Path $root 'active-version.json'))
    $meta=[IO.File]::ReadAllText((Join-Path $root 'installed-manifest.json')) | ConvertFrom-Json
    Assert ($meta.origin.kind -eq 'local' -and $meta.files.Count -eq 10) 'installed metadata records origin and inventory'
    Assert ([IO.File]::ReadAllText($profile).Contains('function clipwarp')) 'isolated profile registered'
    $bytes=[IO.File]::ReadAllBytes($profile); Assert ($bytes[0] -eq 255 -and $bytes[1] -eq 254) 'profile UTF-16 BOM preserved'
    Run (Join-Path $root 'clipwarp.ps1') @('help')
    Assert ($true) 'stable launcher resolves complete active version'
    [IO.File]::AppendAllText((Join-Path $source 'clipwarp-image.cs'),'changed')
    Run (Join-Path $repo 'install.ps1') @('-SourceRoot',$source,'-InstallRoot',$root) -Fail
    Assert ([IO.File]::ReadAllText((Join-Path $root 'active-version.json')) -eq $active) 'hash mismatch preserves active pointer'
    Run (Join-Path $repo 'new-release-manifest.ps1') @('-SourceRoot',$source)
    [IO.File]::WriteAllText((Join-Path $source 'clipwarp.ps1'),'exit 23')
    Run (Join-Path $repo 'new-release-manifest.ps1') @('-SourceRoot',$source)
    $beforeProfile=[Convert]::ToBase64String([IO.File]::ReadAllBytes($profile))
    Run (Join-Path $repo 'install.ps1') @('-SourceRoot',$source,'-InstallRoot',$root,'-ProfilePaths',$profile) -Fail
    Assert ([IO.File]::ReadAllText((Join-Path $root 'active-version.json')) -eq $active) 'failed startup rolls active pointer back'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($profile)) -eq $beforeProfile) 'failed startup restores exact profile bytes'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory).Count -eq 1) 'failed stages removed without touching old release'
    [IO.File]::WriteAllText((Join-Path $source 'clipwarp.ps1'),'# healthy fixture')
    Run (Join-Path $repo 'new-release-manifest.ps1') @('-SourceRoot',$source)
    Run (Join-Path $repo 'install.ps1') @('-SourceRoot',$source,'-InstallRoot',$root)
    Assert ([IO.File]::ReadAllText((Join-Path $root 'active-version.json')) -ne $active) 'upgrade activates unique version'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory).Count -eq 2) 'previous complete version retained'
    $mutex=Get-ClipwarpInstallMutex $root; [void]$mutex.WaitOne()
    try { Run (Join-Path $repo 'install.ps1') @('-SourceRoot',$source,'-InstallRoot',$root,'-MutexTimeoutSeconds','0') -Fail } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    $images=Join-Path $temp 'images'; [void][IO.Directory]::CreateDirectory((Join-Path $images 'nested'))
    foreach ($name in @('clip-20260101-120000-000.png','personal.png','nested\clip-keep.png')) { [IO.File]::WriteAllText((Join-Path $images $name),'keep or purge') }
    [IO.File]::WriteAllText((Join-Path $root 'personal.txt'),'unrelated')
    $oldVersion=Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory | Select-Object -First 1
    [IO.File]::WriteAllText((Join-Path $oldVersion.FullName 'personal.txt'),'unrelated')
    $before=@(Get-ChildItem -LiteralPath $temp -Recurse -File | Where-Object Name -ne 'output.txt' | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
    Run (Join-Path $repo 'uninstall.ps1') @('-InstallRoot',$root,'-ProfilePaths',$profile,'-PurgeImages','-ImageDirectory',$images,'-WhatIf')
    $after=@(Get-ChildItem -LiteralPath $temp -Recurse -File | Where-Object Name -ne 'output.txt' | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
    Assert ($before -eq $after) 'uninstall WhatIf preserves every file and byte'
    [IO.File]::WriteAllText((Join-Path $root 'clipwarp-watch.pid'),[string]$PID)
    Run (Join-Path $repo 'uninstall.ps1') @('-InstallRoot',$root) -Fail
    Assert ([IO.File]::Exists((Join-Path $root 'active-version.json'))) 'live PID prevents deletion even in custom root'
    [IO.File]::Delete((Join-Path $root 'clipwarp-watch.pid'))
    Run (Join-Path $repo 'uninstall.ps1') @('-InstallRoot',$root,'-ProfilePaths',$profile,'-PurgeImages','-ImageDirectory',$images)
    Assert (-not [IO.File]::Exists((Join-Path $images 'clip-20260101-120000-000.png'))) 'managed direct-child image purged'
    Assert ([IO.File]::Exists((Join-Path $images 'personal.png')) -and [IO.File]::Exists((Join-Path $images 'nested\clip-keep.png'))) 'unrelated and nested images preserved'
    Assert ([IO.File]::Exists((Join-Path $root 'personal.txt')) -and [IO.File]::Exists((Join-Path $oldVersion.FullName 'personal.txt'))) 'unrelated installed-root and version files preserved'
    Assert (-not [IO.File]::ReadAllText($profile).Contains('function clipwarp')) 'only isolated marked profile block removed'
    Assert ([IO.File]::ReadAllText($profile).Contains('# personal profile')) 'personal profile content retained'
    Write-Host "Installer tests: $script:count assertions passed ($($PSVersionTable.PSVersion))."
} finally {
    # All artifacts here belong exclusively to this test; never follows a reparse fixture.
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
