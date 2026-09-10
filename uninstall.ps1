<# Removes only owned direct-child files. Windows Clipboard History/cloud copies are not removed. #>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$InstallRoot = (Join-Path $HOME '.claude\scripts'),
    [string[]]$ProfilePaths,
    [string]$ImageDirectory = (Join-Path $HOME '.claude\pasted-images'),
    [string]$SettingsDirectory = (Join-Path $HOME '.claude'),
    [string]$TransportDirectory = ([IO.Path]::GetTempPath()),
    [switch]$PurgeImages,[switch]$PurgeSettings,[switch]$PurgeLogs,[switch]$PurgeTransport,
    [switch]$NoProfiles,[switch]$NoWatcher,
    [int]$MutexTimeoutSeconds = 30
)
$ErrorActionPreference='Stop'
# Installed releases carry this installer as their shared installation-only library.
$library = Join-Path $PSScriptRoot 'install.ps1'
if (-not [IO.File]::Exists($library)) { throw 'Installation library missing; use uninstall.ps1 from a complete release.' }
# Dot-sourcing parameters have local scope: preserve this command's options explicitly.
$options = @{}; foreach ($key in $PSBoundParameters.Keys) { $options[$key]=$PSBoundParameters[$key] }
$rootArg=$InstallRoot; $profilesArg=$ProfilePaths; $noProfilesArg=$NoProfiles; $noWatcherArg=$NoWatcher; $timeoutArg=$MutexTimeoutSeconds
. $library -LibraryOnly -InstallRoot $rootArg -ProfilePaths $profilesArg -NoProfiles:$noProfilesArg -NoWatcher:$noWatcherArg -MutexTimeoutSeconds $timeoutArg
$InstallRoot=Assert-ClipwarpSafePath $rootArg
$defaultRoot=[IO.Path]::GetFullPath((Join-Path $HOME '.claude\scripts'))
if ($InstallRoot -ne $defaultRoot) {
    $NoWatcher=$true
    if (-not $options.ContainsKey('ProfilePaths')) { $NoProfiles=$true }
    foreach ($pair in @(@('PurgeImages','ImageDirectory'),@('PurgeSettings','SettingsDirectory'),@('PurgeTransport','TransportDirectory'))) {
        if ($options[$pair[0]] -and -not $options.ContainsKey($pair[1])) { throw "Custom installations require explicit $($pair[1]) for purge." }
    }
}
if (-not $ProfilePaths) { $ProfilePaths=@(Get-ClipwarpProfilePaths) }
$mutex=Get-ClipwarpInstallMutex $InstallRoot; $locked=$false; $removed=0
function Remove-OwnedDirectFiles([string]$Directory,[string]$Pattern) {
    [void](Assert-ClipwarpSafePath $Directory)
    if (-not [IO.Directory]::Exists($Directory)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Force) {
        if ($file.Name -notmatch $Pattern -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if ($PSCmdlet.ShouldProcess($file.FullName,'Delete owned Clipwarp file')) {
            [void](Assert-ClipwarpSafePath $file.FullName)
            [IO.File]::Delete($file.FullName); $script:removed++
        }
    }
}
try {
    try { $locked=$mutex.WaitOne([TimeSpan]::FromSeconds($MutexTimeoutSeconds)) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another Clipwarp install/uninstall holds the installation mutex.' }
    $active=Get-ClipwarpActiveDirectory $InstallRoot
    if (-not $NoWatcher -and -not $WhatIfPreference) {
        $state=Invoke-ClipwarpWatcher $active 'Status'
        if ($state -notin @(0,1)) { throw 'Unverified watcher; no files removed.' }
        if ($state -eq 0) {
            if (-not $PSCmdlet.ShouldProcess($active,'Stop verified Clipwarp watcher')) { return }
            if ((Invoke-ClipwarpWatcher $active 'Stop') -ne 0 -or (Invoke-ClipwarpWatcher $active 'Status') -ne 1) { throw 'Watcher remains active; no files removed.' }
        }
    }
    # Even -NoWatcher may not delete artifacts referenced by a live/unknown PID.
    $pidFile=Join-Path $InstallRoot 'clipwarp-watch.pid'
    if ([IO.File]::Exists($pidFile) -and -not $WhatIfPreference) {
        [void](Assert-ClipwarpSafePath $pidFile)
        $watchPid=0; $first=[IO.File]::ReadAllLines($pidFile) | Select-Object -First 1
        if (-not [int]::TryParse($first,[ref]$watchPid)) { throw 'Unreadable watcher ownership record; files retained.' }
        if (Get-Process -Id $watchPid -ErrorAction SilentlyContinue) { throw 'PID still alive; artifacts retained (no force kill).' }
    }
    if (-not $NoProfiles) { foreach ($path in $ProfilePaths) { if ([IO.File]::Exists($path) -and $PSCmdlet.ShouldProcess($path,'Remove Clipwarp profile block')) { Set-ClipwarpProfile $path $InstallRoot -Remove } } }
    if ($InstallRoot -eq $defaultRoot) {
        $startup=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'
        if ([IO.File]::Exists($startup) -and $PSCmdlet.ShouldProcess($startup,'Remove Clipwarp autostart shortcut')) { [void](Assert-ClipwarpSafePath $startup); [IO.File]::Delete($startup) }
    }
    if ($PurgeImages) { Remove-OwnedDirectFiles $ImageDirectory '^clip-\d{8}-\d{6}-\d{3}(-[a-f0-9]{32})?\.(png|jpe?g|gif|webp)$' }
    if ($PurgeSettings) { Remove-OwnedDirectFiles $SettingsDirectory '^clipwarp\.json(\.bak|\.last-good|\.corrupt-[0-9a-f]{32})?$' }
    if ($PurgeLogs) { Remove-OwnedDirectFiles $InstallRoot '^clipwarp-watch\.log(\.[0-9]+)?$' }
    # A reviewed command may still use its transport even without an open handle.
    # Retain command transports until shared process-ownership cleanup can prove expiry.
    # Only expired (>24h), exclusively openable calendar title transports are removed.
    if ($PurgeTransport) {
        [void](Assert-ClipwarpSafePath $TransportDirectory)
        if ([IO.Directory]::Exists($TransportDirectory)) {
            foreach ($file in Get-ChildItem -LiteralPath $TransportDirectory -File -Force) {
                if ($file.Name -notmatch '^clipwarp-title-[a-f0-9]{32}\.txt$' -or $file.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-1) -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                if ($PSCmdlet.ShouldProcess($file.FullName,'Delete expired unused Clipwarp transport')) {
                    [void](Assert-ClipwarpSafePath $file.FullName)
                    try { $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { Write-Warning "Transport in use; retained: $($file.Name)"; continue }
                    $stream.Dispose(); [IO.File]::Delete($file.FullName); $removed++
                }
            }
        }
    }
    $versions=Assert-ClipwarpSafePath (Join-Path $InstallRoot 'versions')
    if ([IO.Directory]::Exists($versions)) {
        foreach ($dir in Get-ChildItem -LiteralPath $versions -Directory -Force) {
            if ($dir.Name -notmatch '^v-[a-f0-9]{32}$' -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            # Inventory is fixed, not controlled by installed metadata. Never recurse.
            if ($PSCmdlet.ShouldProcess($dir.FullName,'Remove Clipwarp release inventory (retain unrelated files)')) { Remove-ClipwarpVersionFiles $dir.FullName }
        }
    }
    $names=@(Get-ClipwarpReleaseInventory)+@('active-version.json','installed-manifest.json','release-manifest.json','clipwarp-watch.pid')
    foreach ($name in $names) { $path=Join-Path $InstallRoot $name; if ([IO.File]::Exists($path) -and $PSCmdlet.ShouldProcess($path,'Remove installed Clipwarp file')) { [void](Assert-ClipwarpSafePath $path); [IO.File]::Delete($path); $removed++ } }
    [pscustomobject]@{ RemovedFiles=$removed; WhatIf=[bool]$WhatIfPreference; ImagesRetained=(-not $PurgeImages); SettingsRetained=(-not $PurgeSettings); LogsRetained=(-not $PurgeLogs); TransportRetained=(-not $PurgeTransport); Note='Unrelated files, subdirectories, reparse points, and recent/in-use transports retained. Windows Clipboard History and cloud copies are not removed.' }
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
