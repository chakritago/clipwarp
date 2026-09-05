<#
.SYNOPSIS
    clipwarp - Turn a clipboard image into a file path that Claude Code can attach.

.DESCRIPTION
    Claude Code on native Windows cannot read a raw bitmap pasted from the
    clipboard (Snipping Tool / Win+Shift+S / browser "copy image"). It CAN read
    an image file path pasted as text. This script bridges the two:

      1. Reads whatever image is on the clipboard, whatever format the source
         app used:
           - an image FILE copied in Explorer            (CF_HDROP)
           - a PNG stream ("PNG" / "image/png")          (Lightshot, Chrome, Firefox, Discord, ...)
           - a standard bitmap                           (CF_BITMAP / CF_DIB - Snipping Tool)
           - an alpha bitmap                             (CF_DIBV5 / Format17)
           - HTML with an embedded data: URI or file:/// (browser fallback)
           - plain text that is already an image path
      2. Saves it as a PNG under the output folder (unless it is already a file).
      3. Puts that file path on the clipboard as TEXT.

    Then, back in Claude Code, Ctrl+V pastes the path and Claude auto-attaches
    the image. Windows Terminal pastes text fine, so nothing is intercepted.

.PARAMETER Command
    convert (default) - do one clipboard conversion now.
    watch | stop | status - control the background watcher (clipwarp-watch.ps1)
    that converts automatically on every copy, so plain Ctrl+C -> Ctrl+V works.
    A successful install starts the watcher once; autostart remains explicit.
    calendar enable|disable|status - configure Calendar prompts independently.
    calendar image-details enable|full-path|disable|status - image path privacy.
    calendar duration <minutes>|status - timed-event default (1-1440 minutes).
    calendar export -Title <text> [-Details <text>] [-Path <file>] [-TimeZone <id>] - local ICS.
    history | recopy | clean - inspect, explicitly recopy, or prune saved images.
    doctor - run read-only installation and environment diagnostics.

.PARAMETER OutDir
    Folder for saved PNGs. Default: %USERPROFILE%\.claude\pasted-images

.PARAMETER Quiet
    Suppress the human-readable status lines (still prints the path).

.PARAMETER KeepImage
    Write the path as text AND keep the original image on the clipboard
    (dual format): Claude Code pastes the path, image editors still paste the
    image. Used by the watcher; harmless to use manually.

.PARAMETER Limit
    Maximum history rows (1-100; default 20).

.PARAMETER Before
    Clean only managed clipwarp images older than this date (default 7 days ago).

.EXAMPLE
    # snip with Win+Shift+S / Lightshot / anything, then:
    clipwarp
    # -> path is now on the clipboard; go to Claude Code and press Ctrl+V

.EXAMPLE
    clipwarp watch
    # -> from now on just Ctrl+C an image anywhere, then Ctrl+V in Claude Code

.EXAMPLE
    clipwarp calendar disable
    # -> suppress Calendar prompts without stopping image conversion

.EXAMPLE
    clipwarp history -Limit 10
    clipwarp recopy 1
    clipwarp recopy
    clipwarp clean -Before (Get-Date).AddDays(-30)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('convert', 'watch', 'stop', 'status', 'autostart', 'unautostart', 'calendar', 'target', 'history', 'recopy', 'clean', 'doctor', 'help')]
    [string]$Command = 'convert',
    [Parameter(Position = 1)][string]$Action,
    [Parameter(Position = 2)][string]$Setting,
    [string]$Title,
    [string]$Details,
    [string]$Path,
    [string]$TimeZone,
    [switch]$Clipboard,
    [string]$OutDir = (Join-Path $env:USERPROFILE '.claude\pasted-images'),
    [ValidateRange(1, 100)][int]$Limit = 20,
    [datetime]$Before = (Get-Date).AddDays(-7),
    [switch]$Quiet,
    [switch]$KeepImage,
    [switch]$ImageOnly,
    [Alias('Target')]
    [ValidateSet('auto', 'chatgpt', 'claude', 'image-only', 'dual', 'text')]
    [string]$TargetMode = 'auto',
    [string]$ForegroundProcess,
    [string]$ForegroundTitle,
    [Nullable[int]]$PointerX,
    [Nullable[int]]$PointerY
)

