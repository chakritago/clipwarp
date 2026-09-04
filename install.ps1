<#
    clipwarp installer.

    Works two ways:
      * One-command (remote):  irm https://raw.githubusercontent.com/chakritago/clipwarp/main/install.ps1 | iex
      * From a clone:          git clone https://github.com/chakritago/clipwarp; .\clipwarp\install.ps1

    Installs the clipwarp scripts and calendar popup helper to
    %USERPROFILE%\.claude\scripts and registers a `clipwarp` function (+ `cw`
    alias) in the all-hosts profile of BOTH PowerShell editions. Idempotent, and
    failure-atomic: a mid-way failure rolls back so you never get a half-updated
    (mixed-version) install.
#>

# GitHub's raw host requires TLS 1.2 on Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$RawBaseUrl = if ($env:CLIPWARP_RAW_BASE) { $env:CLIPWARP_RAW_BASE } else { 'https://raw.githubusercontent.com/chakritago/clipwarp/main' }
$scriptsDir = Join-Path $HOME '.claude\scripts'

# Detect a text file's encoding so an existing profile is rewritten unchanged:
# UTF-32/UTF-16/UTF-8 by BOM, then strict-UTF-8 for a no-BOM file, else the system
# ANSI code page (common for legacy Windows PowerShell profiles). Never decode ANSI
# bytes as UTF-8 (that would replace them with U+FFFD).
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

# --- 1. Install the scripts: stage all to temp, then swap in with backup/rollback. ---
$files    = @('clipwarp.ps1', 'clipwarp-watch.ps1', 'clipwarp-calendar.psm1', 'clipwarp-calendar-popup.ps1', 'clipwarp-support.psm1', 'uninstall.ps1')
$staged   = @{}
$backups  = @{}   # name -> backup path (targets that existed before)
$created  = @()   # target paths that did NOT exist before (delete these on rollback)
try {
    New-Item -ItemType Directory -Force -Path $scriptsDir -ErrorAction Stop | Out-Null
    foreach ($name in $files) {
        $tmp = Join-Path $scriptsDir ".$name.download"
        $localSrc = if ($PSScriptRoot) { Join-Path $PSScriptRoot $name } else { $null }
        if ($localSrc -and (Test-Path -LiteralPath $localSrc)) {
            Copy-Item -LiteralPath $localSrc -Destination $tmp -Force -ErrorAction Stop
        }
        else {
            Invoke-WebRequest -Uri "$RawBaseUrl/$name" -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        }
        $staged[$name] = $tmp
    }
    foreach ($name in $files) {
        $target = Join-Path $scriptsDir $name
        if (Test-Path -LiteralPath $target) {
            Copy-Item -LiteralPath $target -Destination "$target.bak" -Force -ErrorAction Stop
            $backups[$name] = "$target.bak"
        }
        else { $created += $target }
        Move-Item -LiteralPath $staged[$name] -Destination $target -Force -ErrorAction Stop
        Write-Host "installed $name" -ForegroundColor Green
    }
    foreach ($b in $backups.Values) { Remove-Item -LiteralPath $b -Force -ErrorAction SilentlyContinue }
}
catch {
    $err = $_.Exception.Message
    $rollbackOk = $true
    foreach ($t in $created) {
        try { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction Stop } }
        catch { $rollbackOk = $false }
    }
    foreach ($name in $backups.Keys) {
        try { Move-Item -LiteralPath $backups[$name] -Destination (Join-Path $scriptsDir $name) -Force -ErrorAction Stop }
        catch { $rollbackOk = $false; Write-Host "  kept backup: $($backups[$name])" -ForegroundColor Yellow }
    }
    foreach ($t in $staged.Values) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    if ($rollbackOk) { Write-Host "clipwarp: install failed - $err. Rolled back; no files were changed." -ForegroundColor Red }
    else { Write-Host "clipwarp: install failed - $err. Rollback INCOMPLETE - the install may be inconsistent; *.bak backups were kept." -ForegroundColor Red }
    exit 1
}

# --- 2. Register the `clipwarp` function in BOTH editions' all-hosts profiles. ---
$startMark = '# >>> clipwarp (Claude Code image paste helper) >>>'
$block = @"

$startMark
function clipwarp { & "`$HOME\.claude\scripts\clipwarp.ps1" @args }
Set-Alias cw clipwarp
# <<< clipwarp <<<
"@

