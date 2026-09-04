<#
    clipwarp uninstaller. Stops the watcher, removes its login-autostart shortcut,
    strips the profile function from both PowerShell editions, then deletes the
    installed scripts. Reports honestly if any step fails and keeps the scripts in
    place (so you can re-run) when profile cleanup didn't complete.

    Run:  .\uninstall.ps1  [-PurgeImages]
    If you installed with the one-liner, the uninstaller lives in your scripts
    folder:  & "$HOME\.claude\scripts\uninstall.ps1"
#>
[CmdletBinding()]
param([switch]$PurgeImages)

$scriptsDir  = Join-Path $HOME '.claude\scripts'
$watchScript = Join-Path $scriptsDir 'clipwarp-watch.ps1'
$pidFile     = Join-Path $scriptsDir 'clipwarp-watch.pid'
$startupLnk  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'
$problems    = @()

# Detect a text file's encoding from its BOM so we can rewrite it unchanged
# (a UTF-16/BOM profile must not be flattened to UTF-8). Defaults to UTF-8 no BOM.
function Get-FileEncoding([string]$Path) {
    try { $b = [System.IO.File]::ReadAllBytes($Path) } catch { return (New-Object System.Text.UTF8Encoding($false)) }
    if ($b.Length -ge 4 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE -and $b[2] -eq 0x00 -and $b[3] -eq 0x00) { return (New-Object System.Text.UTF32Encoding($false, $true)) }
    if ($b.Length -ge 4 -and $b[0] -eq 0x00 -and $b[1] -eq 0x00 -and $b[2] -eq 0xFE -and $b[3] -eq 0xFF) { return (New-Object System.Text.UTF32Encoding($true, $true)) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return (New-Object System.Text.UTF8Encoding($true)) }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
    try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($b); return (New-Object System.Text.UTF8Encoding($false)) }
    catch {
        # Not valid UTF-8 -> legacy ANSI. GetEncoding(0) is ANSI only on .NET Framework
        # (PS 5.1); on .NET/PS 7 it is UTF-8, so ask for the actual ANSI code page and
        # register the code-pages provider (.NET Core needs it for CP125x).
        $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        try { return [System.Text.Encoding]::GetEncoding($cp) }
        catch {
            try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance); return [System.Text.Encoding]::GetEncoding($cp) }
            catch { throw "cannot load the system ANSI code page ($cp) to preserve this profile's encoding - leaving it unchanged" }
        }
    }
}

$startMark = '# >>> clipwarp (Claude Code image paste helper) >>>'
$endMark   = '# <<< clipwarp <<<'

function Get-WatcherState {
    # Tri-state so a reused/stale PID is never killed and a live-but-unverifiable
    # process is never mistaken for gone:
    #   none    - no pid file / process not alive
    #   watcher - live process whose command line is exactly our daemon (+ -Daemon)
    #   foreign - live process verifiably NOT our daemon
    #   unknown - live powershell/pwsh whose command line couldn't be read (CIM failed)
    if (-not (Test-Path -LiteralPath $pidFile)) { return @{ State = 'none'; Pid = $null } }
    $wp = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$wp)) { return @{ State = 'none'; Pid = $null } }
    $p = Get-Process -Id $wp -ErrorAction SilentlyContinue
    if (-not $p) { return @{ State = 'none'; Pid = $wp } }
    if ($p.ProcessName -notin @('powershell','pwsh')) { return @{ State = 'foreign'; Pid = $wp } }
    $cmd = $null; $cimOk = $true
    try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$wp" -ErrorAction Stop).CommandLine }
    catch { $cimOk = $false }
    if (-not $cimOk -or $null -eq $cmd) { return @{ State = 'unknown'; Pid = $wp } }
    $fileRe = '-File\s+"?' + [regex]::Escape($watchScript) + '"?(\s|$)'
    if (($cmd -match $fileRe) -and ($cmd -match '(^|\s)-Daemon(\s|$)')) { return @{ State = 'watcher'; Pid = $wp } }
    return @{ State = 'foreign'; Pid = $wp }
}

# 1. Stop the watcher and disable autostart (needs the watcher script present).
if (Test-Path -LiteralPath $watchScript) {
    try { & $watchScript -Stop        | Out-Null } catch { $problems += "stop watcher: $($_.Exception.Message)" }
    try { & $watchScript -NoAutostart | Out-Null } catch { $problems += "disable autostart: $($_.Exception.Message)" }
}
# Verify it actually stopped; force-kill only the VERIFIED watcher pid as a fallback.
# On 'unknown' (a live shell we can't verify) refuse and keep everything, so we never
# delete the scripts out from under a clipboard watcher that may still be live.
$state = Get-WatcherState
if ($state.State -eq 'watcher') {
    try { Stop-Process -Id $state.Pid -Force -ErrorAction Stop } catch { $problems += "kill watcher pid $($state.Pid): $($_.Exception.Message)" }
    $state = Get-WatcherState
    if ($state.State -eq 'watcher') { $problems += "watcher is still running (pid file: $pidFile)" }
}
if ($state.State -eq 'unknown') {
    $problems += "could not verify the process at pid $($state.Pid) (pid file: $pidFile) - refusing to touch it; re-run once it can be verified"
}