if ($Command -in @('calendar','target','history','recopy','clean','doctor','help')) {
    Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
    switch ($Command) {
        'target' {
            $configPath = Get-ClipwarpDefaultConfigPath
            switch ($Action) {
                'status'   { Write-Host "clipwarp target: $(Get-ClipwarpTargetMode -ConfigPath $configPath)" }
                'auto'     { [void](Set-ClipwarpTargetMode -Mode auto -ConfigPath $configPath); Write-Host 'clipwarp target: auto (ChatGPT browser pastes image; terminal/Claude pastes path)' -ForegroundColor Green }
                'chatgpt'  { [void](Set-ClipwarpTargetMode -Mode chatgpt -ConfigPath $configPath); Write-Host 'clipwarp target: chatgpt (always paste pure image, no text/file path)' -ForegroundColor Green }
                'image-only' { [void](Set-ClipwarpTargetMode -Mode image-only -ConfigPath $configPath); Write-Host 'clipwarp target: image-only (always paste pure image, no text/file path)' -ForegroundColor Green }
                'claude'   { [void](Set-ClipwarpTargetMode -Mode claude -ConfigPath $configPath); Write-Host 'clipwarp target: claude (dual format: path text + image)' -ForegroundColor Green }
                'dual'     { [void](Set-ClipwarpTargetMode -Mode dual -ConfigPath $configPath); Write-Host 'clipwarp target: dual (dual format: path text + image)' -ForegroundColor Green }
                'text'     { [void](Set-ClipwarpTargetMode -Mode text -ConfigPath $configPath); Write-Host 'clipwarp target: text (file path text only)' -ForegroundColor Green }
                default    { Write-Host 'usage: clipwarp target auto|chatgpt|image-only|claude|dual|text|status' -ForegroundColor Yellow; exit 1 }
            }
        }
        'calendar' {
            $configPath = Get-ClipwarpDefaultConfigPath
            switch ($Action) {
                'enable'  { [void](Set-ClipwarpCalendarEnabled -Enabled $true -ConfigPath $configPath); Write-Host 'clipwarp calendar: enabled' -ForegroundColor Green }
                'disable' { [void](Set-ClipwarpCalendarEnabled -Enabled $false -ConfigPath $configPath); Write-Host 'clipwarp calendar: disabled (image conversion remains active)' -ForegroundColor Green }
                'status'  { $state = if (Get-ClipwarpCalendarEnabled -ConfigPath $configPath) { 'enabled' } else { 'disabled' }; Write-Host "clipwarp calendar: $state" }
                'image-details' {
                    switch($Setting){
                        'enable' {[void](Set-ClipwarpCalendarImageDetails -Mode Filename -ConfigPath $configPath); Write-Host 'clipwarp calendar image details: filename enabled (sent to Google only when the prompt is accepted)' -ForegroundColor Green}
                        'full-path' {[void](Set-ClipwarpCalendarImageDetails -Mode FullPath -ConfigPath $configPath); Write-Host 'clipwarp calendar image details: full path enabled (sent to Google only when the prompt is accepted)' -ForegroundColor Yellow}
                        'disable' {[void](Set-ClipwarpCalendarImageDetails -Mode Disabled -ConfigPath $configPath); Write-Host 'clipwarp calendar image details: disabled' -ForegroundColor Green}
                        'status' {Write-Host "clipwarp calendar image details: $(Get-ClipwarpCalendarImageDetails -ConfigPath $configPath)"}
                        default {throw 'usage: clipwarp calendar image-details enable|full-path|disable|status'}
                    }
                }
                'duration' {
                    if($Setting -eq 'status') { Write-Host "clipwarp calendar default duration: $(Get-ClipwarpCalendarDefaultDuration -ConfigPath $configPath) minutes" }
                    else {
                        $minutes = 0
                        if (-not [int]::TryParse($Setting, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) {
                            throw 'usage: clipwarp calendar duration <minutes 1-1440>|status'
                        }
                        [void](Set-ClipwarpCalendarDefaultDuration -Minutes $minutes -ConfigPath $configPath)
                        Write-Host "clipwarp calendar default duration: $minutes minutes" -ForegroundColor Green
                    }
                }
                'export' {
                    if ([string]::IsNullOrWhiteSpace($Title)) { throw 'calendar export requires -Title.' }
                    Import-Module (Join-Path $PSScriptRoot 'clipwarp-calendar.psm1') -Force
                    $target = if($Path){$Path}else{Join-Path (Get-Location) ('clipwarp-event-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.ics')}
                    $duration = Get-ClipwarpCalendarDefaultDuration -ConfigPath $configPath
                    $event = ConvertFrom-ClipwarpCalendarText -Text $Title -LocalDate (Get-Date) -DefaultDurationMinutes $duration
                    $zone = if($TimeZone){$TimeZone}else{Get-ClipwarpCalendarTimeZone}
                    $export = @{ Title=$event.Title; Details=$Details; Path=$target; TimeZone=$zone }
                    if ($event.Location) { $export.Location = $event.Location }
                    if($event.IsTimed){$export.Start=$event.Start; $export.End=$event.End}else{$export.LocalDate=$event.LocalDate}
                    $item = Export-ClipwarpIcsEvent @export
                    if($Clipboard){ Set-ClipwarpClipboardText -Value $item.FullName }
                    Write-Host "clipwarp calendar export: $($item.FullName)" -ForegroundColor Green
                }
                default {
                    Write-Host 'usage: clipwarp calendar enable|disable|status|image-details enable|full-path|disable|status|duration <minutes>|status|export' -ForegroundColor Yellow; exit 1
                }
            }
        }
        'history' {
            $historyIndex = 0
            Get-ClipwarpHistory -OutDir $OutDir -Limit $Limit |
                ForEach-Object {
                    $historyIndex++
                    [pscustomobject]@{ Index = $historyIndex; LastWriteTime = $_.LastWriteTime; Length = $_.Length; FullName = $_.FullName }
                } | Format-Table -AutoSize
        }
        'clean' {
            $removed = @(Clear-ClipwarpHistory -OutDir $OutDir -Before $Before -Confirm:$false)
            Write-Host "clipwarp clean: removed $($removed.Count) saved image(s) older than $($Before.ToString('s'))." -ForegroundColor Green
        }
        'recopy' {
            $item = if ($Action -match '^\d+$') {
                Get-ClipwarpRecopyTarget -OutDir $OutDir -Index ([int]$Action)
            } else {
                Get-ClipwarpRecopyTarget -OutDir $OutDir -Path $Action
            }
            $path = $item.FullName
            $copyWork = { param($p); Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Clipboard]::SetText($p) }
            $copyRunspace = [runspacefactory]::CreateRunspace(); $copyRunspace.ApartmentState='STA'; $copyRunspace.Open()
            $copyPs = [powershell]::Create(); $copyPs.Runspace=$copyRunspace; [void]$copyPs.AddScript($copyWork).AddArgument($path)
            try { [void]$copyPs.Invoke(); if ($copyPs.HadErrors) { throw "$($copyPs.Streams.Error[0])" } } finally { $copyPs.Dispose(); $copyRunspace.Dispose() }
            Write-Host "clipwarp recopy: $path" -ForegroundColor Green
        }
        'doctor' { Test-ClipwarpEnvironment -ScriptRoot $PSScriptRoot -OutDir $OutDir | Format-Table Name, Status, Detail -AutoSize }
        'help' { Get-Help $PSCommandPath -Detailed }
    }
    exit 0
}