$cur = $PROFILE.CurrentUserAllHosts
$profilePaths = @($cur)
if     ($cur -match '\\WindowsPowerShell\\profile\.ps1$') { $profilePaths += ($cur -replace '\\WindowsPowerShell\\profile\.ps1$', '\PowerShell\profile.ps1') }
elseif ($cur -match '\\PowerShell\\profile\.ps1$')        { $profilePaths += ($cur -replace '\\PowerShell\\profile\.ps1$', '\WindowsPowerShell\profile.ps1') }
$profilePaths = $profilePaths | Select-Object -Unique

$problems = @()
foreach ($profilePath in $profilePaths) {
    try {
        $profileDir = Split-Path $profilePath
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir -ErrorAction Stop | Out-Null }
        $existed = Test-Path -LiteralPath $profilePath
        if ($existed) { $enc = Get-FileEncoding $profilePath; $content = [System.IO.File]::ReadAllText($profilePath, $enc) }
        else          { $enc = New-Object System.Text.UTF8Encoding($false); $content = '' }
        if ($content.Contains($startMark)) {
            Write-Host "profile already registers clipwarp -> $profilePath" -ForegroundColor DarkGray
            continue
        }
        [System.IO.File]::WriteAllText($profilePath, ($content + $block), $enc)
        Write-Host "registered clipwarp function -> $profilePath" -ForegroundColor Green
    }
    catch {
        $msg = "profile ${profilePath}: $($_.Exception.Message)"
        $problems += $msg
        if ($profilePath -eq $cur) { $problems += "current-edition-profile-failed" }
    }
}

# --- 3. Load into the current session so it works immediately. ---
try { . $cur } catch {}

# --- 4. Start the watcher after a fully successful install. Updates restart an
# existing watcher so it runs the newly installed script. This does not create a
# login shortcut; `clipwarp autostart` remains the only opt-in for that behavior.
$installedWatch = Join-Path $scriptsDir 'clipwarp-watch.ps1'
if ($problems.Count -eq 0) {
    & $installedWatch -Status *> $null
    $watchState = $LASTEXITCODE
    if ($watchState -eq 2) {
        $problems += "a running watcher could not be verified - it was NOT restarted, so it may still run the old version. Stop it manually and run 'clipwarp watch'."
    }
    else {
        if ($watchState -eq 0) {
            & $installedWatch -Stop *> $null
            if ($LASTEXITCODE -ne 0) {
                $problems += "could not stop the running watcher to update it - it may still run the old version."
            }
        }
    }
    if ($problems.Count -eq 0) {
        & $installedWatch *> $null
        $startCode = $LASTEXITCODE
        & $installedWatch -Status *> $null
        if ($startCode -eq 0 -and $LASTEXITCODE -eq 0) {
            $verb = if ($watchState -eq 0) { 'restarted' } else { 'started' }
            Write-Host "$verb the clipboard watcher" -ForegroundColor Green
        }
        else { $problems += "the watcher did not start - run 'clipwarp watch' to start it manually." }

        # Enable autostart on Windows logon
        & $installedWatch -Autostart *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "enabled autostart on Windows logon" -ForegroundColor Green
        }
        else {
            $problems += "could not enable login autostart - run 'clipwarp autostart' manually."
        }
    }
}

# --- 5. Honest summary. ---
Write-Host ""
$currentEditionBroke = $problems -contains 'current-edition-profile-failed'
$problems = $problems | Where-Object { $_ -ne 'current-edition-profile-failed' }
if ($problems.Count -gt 0) {
    Write-Host "clipwarp installed, but with problems:" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    if ($currentEditionBroke) {
        Write-Host "The 'clipwarp' command may be unavailable in this edition until that profile is fixed." -ForegroundColor Yellow
        exit 1
    }
    exit 1
}

Write-Host "clipwarp installed and the clipboard watcher is running." -ForegroundColor Cyan
Write-Host "  1) snip or Ctrl+C an image anywhere (Win+Shift+S, Lightshot, browser...)"
Write-Host "  2) in Claude Code, press Ctrl+V"
Write-Host ""
Write-Host "Login autostart is enabled (starts on Windows logon). Run 'clipwarp unautostart' if you want to turn it off." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Open a NEW terminal (or run '. `$PROFILE') if 'clipwarp' isn't found yet." -ForegroundColor DarkGray