# 2. Remove the login-autostart shortcut directly (in case the script was gone).
if (Test-Path -LiteralPath $startupLnk) {
    try { Remove-Item -LiteralPath $startupLnk -Force -ErrorAction Stop; Write-Host "removed autostart shortcut -> $startupLnk" -ForegroundColor Green }
    catch { $problems += "remove autostart shortcut: $($_.Exception.Message)" }
}

# 3. Strip the marked block from BOTH editions' all-hosts profiles (install writes to both).
$cur = $PROFILE.CurrentUserAllHosts
$profilePaths = @($cur)
if     ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $profilePaths += ($cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1') }
elseif ($cur -match '\\PowerShell\\profile\.ps1$')        { $profilePaths += ($cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1') }
$profilePaths = $profilePaths | Select-Object -Unique

foreach ($profilePath in $profilePaths) {
    if (-not (Test-Path -LiteralPath $profilePath)) { continue }
    $tmp = "$profilePath.clipwarp.tmp"
    try {
        $enc   = Get-FileEncoding $profilePath
        $lines = @([System.IO.File]::ReadAllLines($profilePath, $enc))
        # Require a COMPLETE, EXACT start/end marker pair before mutating anything -
        # never delete from the start marker to EOF if the closing marker is missing.
        $startIdx = -1; $endIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($startIdx -lt 0 -and $lines[$i].Trim() -eq $startMark) { $startIdx = $i; continue }
            if ($startIdx -ge 0 -and $lines[$i].Trim() -eq $endMark)   { $endIdx = $i; break }
        }
        if ($startIdx -lt 0) { continue }                       # no clipwarp block here
        if ($endIdx -lt 0) {
            $problems += "profile ${profilePath} has an unterminated clipwarp block - left untouched (remove it by hand)"
            continue
        }
        $kept = @()
        if ($startIdx -gt 0)               { $kept += $lines[0..($startIdx - 1)] }
        if ($endIdx -lt ($lines.Count - 1)) { $kept += $lines[($endIdx + 1)..($lines.Count - 1)] }
        # Write a same-directory temp in the ORIGINAL encoding, then atomically replace.
        [System.IO.File]::WriteAllLines($tmp, [string[]]$kept, $enc)
        Move-Item -LiteralPath $tmp -Destination $profilePath -Force -ErrorAction Stop
        Write-Host "removed clipwarp function from $profilePath" -ForegroundColor Green
    }
    catch {
        $problems += "edit profile ${profilePath}: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 4. Optionally purge saved images.
if ($PurgeImages) {
    $imgDir = Join-Path $HOME '.claude\pasted-images'
    if (Test-Path -LiteralPath $imgDir) {
        try { Remove-Item -LiteralPath $imgDir -Recurse -Force -ErrorAction Stop; Write-Host "purged $imgDir" -ForegroundColor Green }
        catch { $problems += "purge images: $($_.Exception.Message)" }
    }
}

# 5. Delete the installed scripts LAST — and only if EVERY prior step was clean, so
#    any earlier failure leaves a working `clipwarp` + the uninstaller to retry.
if ($problems.Count -eq 0) {
    $removeOk = $true
    foreach ($name in @('clipwarp.ps1', 'clipwarp-watch.ps1', 'clipwarp-calendar.psm1', 'clipwarp-calendar-popup.ps1', 'clipwarp-support.psm1', 'clipwarp-watch.pid', 'clipwarp-watch.log')) {
        $t = Join-Path $scriptsDir $name
        if (Test-Path -LiteralPath $t) {
            try { Remove-Item -LiteralPath $t -Force -ErrorAction Stop; Write-Host "removed $t" -ForegroundColor Green }
            catch { $problems += "remove ${t}: $($_.Exception.Message)"; $removeOk = $false }
        }
    }
    # Delete this uninstaller itself, absolutely last, only if the rest succeeded.
    if ($removeOk) {
        $self = Join-Path $scriptsDir 'uninstall.ps1'
        if (Test-Path -LiteralPath $self) {
            try { Remove-Item -LiteralPath $self -Force -ErrorAction Stop }
            catch { $problems += "remove uninstaller ${self}: $($_.Exception.Message)" }
        }
    }
    else {
        $problems += "some scripts could not be removed - kept the uninstaller so you can re-run it"
    }
}
else {
    $problems += "earlier steps did not complete cleanly - kept the installed scripts so you can re-run the uninstaller"
}

# 6. Honest final report.
if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "clipwarp uninstall finished with problems:" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    exit 1
}
Write-Host "clipwarp uninstalled cleanly. Open a new terminal to drop the function from your session." -ForegroundColor Cyan