if ($Command -ne 'convert') {
    $watcherScript = Join-Path $PSScriptRoot 'clipwarp-watch.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) {
        Write-Host 'clipwarp: clipwarp-watch.ps1 not found next to clipwarp.ps1 - re-run install.ps1.' -ForegroundColor Yellow
        exit 1
    }
    switch ($Command) {
        'watch'       { & $watcherScript }
        'stop'        { & $watcherScript -Stop }
        'status'      { & $watcherScript -Status }
        'autostart'   { & $watcherScript -Autostart }
        'unautostart' { & $watcherScript -NoAutostart }
    }
    exit $LASTEXITCODE
}

# All clipboard access must run on an STA thread. Windows PowerShell 5.1's
# console host is STA, but pwsh 7 defaults to MTA, so we always marshal the
# work onto a dedicated STA runspace to behave identically in both.
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
$fgInfo = Get-ClipwarpForegroundTargetInfo
$effProcess = if ($ForegroundProcess) { $ForegroundProcess } else { $fgInfo.ProcessName }
$effTitle   = if ($ForegroundTitle)   { $ForegroundTitle }   else { $fgInfo.WindowTitle }
$resolvedMode = Resolve-ClipwarpPublicationMode -Target $TargetMode -ImageOnly:$ImageOnly -KeepImage:$KeepImage -ProcessName $effProcess -WindowTitle $effTitle

