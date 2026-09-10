<# Transactional per-user installation. Checksums detect corruption, not publisher authenticity. #>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$InstallRoot = (Join-Path $HOME '.claude\scripts'),
    [string]$SourceRoot = $PSScriptRoot,
    [string]$Commit,
    [string[]]$ProfilePaths,
    [switch]$NoProfiles,
    [switch]$NoWatcher,
    [switch]$LibraryOnly,
    [int]$MutexTimeoutSeconds = 30
)

function Get-ClipwarpReleaseInventory {
    @('clipwarp.ps1','clipwarp-watch.ps1','clipwarp-calendar.psm1','clipwarp-calendar-popup.ps1','clipwarp-support.psm1','clipwarp-clipboard.cs','clipwarp-policy.cs','clipwarp-image.cs','install.ps1','uninstall.ps1')
}
function Assert-ClipwarpSafePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $part = $full
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse path: $part" }
        }
        $parent = [IO.Path]::GetDirectoryName($part)
        if ($parent -eq $part) { break }; $part = $parent
    }
    return $full
}
function Get-ClipwarpInstallMutex([string]$Root) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).TrimEnd('\','/').ToLowerInvariant()))).Replace('-','') }
    finally { $sha.Dispose() }
    New-Object Threading.Mutex($false, ('Local\Clipwarp.Install.' + $key))
}
function Write-ClipwarpAtomicBytes([string]$Path,[byte[]]$Bytes) {
    [void](Assert-ClipwarpSafePath $Path)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($tmp,$Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp,$Path,[NullString]::Value) }
        else { [IO.File]::Move($tmp,$Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Write-ClipwarpAtomicText([string]$Path,[string]$Text) { Write-ClipwarpAtomicBytes $Path ([Text.Encoding]::UTF8.GetBytes($Text)) }
function Get-FileEncoding([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 4 -and $b[0] -eq 255 -and $b[1] -eq 254 -and $b[2] -eq 0 -and $b[3] -eq 0) { return [Text.Encoding]::UTF32 }
    if ($b.Length -ge 4 -and $b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 254 -and $b[3] -eq 255) { return (New-Object Text.UTF32Encoding($true,$true)) }
    if ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) { return (New-Object Text.UTF8Encoding($true)) }
    if ($b.Length -ge 2 -and $b[0] -eq 255 -and $b[1] -eq 254) { return [Text.Encoding]::Unicode }
    if ($b.Length -ge 2 -and $b[0] -eq 254 -and $b[1] -eq 255) { return [Text.Encoding]::BigEndianUnicode }
    try { [void](New-Object Text.UTF8Encoding($false,$true)).GetString($b); return (New-Object Text.UTF8Encoding($false)) }
    catch { $cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage; try { return [Text.Encoding]::GetEncoding($cp) } catch { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance); return [Text.Encoding]::GetEncoding($cp) } }
}
function Get-ClipwarpProfilePaths {
    $cur = $PROFILE.CurrentUserAllHosts
    @($cur; if ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1' } elseif ($cur -match '\\PowerShell\\profile\.ps1$') { $cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1' }) | Select-Object -Unique
}
function Set-ClipwarpProfile([string]$Path,[string]$Root,[switch]$Remove) {
    [void](Assert-ClipwarpSafePath $Path)
    $enc = New-Object Text.UTF8Encoding($false); $text = ''
    if ([IO.File]::Exists($Path)) { $enc = Get-FileEncoding $Path; $text = [IO.File]::ReadAllText($Path,$enc) }
    $start = '# >>> clipwarp (Claude Code image paste helper) >>>'; $end = '# <<< clipwarp <<<'
    $pattern = '(?ms)^' + [regex]::Escape($start) + '\r?\n.*?^' + [regex]::Escape($end) + '[ \t]*(?:\r?\n|$)'
    if ($text.Contains($start) -and -not [regex]::IsMatch($text,$pattern)) { throw "Unterminated profile block: $Path" }
    $text = [regex]::Replace($text,$pattern,'')
    if (-not $Remove) { $escaped = (Join-Path $Root 'clipwarp.ps1').Replace("'","''"); $text += "`r`n$start`r`nfunction clipwarp { & '$escaped' @args }`r`nSet-Alias cw clipwarp`r`n$end`r`n" }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    Write-ClipwarpAtomicBytes $Path ([byte[]]($enc.GetPreamble() + $enc.GetBytes($text)))
}
function New-ClipwarpReleaseManifest([string]$Root,[string]$SourceCommit) {
    $files = @(foreach ($name in Get-ClipwarpReleaseInventory) {
        $path = Assert-ClipwarpSafePath (Join-Path $Root $name)
        if (-not [IO.File]::Exists($path)) { throw "Missing release file: $name" }
        [ordered]@{ name=$name; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    [pscustomobject][ordered]@{ schemaVersion=1; commit=$SourceCommit; files=$files }
}
function Test-ClipwarpReleaseManifest($Manifest,[string]$Root) {
    $inventory = @(Get-ClipwarpReleaseInventory)
    if ($Manifest.schemaVersion -ne 1 -or @($Manifest.files).Count -ne $inventory.Count) { throw 'Invalid release manifest schema/inventory.' }
    $seen = @{}
    foreach ($entry in $Manifest.files) {
        if ($entry.name -cnotin $inventory -or $seen.ContainsKey($entry.name) -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid release manifest entry.' }
        $seen[$entry.name] = $true
        $path = Assert-ClipwarpSafePath (Join-Path $Root $entry.name)
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry.sha256) { throw "SHA-256 mismatch: $($entry.name)" }
    }
}
function Get-ClipwarpActiveDirectory([string]$Root) {
    $pointer = Join-Path $Root 'active-version.json'
    if (-not [IO.File]::Exists($pointer)) { return $Root }
    [void](Assert-ClipwarpSafePath $pointer)
    $active = [IO.File]::ReadAllText($pointer) | ConvertFrom-Json
    if ($active.version -notmatch '^v-[a-f0-9]{32}$') { throw 'Invalid active version pointer.' }
    $dir = Assert-ClipwarpSafePath (Join-Path (Join-Path $Root 'versions') $active.version)
    if (-not [IO.File]::Exists((Join-Path $dir 'installed-manifest.json'))) { throw 'Active version is incomplete.' }
    $dir
}
function Invoke-ClipwarpWatcher([string]$Directory,[string]$Action) {
    $script = Join-Path $Directory 'clipwarp-watch.ps1'
    if (-not [IO.File]::Exists($script)) { if ($Action -eq 'Status') { return 1 }; throw 'Watcher script is missing.' }
    $engine = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script)
    if ($Action) { $arguments += ('-' + $Action) }
    & $engine @arguments | Out-Host
    return $LASTEXITCODE
}
function Remove-ClipwarpVersionFiles([string]$Directory) {
    [void](Assert-ClipwarpSafePath $Directory)
    foreach ($name in @((Get-ClipwarpReleaseInventory)) + @('release-manifest.json','installed-manifest.json')) {
        $path = Assert-ClipwarpSafePath (Join-Path $Directory $name)
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    if ([IO.Directory]::Exists($Directory) -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -eq 0) { [IO.Directory]::Delete($Directory) }
}
if ($LibraryOnly) { return }
$ErrorActionPreference = 'Stop'
$InstallRoot = Assert-ClipwarpSafePath $InstallRoot
if (-not $PSCmdlet.ShouldProcess($InstallRoot,'Verify and activate Clipwarp release; update selected profiles and restart an existing watcher')) { return }
# Custom roots never operate on the real user's profiles or watcher implicitly.
$defaultRoot = [IO.Path]::GetFullPath((Join-Path $HOME '.claude\scripts'))
if ($InstallRoot -ne $defaultRoot) { $NoWatcher = $true; if (-not $PSBoundParameters.ContainsKey('ProfilePaths')) { $NoProfiles = $true } }
if (-not $ProfilePaths) { $ProfilePaths = @(Get-ClipwarpProfilePaths) }
$mutex = Get-ClipwarpInstallMutex $InstallRoot; $locked = $false; $stage = $null; $activated = $false; $stopped = $false; $saved = @{}; $oldDir = $InstallRoot
try {
    try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds($MutexTimeoutSeconds)) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another Clipwarp install/uninstall holds the installation mutex.' }
    [void][IO.Directory]::CreateDirectory($InstallRoot)
    $oldDir = Get-ClipwarpActiveDirectory $InstallRoot
    $versions = Assert-ClipwarpSafePath (Join-Path $InstallRoot 'versions'); [void][IO.Directory]::CreateDirectory($versions)
    $version = 'v-' + [guid]::NewGuid().ToString('N'); $stage = Join-Path $versions $version; [void][IO.Directory]::CreateDirectory($stage)
    if ($SourceRoot) {
        $SourceRoot = Assert-ClipwarpSafePath $SourceRoot
        if (-not $Commit) { try { $Commit = (& git -C $SourceRoot rev-parse HEAD 2>$null | Select-Object -First 1) } catch {} }
        $manifestPath = Join-Path $SourceRoot 'release-manifest.json'
        $manifest = if ([IO.File]::Exists($manifestPath)) { [IO.File]::ReadAllText((Assert-ClipwarpSafePath $manifestPath)) | ConvertFrom-Json } else { New-ClipwarpReleaseManifest $SourceRoot $Commit }
        foreach ($name in Get-ClipwarpReleaseInventory) { Copy-Item -LiteralPath (Assert-ClipwarpSafePath (Join-Path $SourceRoot $name)) -Destination (Join-Path $stage $name) }
        $origin = [ordered]@{ kind='local'; source=$SourceRoot; commit=$Commit; integrity='local inventory SHA-256; not a signature' }
    } else {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        if (-not $Commit) { $Commit = (Invoke-RestMethod -Uri 'https://api.github.com/repos/chakritago/clipwarp/commits/main' -Headers @{ 'User-Agent'='Clipwarp-Installer' }).sha }
        if ($Commit -notmatch '^[a-fA-F0-9]{40}$') { throw 'Remote installation requires a full 40-character commit SHA.' }
        $base = "https://raw.githubusercontent.com/chakritago/clipwarp/$Commit"
        $manifest = Invoke-RestMethod -Uri "$base/release-manifest.json"
        foreach ($name in Get-ClipwarpReleaseInventory) { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile (Join-Path $stage $name) }
        $origin = [ordered]@{ kind='github'; source=$base; commit=$Commit; integrity='pinned HTTPS + SHA-256; not a signature' }
    }
    Test-ClipwarpReleaseManifest $manifest $stage
    # Parse every staged PowerShell entry point before any activation.
    foreach ($name in (Get-ClipwarpReleaseInventory | Where-Object { $_ -match '\.ps(m)?1$' })) {
        $tokens=$null; $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $stage $name),[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Staged script does not parse: $name" }
    }
    Write-ClipwarpAtomicText (Join-Path $stage 'release-manifest.json') ($manifest | ConvertTo-Json -Depth 8)
    $metadata = [ordered]@{ schemaVersion=1; version=$version; installedAtUtc=[DateTime]::UtcNow.ToString('o'); origin=$origin; files=$manifest.files; profiles=@(if (-not $NoProfiles) { $ProfilePaths }); previousVersion=if ($oldDir -ne $InstallRoot) { Split-Path $oldDir -Leaf } else { $null } }
    Write-ClipwarpAtomicText (Join-Path $stage 'installed-manifest.json') ($metadata | ConvertTo-Json -Depth 8)
    $targets = @('clipwarp.ps1','clipwarp-watch.ps1','uninstall.ps1','active-version.json','installed-manifest.json') | ForEach-Object { Join-Path $InstallRoot $_ }
    if (-not $NoProfiles) { $targets += $ProfilePaths }
    foreach ($path in $targets) { [void](Assert-ClipwarpSafePath $path); $saved[$path] = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllBytes($path) } else { $null } }
    $ownershipPath = Join-Path $InstallRoot 'clipwarp-watch.pid'
    if ($NoWatcher -and [IO.File]::Exists($ownershipPath)) {
        [void](Assert-ClipwarpSafePath $ownershipPath)
        $ownedPid = 0
        if (-not [int]::TryParse(([IO.File]::ReadAllLines($ownershipPath) | Select-Object -First 1),[ref]$ownedPid) -or (Get-Process -Id $ownedPid -ErrorAction SilentlyContinue)) { throw 'Watcher ownership record is live or unreadable; activation cancelled.' }
    }
    if (-not $NoWatcher) {
        $state = Invoke-ClipwarpWatcher $oldDir 'Status'
        if ($state -notin @(0,1)) { throw 'Running watcher cannot be verified; activation cancelled.' }
        if ($state -eq 0) { if ((Invoke-ClipwarpWatcher $oldDir 'Stop') -ne 0 -or (Invoke-ClipwarpWatcher $oldDir 'Status') -ne 1) { throw 'Watcher did not stop; activation cancelled.' }; $stopped=$true }
    }
    $activated = $true
    # First install/flat migration must have a durable complete target BEFORE
    # any stable entry point replaces a flat script. A process interruption
    # then leaves either the old flat script or a working stable launcher.
    if (-not [IO.File]::Exists((Join-Path $InstallRoot 'active-version.json'))) {
        Write-ClipwarpAtomicText (Join-Path $InstallRoot 'active-version.json') (@{ schemaVersion=1; version=$version } | ConvertTo-Json)
    }
    foreach ($name in @('clipwarp.ps1','clipwarp-watch.ps1','uninstall.ps1')) {
        $launcher = @'
# Clipwarp stable launcher; active-version.json is the single activation pointer.
$root = $PSScriptRoot
$p = Get-Content -LiteralPath (Join-Path $root 'active-version.json') -Raw -ErrorAction Stop | ConvertFrom-Json
if ($p.version -notmatch '^v-[a-f0-9]{32}$') { throw 'Invalid Clipwarp active version.' }
$dir = Join-Path (Join-Path $root 'versions') $p.version
$check = $dir
while ($check) {
    if ((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing redirected Clipwarp version.' }
    $check = [IO.Path]::GetDirectoryName($check)
}
if (-not (Test-Path -LiteralPath (Join-Path $dir 'installed-manifest.json') -PathType Leaf)) { throw 'Incomplete Clipwarp release.' }
& (Join-Path $dir '__ENTRY__') @args
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
'@
        if ($name -eq 'uninstall.ps1') { $launcher = $launcher.Replace("& (Join-Path `$dir '__ENTRY__') @args", "& (Join-Path `$dir '__ENTRY__') -InstallRoot `$root @args") }
        Write-ClipwarpAtomicText (Join-Path $InstallRoot $name) ($launcher.Replace('__ENTRY__',$name))
    }
    if (-not $NoProfiles) { foreach ($path in $ProfilePaths) { Set-ClipwarpProfile $path $InstallRoot } }
    Write-ClipwarpAtomicText (Join-Path $InstallRoot 'installed-manifest.json') ($metadata | ConvertTo-Json -Depth 8)
    Write-ClipwarpAtomicText (Join-Path $InstallRoot 'active-version.json') (@{ schemaVersion=1; version=$version } | ConvertTo-Json)
    # Startup check invokes a non-mutating command, never starts a watcher on first install.
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot 'clipwarp.ps1') help *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Activated launcher startup check failed.' }
    if ($stopped -and ((Invoke-ClipwarpWatcher $stage '') -ne 0 -or (Invoke-ClipwarpWatcher $stage 'Status') -ne 0)) { throw 'Updated watcher startup check failed.' }
    Write-Host "Clipwarp activated: $version ($($origin.kind), commit $Commit). Existing versions retained for rollback. Autostart unchanged."
} catch {
    $failure = $_
    if ($activated) {
        if ($stopped) { try { if ((Invoke-ClipwarpWatcher $stage 'Status') -eq 0) { if ((Invoke-ClipwarpWatcher $stage 'Stop') -ne 0) { throw 'Cannot stop failed new watcher.' } } } catch { throw "Installation failed and new watcher could not stop; files retained: $stage. $failure" } }
        foreach ($path in $saved.Keys) { if ($null -eq $saved[$path]) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } else { Write-ClipwarpAtomicBytes $path $saved[$path] } }
    }
    if ($stopped) { try { [void](Invoke-ClipwarpWatcher $oldDir '') } catch { Write-Warning 'Old watcher restart failed; restart it manually.' } }
    if ($stage) { Remove-ClipwarpVersionFiles $stage }
    throw $failure
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