$work = {
    param($OutDir, $KeepImage, $PublicationMode)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    # Guard the compiled helpers: types live in the process AppDomain, so running
    # clipwarp twice in one PS 5.1 session would otherwise throw "type already
    # exists" - which, now that we read Streams.Error, would be misreported.
    if (-not ([System.Management.Automation.PSTypeName]'ClipwarpNative.Clip').Type) {
        Add-Type -Namespace ClipwarpNative -Name Clip -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetClipboardSequenceNumber();
'@
    }

    # General BITFIELDS decoder: map arbitrary R/G/B/A channel masks into BGRA.
    # Used for the (rare) non-canonical 32bpp case that neither the fast memcpy
    # path nor GDI+ (which can't parse BITMAPV5HEADER+BITFIELDS) handles. Written
    # in C# to avoid a slow per-pixel PowerShell loop; no C#7 features so it
    # compiles under Windows PowerShell 5.1's bundled compiler too.
    if (-not ([System.Management.Automation.PSTypeName]'ClipwarpNative.Dib').Type) {
        Add-Type -Namespace ClipwarpNative -Name Dib -MemberDefinition @'
public static int Shift(uint m){ if(m==0)return 0; int s=0; while(((m>>s)&1)==0)s++; return s; }
public static int Width(uint m){ int c=0; while(m!=0){ c+=(int)(m&1u); m>>=1; } return c; }
public static byte[] DecodeMasked(byte[] dib, int srcOff, int w, int absH, int stride, bool bottomUp, uint rM, uint gM, uint bM, uint aM){
    int rS=Shift(rM), gS=Shift(gM), bS=Shift(bM), aS=Shift(aM);
    int rMax=(1<<Width(rM))-1, gMax=(1<<Width(gM))-1, bMax=(1<<Width(bM))-1, aW=Width(aM); int aMax=(1<<aW)-1;
    if(rMax<1)rMax=1; if(gMax<1)gMax=1; if(bMax<1)bMax=1; if(aMax<1)aMax=1;
    byte[] outb = new byte[w*4*absH];
    for(int y=0;y<absH;y++){
        int srcRow = bottomUp ? (absH-1-y) : y;
        int ro = srcOff + srcRow*stride;
        int wo = y*w*4;
        for(int x=0;x<w;x++){
            uint px = System.BitConverter.ToUInt32(dib, ro + x*4);
            int rv = (int)(((px & rM)>>rS)*255u/(uint)rMax);
            int gv = (int)(((px & gM)>>gS)*255u/(uint)gMax);
            int bv = (int)(((px & bM)>>bS)*255u/(uint)bMax);
            int av = (aM==0) ? 255 : (int)(((px & aM)>>aS)*255u/(uint)aMax);
            int o = wo + x*4;
            outb[o]=(byte)bv; outb[o+1]=(byte)gv; outb[o+2]=(byte)rv; outb[o+3]=(byte)av;
        }
    }
    return outb;
}
'@
    }

    # Snapshot the clipboard's change counter now. If it changes before we
    # publish (a newer image was copied while we were converting - the watcher's
    # A-then-B race), we must NOT overwrite it with this older result.
    $seq0 = [ClipwarpNative.Clip]::GetClipboardSequenceNumber()

    $out = [pscustomobject]@{ Path = $null; Kind = $null; Error = $null }

    # Clipboard calls fail with an ExternalException ("OpenClipboard failed")
    # whenever another app is holding the clipboard open at that instant - a
    # very common transient on a busy desktop. Retry briefly before giving up.
    # Reads pass -ThrowOnFail:$false and treat $null as "not available".
    # Writes pass -ThrowOnFail so an exhausted retry is a real failure, not a
    # silent success (SetText returns void, so null alone can't tell them apart).
    function Invoke-Retry {
        param([scriptblock]$Action, [int]$Tries = 10, [int]$Delay = 100, [switch]$ThrowOnFail)
        $err = $null
        for ($i = 0; $i -lt $Tries; $i++) {
            try { return (& $Action) } catch { $err = $_; Start-Sleep -Milliseconds $Delay }
        }
        if ($ThrowOnFail) { throw ($err.Exception.Message) }
        return $null
    }

    # Retry a single-attempt clipboard WRITE, re-checking the sequence number
    # before EACH attempt. This closes the TOCTOU where a one-shot 4-arg
    # SetDataObject would keep retrying across ~1s and, after a newer copy (B)
    # released the clipboard, still land the stale (A) write on top of B. If the
    # clipboard changed since we read our source, abort (watcher mode only).
    function Set-ClipboardChecked {
        param([scriptblock]$WriteOnce)
        for ($i = 0; $i -lt 10; $i++) {
            if (($KeepImage -or $PublicationMode -eq 'image-only') -and $seq0 -ne 0) {
                $now = [ClipwarpNative.Clip]::GetClipboardSequenceNumber()
                if ($now -ne 0 -and $now -ne $seq0) { throw 'clipboard-changed' }
            }
            try { & $WriteOnce; return } catch { Start-Sleep -Milliseconds 100 }
        }
        throw 'clipboard write failed after retries'
    }

    # Put the result on the clipboard.
    # Mode 'image-only' (e.g. ChatGPT web in browser): pure image/PNG, NO text/file path.
    # Mode 'dual' (-KeepImage): text path for Claude Code + original image/file.
    # Mode 'text': text only (the path).
    function Publish-Result {
        param([string]$Path, $Img, [byte[]]$PngBytes, [string]$DropFile)
        try {
            if ($PublicationMode -eq 'image-only') {
                if (-not $Img -and -not $PngBytes) {
                    if ($DropFile -and (Test-Path -LiteralPath $DropFile -PathType Leaf)) {
                        try { $PngBytes = [System.IO.File]::ReadAllBytes($DropFile) } catch {}
                    } elseif ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
                        try { $PngBytes = [System.IO.File]::ReadAllBytes($Path) } catch {}
                    }
                }
                $do = New-Object System.Windows.Forms.DataObject
                if ($PngBytes) {
                    $do.SetData('PNG', (New-Object System.IO.MemoryStream (,$PngBytes)))
                    if (-not $Img) { $Img = New-ImageFromBytes $PngBytes }
                }
                if ($Img) { $do.SetImage($Img) }
                Set-ClipboardChecked { [System.Windows.Forms.Clipboard]::SetDataObject($do, $true) }
            }
            elseif ($PublicationMode -eq 'dual') {
                $do = New-Object System.Windows.Forms.DataObject
                $do.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Path)
                if ($PngBytes) {
                    $do.SetData('PNG', (New-Object System.IO.MemoryStream (,$PngBytes)))
                    if (-not $Img) { $Img = New-ImageFromBytes $PngBytes }
                }
                if ($Img) { $do.SetImage($Img) }
                if ($DropFile) {
                    $sc = New-Object System.Collections.Specialized.StringCollection
                    [void]$sc.Add($DropFile)
                    $do.SetFileDropList($sc)
                }
                Set-ClipboardChecked { [System.Windows.Forms.Clipboard]::SetDataObject($do, $true) }
            }
            else {
                Set-ClipboardChecked { [System.Windows.Forms.Clipboard]::SetText($Path) }
            }
        }
        finally {
            if ($Img) { $Img.Dispose() }
        }
    }

    function New-OutPath {
        if (-not (Test-Path -LiteralPath $OutDir)) {
            New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        }
        Join-Path $OutDir ('clip-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.png')
    }

    # Load an image from bytes into an INDEPENDENT Bitmap. Image.FromStream keeps a
    # reference to the stream for the image's lifetime, so an anonymous MemoryStream
    # would be GC-collectable and later Save/SetImage could fail; clone into a new
    # Bitmap and dispose the source + stream immediately (returns $null on failure).
    function New-ImageFromBytes {
        param([byte[]]$Bytes)
        $ms = New-Object System.IO.MemoryStream (,$Bytes)
        try {
            $src = [System.Drawing.Image]::FromStream($ms)
            try { return (New-Object System.Drawing.Bitmap $src) } finally { $src.Dispose() }
        } catch { return $null }
        finally { $ms.Dispose() }
    }

    # Claude Code attaches png/jpg/jpeg/gif/webp but NOT bmp, so transcode a
    # .bmp source file to PNG. Returns the new PNG path (via -out ref-like object)
    # or $null on failure. Reads through a byte[] so the source file isn't locked.
    function ConvertTo-PngFile {
        param([string]$SrcFile)
        try {
            $bytes = [System.IO.File]::ReadAllBytes($SrcFile)
            $im = New-ImageFromBytes $bytes
            if (-not $im) { return $null }
            $path = New-OutPath
            $im.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            return @{ Path = $path; Img = $im }
        } catch { return $null }
    }

    function Read-StreamBytes ($obj) {
        if ($obj -is [System.IO.MemoryStream]) { return $obj.ToArray() }
        if ($obj -is [System.IO.Stream]) {
            $ms = New-Object System.IO.MemoryStream
            $obj.CopyTo($ms)
            return $ms.ToArray()
        }
        if ($obj -is [byte[]]) { return $obj }
        return $null
    }

    $data = Invoke-Retry { [System.Windows.Forms.Clipboard]::GetDataObject() }

    # --- 1. A real image FILE on the clipboard (Ctrl+C on a .png in Explorer) ---
    $dropList = Invoke-Retry { [System.Windows.Forms.Clipboard]::GetFileDropList() }
    if ($dropList) {
        foreach ($f in $dropList) {
            if ($f -match '\.(png|jpe?g|gif|webp)$' -and (Test-Path -LiteralPath $f -PathType Leaf)) {
                Publish-Result -Path $f -DropFile $f
                $out.Path = $f
                $out.Kind = 'file'
                return $out
            }
            if ($f -match '\.bmp$' -and (Test-Path -LiteralPath $f -PathType Leaf)) {
                $c = ConvertTo-PngFile $f
                if ($c) {
                    Publish-Result -Path $c.Path -Img $c.Img
                    $out.Path = $c.Path
                    $out.Kind = 'file-bmp'
                    return $out
                }
            }
        }
    }

    # --- 2. A raw PNG stream (Lightshot, Chrome, Firefox, Discord, ShareX...) ---
    # Best fidelity: the source app's own PNG encode, alpha preserved.
    if ($data) {
        foreach ($fmt in @('PNG', 'image/png')) {
            if ($data.GetDataPresent($fmt)) {
                $bytes = Read-StreamBytes ($data.GetData($fmt))
                # PNG signature: 89 50 4E 47
                if ($bytes -and $bytes.Length -gt 8 -and
                    $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
                    $path = New-OutPath
                    [System.IO.File]::WriteAllBytes($path, $bytes)
                    Publish-Result -Path $path -PngBytes $bytes
                    $out.Path = $path
                    $out.Kind = 'png-stream'
                    return $out
                }
            }
        }
    }

    # --- 3. A standard bitmap (Snipping Tool, Win+Shift+S; CF_BITMAP/CF_DIB) ---
    if (Invoke-Retry { [System.Windows.Forms.Clipboard]::ContainsImage() }) {
        $img = Invoke-Retry { [System.Windows.Forms.Clipboard]::GetImage() }
        if ($img) {
            $path = New-OutPath
            $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            Publish-Result -Path $path -Img $img
            $out.Path = $path
            $out.Kind = 'bitmap'
            return $out
        }
    }

    # --- 4. CF_DIBV5 / Format17 only (alpha-aware apps; GetImage misses these) ---
    # GDI+ chokes on BITMAPV5HEADER + BI_BITFIELDS streams, so decode the common
    # 32bpp case by hand and only fall back to a GDI+ BMP-wrap for the rest.
    if ($data) {
        foreach ($fmt in @('Format17', [System.Windows.Forms.DataFormats]::Dib)) {
            if (-not $data.GetDataPresent($fmt)) { continue }
            $dib = Read-StreamBytes ($data.GetData($fmt))
            if (-not $dib -or $dib.Length -lt 40) { continue }
            try {
                $biSize        = [BitConverter]::ToUInt32($dib, 0)
                $w             = [BitConverter]::ToInt32($dib, 4)
                $h             = [BitConverter]::ToInt32($dib, 8)
                $biBitCount    = [BitConverter]::ToUInt16($dib, 14)
                $biCompression = [BitConverter]::ToUInt32($dib, 16)
                $biClrUsed     = [BitConverter]::ToUInt32($dib, 32)
                # BI_BITFIELDS carries R/G/B (and, for V4/V5, A) channel masks.
                # For a size-40 header they sit right after it (offset 40/44/48);
                # V4/V5 headers embed them at the same offsets, plus alpha at 52.
                # We only hand-decode the canonical BGRA layout - anything else is
                # left to GDI+ (below), which honors arbitrary masks correctly.
                $rMask = 0; $gMask = 0; $bMask = 0; $alphaMask = 0
                if ($biCompression -eq 3 -and $dib.Length -ge 52) {
                    $rMask = [BitConverter]::ToUInt32($dib, 40)
                    $gMask = [BitConverter]::ToUInt32($dib, 44)
                    $bMask = [BitConverter]::ToUInt32($dib, 48)
                }
                if ($biSize -ge 108 -and $dib.Length -ge 56) { $alphaMask = [BitConverter]::ToUInt32($dib, 52) }
                $canonicalBgra = $false
                if ($biCompression -eq 0) {
                    $canonicalBgra = $true                       # BI_RGB 32bpp == BGRx by definition
                }
                elseif ($biCompression -eq 3) {
                    $canonicalBgra = ($rMask -eq 0x00FF0000 -and $gMask -eq 0x0000FF00 -and $bMask -eq 0x000000FF -and
                                      ($alphaMask -eq [uint32]'0xFF000000' -or $alphaMask -eq 0))
                }
                $palette = 0
                if ($biClrUsed -gt 0) { $palette = $biClrUsed * 4 }
                elseif ($biBitCount -le 8) { $palette = [int][math]::Pow(2, $biBitCount) * 4 }
                $masks = 0
                if ($biCompression -eq 3 -and $biSize -eq 40) { $masks = 12 }  # BI_BITFIELDS with plain BITMAPINFOHEADER
                $srcOff = [int]($biSize + $masks + $palette)
                $img = $null

                if ($biBitCount -eq 32 -and $canonicalBgra -and $w -gt 0 -and $h -ne 0) {
                    # Manual decode: canonical BGRA rows, 4-byte aligned by construction.
                    $absH = [math]::Abs($h)
                    $stride = $w * 4
                    $need = $srcOff + $stride * $absH
                    if ($dib.Length -lt $need) {
                        # Some OLE roundtrips shave a few trailing bytes; zero-pad.
                        $padded = New-Object byte[] $need
                        [Array]::Copy($dib, $padded, $dib.Length)
                        $dib = $padded
                    }
                    # Decide whether these 32bpp pixels actually carry alpha.
                    # Scans are bounded to $need (pixel data) so trailing V5
                    # bytes - e.g. an embedded ICC profile - never skew the test.
                    $forceOpaque = $false
                    if ($biCompression -eq 3 -and $biSize -eq 40) {
                        $forceOpaque = $true                       # BITFIELDS w/ only R,G,B masks: no alpha
                    }
                    elseif ($biSize -ge 108 -and $alphaMask -eq 0) {
                        $forceOpaque = $true                       # V4/V5 explicitly declares no alpha
                    }
                    elseif ($biCompression -eq 0) {
                        # BI_RGB: the 4th byte is officially undefined. If not one
                        # pixel sets it, the source meant opaque (xBGR) - force
                        # A=255 or the PNG comes out fully transparent.
                        $anyAlpha = $false
                        for ($i = $srcOff + 3; $i -lt $need; $i += 4) {
                            if ($dib[$i] -ne 0) { $anyAlpha = $true; break }
                        }
                        if (-not $anyAlpha) { $forceOpaque = $true }
                    }
                    if ($forceOpaque) {
                        for ($i = $srcOff + 3; $i -lt $need; $i += 4) { $dib[$i] = 255 }
                    }
                    $bmp = New-Object System.Drawing.Bitmap $w, $absH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $absH
                    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    for ($y = 0; $y -lt $absH; $y++) {
                        $srcRow = $y                                  # top-down (negative height)
                        if ($h -gt 0) { $srcRow = $absH - 1 - $y }    # bottom-up (positive height)
                        [System.Runtime.InteropServices.Marshal]::Copy($dib, $srcOff + $srcRow * $stride, [IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $stride)
                    }
                    $bmp.UnlockBits($bd)
                    $img = $bmp
                }
                elseif ($biBitCount -eq 32 -and $biCompression -eq 3 -and $w -gt 0 -and $h -ne 0) {
                    # Non-canonical BITFIELDS masks: GDI+ can't parse
                    # BITMAPV5HEADER+BITFIELDS, so decode the channels ourselves.
                    $absH = [math]::Abs($h)
                    $stride = $w * 4
                    $need = $srcOff + $stride * $absH
                    if ($dib.Length -lt $need) {
                        $padded = New-Object byte[] $need
                        [Array]::Copy($dib, $padded, $dib.Length)
                        $dib = $padded
                    }
                    $bgra = [ClipwarpNative.Dib]::DecodeMasked($dib, $srcOff, $w, $absH, $stride, ($h -gt 0), [uint32]$rMask, [uint32]$gMask, [uint32]$bMask, [uint32]$alphaMask)
                    $bmp = New-Object System.Drawing.Bitmap $w, $absH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $absH
                    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    for ($y = 0; $y -lt $absH; $y++) {
                        [System.Runtime.InteropServices.Marshal]::Copy($bgra, $y * $stride, [IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $stride)
                    }
                    $bmp.UnlockBits($bd)
                    $img = $bmp
                }
                else {
                    # Everything else: wrap in a BITMAPFILEHEADER and let GDI+ try.
                    $ms = New-Object System.IO.MemoryStream
                    $bw = New-Object System.IO.BinaryWriter $ms
                    $bw.Write([byte]0x42); $bw.Write([byte]0x4D)     # 'BM'
                    $bw.Write([uint32](14 + $dib.Length))             # bfSize
                    $bw.Write([uint16]0); $bw.Write([uint16]0)        # reserved
                    $bw.Write([uint32](14 + $srcOff))                 # bfOffBits
                    $bw.Write($dib)
                    $bw.Flush(); $ms.Position = 0
                    $bmpSrc = [System.Drawing.Image]::FromStream($ms)
                    try { $img = New-Object System.Drawing.Bitmap $bmpSrc } finally { $bmpSrc.Dispose() }
                }

                if ($img) {
                    $path = New-OutPath
                    $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                    Publish-Result -Path $path -Img $img
                    $out.Path = $path
                    $out.Kind = 'dibv5'
                    return $out
                }
            } catch { if ($_.Exception.Message -match 'clipboard-changed|clipboard write failed') { throw } }
        }
    }

    # --- 5. HTML with an embedded image (browser "copy image" fallback) ---
    if ($data -and $data.GetDataPresent([System.Windows.Forms.DataFormats]::Html)) {
        $html = [string]$data.GetData([System.Windows.Forms.DataFormats]::Html)
        if ($html) {
            $m = [regex]::Match($html, 'data:image/(png|jpe?g|gif|webp);base64,([A-Za-z0-9+/=\s]+)')
            if ($m.Success) {
                try {
                    $bytes = [Convert]::FromBase64String(($m.Groups[2].Value -replace '\s', ''))
                    $ext = $m.Groups[1].Value -replace 'jpg', 'jpeg'
                    $path = New-OutPath
                    if ($ext -ne 'png') { $path = $path -replace '\.png$', ".$ext" }
                    [System.IO.File]::WriteAllBytes($path, $bytes)
                    if ($ext -eq 'png') {
                        Publish-Result -Path $path -PngBytes $bytes
                    }
                    else {
                        $im = New-ImageFromBytes $bytes
                        Publish-Result -Path $path -Img $im
                    }
                    $out.Path = $path
                    $out.Kind = 'html-data'
                    return $out
                } catch { if ($_.Exception.Message -match 'clipboard-changed|clipboard write failed') { throw } }
            }
            $m = [regex]::Match($html, 'src\s*=\s*["'']file:///([^"''\s>]+)')
            if ($m.Success) {
                $p = [Uri]::UnescapeDataString($m.Groups[1].Value) -replace '/', '\'
                if ($p -match '\.(png|jpe?g|gif|webp)$' -and (Test-Path -LiteralPath $p)) {
                    Publish-Result -Path $p -DropFile $p
                    $out.Path = $p
                    $out.Kind = 'file'
                    return $out
                }
                if ($p -match '\.bmp$' -and (Test-Path -LiteralPath $p)) {
                    $c = ConvertTo-PngFile $p
                    if ($c) {
                        Publish-Result -Path $c.Path -Img $c.Img
                        $out.Path = $c.Path
                        $out.Kind = 'file-bmp'
                        return $out
                    }
                }
            }
        }
    }

    # --- 6. Plain text that is already a path to an image file ---
    $txt = Invoke-Retry { [System.Windows.Forms.Clipboard]::GetText() }
    if ($txt) {
        $p = $txt.Trim().Trim('"').Trim("'")
        if ($p -match '\.(png|jpe?g|gif|webp)$' -and (Test-Path -LiteralPath $p)) {
            Publish-Result -Path $p
            $out.Path = $p
            $out.Kind = 'file'
            return $out
        }
        if ($p -match '\.bmp$' -and (Test-Path -LiteralPath $p)) {
            $c = ConvertTo-PngFile $p
            if ($c) {
                Publish-Result -Path $c.Path -Img $c.Img
                $out.Path = $c.Path
                $out.Kind = 'file-bmp'
                return $out
            }
        }
    }

    $out.Error = 'no-image'
    return $out
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.ThreadOptions = 'ReuseThread'
$rs.Open()
$ps = [powershell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript($work).AddArgument($OutDir).AddArgument([bool]$KeepImage).AddArgument([string]$resolvedMode)
$changed  = $false
$writeErr = $null
try { $invoked = $ps.Invoke() }
catch {
    # Some hosts do surface a terminating error here; classify it too.
    if ($_.Exception.Message -match 'clipboard-changed') { $changed = $true }
    elseif (-not $writeErr) { $writeErr = $_.Exception.Message }
    $invoked = @()
}
finally {
    # In the PowerShell SDK a terminating error inside Invoke() usually lands in
    # Streams.Error rather than the host try/catch above (verified on PS 7.4:
    # Invoke returns 0 objects, HadErrors=$true, catch not entered). Read and
    # classify it BEFORE disposing, or 'clipboard-changed' / a real write failure
    # would be lost and misreported as "no image".
    try {
        foreach ($e in @($ps.Streams.Error)) {
            $m = "$e"
            if ($m -match 'clipboard-changed') { $changed = $true }
            elseif ($m -and -not $writeErr)    { $writeErr = $m }
        }
    } catch {}
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
}

$r = $invoked | Where-Object { $_ -is [pscustomobject] } | Select-Object -Last 1

if ($changed) {
    # A newer image landed on the clipboard mid-conversion; we deliberately
    # skipped overwriting it. Not an error - the watcher handles the new one.
    if (-not $Quiet) { Write-Host 'clipwarp: clipboard changed mid-convert - skipped (newer image will be handled).' -ForegroundColor DarkGray }
    exit 0
}

if ($writeErr -or ($r -and $r.Error -eq 'clipboard-write')) {
    $msg = if ($writeErr) { $writeErr } else { $r.Error }
    Write-Host "clipwarp: conversion did not complete - $msg" -ForegroundColor Red
    exit 1
}

if (-not $r -or $r.Error -eq 'no-image' -or -not $r.Path) {
    Write-Host 'clipwarp: no image on the clipboard.' -ForegroundColor Yellow
    Write-Host '  1) snip or copy an image in any app, then' -ForegroundColor DarkGray
    Write-Host '  2) run clipwarp again.' -ForegroundColor DarkGray
    exit 1
}

# Best-effort housekeeping: drop PNGs older than 7 days so the folder never grows unbounded.
try {
    Get-ChildItem -LiteralPath $OutDir -Filter 'clip-*' -ErrorAction Stop |
        Where-Object { $_.Extension -match '^\.(png|jpe?g|gif|webp)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

if (-not $Quiet) {
    $verb = switch ($r.Kind) {
        'file'       { 'using existing file' }
        'file-bmp'   { 'transcoded BMP -> PNG ->' }
        'png-stream' { 'saved PNG stream ->' }
        'dibv5'      { 'saved DIBv5 bitmap ->' }
        'html-data'  { 'extracted from HTML ->' }
        default      { 'saved bitmap ->' }
    }
    Write-Host "clipwarp: $verb $($r.Path)" -ForegroundColor Green
    if ($resolvedMode -eq 'image-only') {
        Write-Host 'image copied to clipboard (ChatGPT target). Switch to ChatGPT and press Ctrl+V.' -ForegroundColor Cyan
    } else {
        Write-Host 'path copied to clipboard. Switch to Claude Code and press Ctrl+V.' -ForegroundColor Cyan
    }
}

# Show the same short-lived, non-blocking calendar prompt in manual and watcher
# conversions. It never reads or writes the clipboard.
try {
    Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
    if (-not (Get-ClipwarpCalendarEnabled)) { throw 'calendar-disabled' }
    Import-Module (Join-Path $PSScriptRoot 'clipwarp-calendar.psm1') -Force
    $imageTitle = 'Clipboard image ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Start-ClipwarpCalendarPopup -Kind Image -Title $imageTitle -ImagePath $r.Path -PointerX $PointerX -PointerY $PointerY -ScriptRoot $PSScriptRoot
} catch {
    if ($_.Exception.Message -ne 'calendar-disabled' -and -not $Quiet) { Write-Host "clipwarp: calendar popup could not be shown - $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Always emit the raw path last so it is usable in a pipeline too.
$r.Path
exit 0
