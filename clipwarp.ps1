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
    Start the watcher explicitly; updates restart only an already running watcher.
    Login autostart remains opt-in.
    calendar enable|disable|status - configure Calendar prompts independently.
    calendar image-details enable|full-path|disable|status - image path privacy.
    calendar duration <minutes>|status - timed-event default (1-1440 minutes).
    calendar export -Title <text> [-Details <text>] [-Path <file>] [-TimeZone <id>] - local ICS.
    privacy pause|resume|status|retention <days 0-3650> - pause processing / opt-in cleanup.
    target auto|web|chatgpt|image-only|claude|dual|text|status - publication mode.
    history | recopy | clean - inspect, explicitly recopy, or prune saved images.
    doctor [-Json] - read-only structured installation and environment diagnostics.
    version [-Json] - installed origin/version metadata, or development checkout.
    clean -Preview|-WhatIf - show managed cleanup without deleting files.
    ChatGPT popup action opens a temporary chat for MANUAL paste/send; never auto-sends.
    PNG/JPEG/BMP/GIF first frame require decoding; WebP requires an available decoder.
    Invalid explicit calendar dates require review; unrecognized text defaults to tomorrow.

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
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('convert', 'watch', 'stop', 'status', 'autostart', 'unautostart', 'privacy', 'calendar', 'target', 'history', 'recopy', 'clean', 'doctor', 'version', 'actions', 'popup', 'help')]
    [string]$Command = 'convert',
    [Parameter(Position = 1)][string]$Action,
    [Parameter(Position = 2)][string]$Setting,
    [string]$Title,
    [string]$Details,
    [string]$Path,
    [string]$TimeZone,
    [switch]$Clipboard,
    [switch]$Json,
    [switch]$Preview,
    [string]$OutDir = (Join-Path $env:USERPROFILE '.claude\pasted-images'),
    [ValidateRange(1, 100)][int]$Limit = 20,
    [datetime]$Before = (Get-Date).AddDays(-7),
    [switch]$Quiet,
    [switch]$KeepImage,
    [switch]$ImageOnly,
    [Alias('Target')]
    [ValidateSet('auto', 'chatgpt', 'claude', 'image-only', 'dual', 'text', 'web')]
    [string]$TargetMode = 'auto',
    [string]$ForegroundProcess,
    [string]$ForegroundTitle,
    [string]$ForegroundClass,
    [Nullable[int]]$PointerX,
    [Nullable[int]]$PointerY
)

# WhatIf must not launch a watcher, popup, browser, clipboard operation or mutate settings.
# Clean delegates to its per-file preview so the exact managed candidates are visible.
if ($WhatIfPreference -and $Command -notin @('clean','history','doctor','version','help')) {
    [void]$PSCmdlet.ShouldProcess(('clipwarp ' + $Command + ' ' + $Action + ' ' + $Setting), 'Execute command')
    return
}

if ($Command -in @('privacy','calendar','target','history','recopy','clean','doctor','version','actions','popup','help')) {
    Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
    switch ($Command) {
        'actions' {
            if ($Action -notin @('calendar','chatgpt','runCommand')) { throw 'usage: clipwarp actions calendar|chatgpt|runCommand enable|disable|status' }
            if ($Setting -notin @('enable','disable','status')) { throw 'usage: clipwarp actions calendar|chatgpt|runCommand enable|disable|status' }
            if ($Setting -eq 'status') { Get-ClipwarpActionEnabled -Action $Action }
            else { Set-ClipwarpActionEnabled -Action $Action -Enabled ($Setting -eq 'enable') }
        }
        'popup' {
            if ($Action -ne 'duration') { throw 'usage: clipwarp popup duration <seconds>|status' }
            if ($Setting -eq 'status') { (Get-ClipwarpConfig).popup.durationSeconds }
            else {
                $seconds = 0
                if (-not [int]::TryParse($Setting,[ref]$seconds) -or $seconds -lt 3 -or $seconds -gt 300) { throw 'popup duration requires seconds 3-300' }
                Set-ClipwarpConfigProperty -Name 'popup.durationSeconds' -Value $seconds
            }
        }
        'privacy' {
            switch ($Action) {
                'pause' { Set-ClipwarpPaused -Paused $true; Write-Host 'clipwarp: paused' }
                'resume' { Set-ClipwarpPaused -Paused $false; Write-Host 'clipwarp: resumed; copy again' }
                'status' { Write-Host "clipwarp privacy: paused=$(Get-ClipwarpPaused), retentionDays=$(Get-ClipwarpRetentionDays) (0 disables cleanup)" }
                'retention' {
                    $days=0
                    if (-not [int]::TryParse($Setting,[ref]$days) -or $days -lt 0 -or $days -gt 3650) { throw 'retention requires days 0-3650' }
                    Set-ClipwarpRetentionDays -Days $days
                }
                default { throw 'usage: clipwarp privacy pause|resume|status|retention <days 0-3650>' }
            }
        }
        'target' {
            $configPath = Get-ClipwarpDefaultConfigPath
            switch ($Action) {
                'status'   { Write-Host "clipwarp target: $(Get-ClipwarpTargetMode -ConfigPath $configPath)" }
                'explain' {
                    $targetInfo = Get-ClipwarpForegroundTargetInfo
                    $process = if ($ForegroundProcess) { $ForegroundProcess } else { $targetInfo.ProcessName }
                    $caption = if ($ForegroundTitle) { $ForegroundTitle } else { $targetInfo.WindowTitle }
                    $windowClass = if ($ForegroundClass) { $ForegroundClass } else { $targetInfo.WindowClass }
                    $controls = if ($targetInfo.PSObject.Properties['HasFilePickerControls']) { [bool]$targetInfo.HasFilePickerControls } else { $false }
                    $decision = Get-ClipwarpTargetExplanation -TargetMode $TargetMode -ProcessName $process -WindowTitle $caption -WindowClass $windowClass -HasFilePickerControls $controls -ConfigPath $configPath
                    # Do not include window captions: they may contain document names or copied text.
                    $explanation = [pscustomobject]@{ ProcessName=$process; WindowClass=$windowClass; Mode=$decision.Mode; Reason=$decision.Reason; MatchedRule=$decision.MatchedRule; BrowserOriginVerified=$false }
                    if ($Json) { $explanation | ConvertTo-Json } else { $explanation | Format-List }
                }
                'auto'     { [void](Set-ClipwarpTargetMode -Mode auto -ConfigPath $configPath); Write-Host 'clipwarp target: auto (file picker & terminal/Claude paste file path; all other apps paste image)' -ForegroundColor Green }
                'web'      { [void](Set-ClipwarpTargetMode -Mode web -ConfigPath $configPath); Write-Host 'clipwarp target: web (always paste pure image, no text/file path)' -ForegroundColor Green }
                'chatgpt'  { [void](Set-ClipwarpTargetMode -Mode chatgpt -ConfigPath $configPath); Write-Host 'clipwarp target: chatgpt (always paste pure image, no text/file path)' -ForegroundColor Green }
                'image-only' { [void](Set-ClipwarpTargetMode -Mode image-only -ConfigPath $configPath); Write-Host 'clipwarp target: image-only (always paste pure image, no text/file path)' -ForegroundColor Green }
                'claude'   { [void](Set-ClipwarpTargetMode -Mode claude -ConfigPath $configPath); Write-Host 'clipwarp target: claude (dual format: path text + image)' -ForegroundColor Green }
                'dual'     { [void](Set-ClipwarpTargetMode -Mode dual -ConfigPath $configPath); Write-Host 'clipwarp target: dual (dual format: path text + image)' -ForegroundColor Green }
                'text'     { [void](Set-ClipwarpTargetMode -Mode text -ConfigPath $configPath); Write-Host 'clipwarp target: text (file path text only)' -ForegroundColor Green }
                default    { Write-Host 'usage: clipwarp target auto|web|chatgpt|image-only|claude|dual|text|status' -ForegroundColor Yellow; exit 1 }
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
                    if ($event.PSObject.Properties['NeedsReview'] -and $event.NeedsReview) {
                        throw 'Calendar date needs review. Correct the explicit date before exporting.'
                    }
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
            if ($Preview -or $WhatIfPreference) {
                Clear-ClipwarpHistory -OutDir $OutDir -Before $Before -WhatIf
                Write-Host 'clipwarp clean: preview only; no files deleted.'
            } elseif ($PSCmdlet.ShouldProcess($OutDir, 'Delete managed images older than the cutoff')) {
                $removed = @(Clear-ClipwarpHistory -OutDir $OutDir -Before $Before -Confirm:$false)
                Write-Host "clipwarp clean: removed $($removed.Count) saved image(s) older than $($Before.ToString('s'))." -ForegroundColor Green
            }
            Write-Host 'Settings, unrelated files, Windows Clipboard History and cloud copies are retained.'
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
        'doctor' {
            $diagnostics = @(Test-ClipwarpEnvironment -ScriptRoot $PSScriptRoot -OutDir $OutDir)
            if ($Json) { $diagnostics | ConvertTo-Json -Depth 8 } else { $diagnostics | Format-Table Name, Status, Detail -AutoSize }
        }
        'version' {
            $metadata = Get-ClipwarpInstalledMetadata -ScriptRoot $PSScriptRoot
            if ($Json) { $metadata | ConvertTo-Json -Depth 8 } else { $metadata | Format-List }
        }
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
if (Get-ClipwarpPaused) { if (-not $Quiet) { Write-Host 'clipwarp: paused' }; exit 0 }
$fgInfo = Get-ClipwarpForegroundTargetInfo
$effProcess = if ($ForegroundProcess) { $ForegroundProcess } else { $fgInfo.ProcessName }
$effTitle   = if ($ForegroundTitle)   { $ForegroundTitle }   else { $fgInfo.WindowTitle }
$effClass   = if ($ForegroundClass)   { $ForegroundClass }   else { $fgInfo.WindowClass }
$resolvedMode = Resolve-ClipwarpPublicationMode -Target $TargetMode -ImageOnly:$ImageOnly -KeepImage:$KeepImage -ProcessName $effProcess -WindowTitle $effTitle -WindowClass $effClass -HasFilePickerControls ([bool]$fgInfo.HasFilePickerControls)

$work = {
    param($OutDir, $KeepImage, $PublicationMode, $ScriptRoot, $TargetMode, $ImageOnly)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Import-Module (Join-Path $ScriptRoot 'clipwarp-support.psm1') -Force
    foreach ($helper in @(@('ClipwarpTransport.ClipboardWriter', 'clipwarp-clipboard.cs'), @('ClipwarpImages.ImageHelper', 'clipwarp-image.cs'))) {
        if (-not ($helper[0] -as [type])) {
            $source = [IO.File]::ReadAllText((Join-Path $ScriptRoot $helper[1]))
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $refs = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
                $refs += @([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
                $refs += [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
                Add-Type -TypeDefinition $source -ReferencedAssemblies ($refs | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
            } else { Add-Type -TypeDefinition $source -ReferencedAssemblies System,System.Windows.Forms,System.Drawing }
        }
    }
    if (-not ('ClipwarpNative.Clip' -as [type])) {
        Add-Type -Namespace ClipwarpNative -Name Clip -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetClipboardSequenceNumber();
'@
    }

    function New-ConversionLimits {
        param($Config)
        $limits = New-Object ClipwarpImages.ImageLimits
        # Optional imageLimits overrides are validated and fail closed.
        $section = $Config.imageLimits
        if ($null -ne $section) {
            foreach ($name in @('MaxSourceBytes', 'MaxDimension', 'MaxWidth', 'MaxHeight', 'MaxPixels', 'MaxDecodedBytes')) {
                $value = $section.$name
                if ($null -ne $value) {
                    $number = 0L
                    if (-not [long]::TryParse([string]$value, [ref]$number)) { throw "Invalid image limit: $name" }
                    if ($name -in @('MaxDimension','MaxWidth','MaxHeight')) { $limits.$name = [int]$number }
                    else { $limits.$name = $number }
                }
            }
        }
        $limits.Validate()
        return $limits
    }

    function Read-StreamBytes {
        param($Value, [long]$MaxBytes)
        if ($MaxBytes -lt 1 -or $MaxBytes -gt 268435456) { throw 'Invalid source byte budget' }
        if ($Value -is [byte[]]) {
            if ($Value.LongLength -gt $MaxBytes) { throw 'Image source exceeds resource limits' }
            return ,$Value
        }
        if ($Value -isnot [IO.Stream]) { throw 'Unsupported image stream' }
        # OLE owns the input; preserve its position and do not dispose it.
        $position = $null
        $copy = New-Object IO.MemoryStream
        try {
            if ($Value.CanSeek) {
                $position = $Value.Position
                if ($Value.Length -gt $MaxBytes) { throw 'Image source exceeds resource limits' }
                $Value.Position = 0
            }
            $buffer = New-Object byte[] 8192
            while (($count = $Value.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($copy.Length + $count -gt $MaxBytes) { throw 'Image source exceeds resource limits' }
                $copy.Write($buffer, 0, $count)
            }
            return ,$copy.ToArray()
        } finally {
            $copy.Dispose()
            if ($null -ne $position) { $Value.Position = $position }
        }
    }

    function New-PngStreamPayload {
        param([byte[]]$Bytes, $Limits)
        if (-not [ClipwarpImages.ImageHelper]::HasPngSignature($Bytes)) { throw 'Invalid PNG signature' }
        return [ClipwarpImages.ImageHelper]::FromBytes($Bytes, $Limits)
    }

    function Save-OwnedPng {
        param($Payload, [string]$Directory, $OwnedFiles)
        $Directory = Assert-ClipwarpSafeDirectory -Directory $Directory
        [void][IO.Directory]::CreateDirectory($Directory)
        $path = Join-Path $Directory ('clip-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N') + '.png')
        $bytes = $Payload.GetPngBytes()
        # Exclusive creation cannot truncate existing files, even on collision.
        $stream = New-Object IO.FileStream $path, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
        try {
            [void]$OwnedFiles.Add($path)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally { $stream.Dispose() }
        return $path
    }

    function Remove-AbortedFiles {
        param($OwnedFiles, [bool]$PublicationAttempted)
        # The native writer may fail after publishing some formats. Retain files
        # after any write attempt rather than delete a potentially referenced path.
        if ($PublicationAttempted) { return }
        foreach ($path in $OwnedFiles) {
            try {
                [void](Assert-ClipwarpSafeDirectory -Directory ([IO.Path]::GetDirectoryName($path)))
                if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { [IO.File]::Delete($path) }
            } catch { }
        }
    }

    function New-ConversionPublication {
        param([string]$Mode, [string]$Path, $Payload)
        if ($Mode -notin @('text', 'dual', 'image-only')) { throw 'Invalid publication mode' }
        if (-not $Path) { throw 'Missing publication path' }
        $image = $null; $pngStream = $null
        try {
            $data = New-Object System.Windows.Forms.DataObject
            $data.SetData('ClipwarpManaged', $Path)
            if ($Mode -ne 'image-only') { $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Path) }
            if ($Mode -ne 'text') {
                if (-not $Payload) { throw 'Image publication requires a decoded image' }
                $bytes = $Payload.GetPngBytes()
                if (-not [ClipwarpImages.ImageHelper]::HasPngSignature($bytes)) { throw 'Invalid encoded PNG' }
                $pngStream = New-Object IO.MemoryStream (,$bytes)
                $image = $Payload.CreateBitmap()
                $data.SetData('PNG', $pngStream)
                $data.SetImage($image)
                if ($Mode -eq 'dual') {
                    $files = New-Object System.Collections.Specialized.StringCollection
                    [void]$files.Add($Path)
                    $data.SetFileDropList($files)
                }
            }
            return [pscustomobject]@{ Data = $data; Image = $image; Stream = $pngStream }
        } catch {
            if ($image) { $image.Dispose() }
            if ($pngStream) { $pngStream.Dispose() }
            throw
        }
    }

    function Invoke-Retry {
        param([scriptblock]$Action)
        for ($i = 0; $i -lt 10; $i++) {
            try { return (& $Action) } catch { if ($i -eq 9) { throw }; Start-Sleep -Milliseconds 100 }
        }
    }

    function Publish-Result {
        param([string]$Path, $Payload, $Operation)
        # Decode can take seconds: discard the launch-time foreground hints.
        $currentTarget = Get-ClipwarpForegroundTargetInfo
        $PublicationMode = Resolve-ClipwarpPublicationMode -Target $TargetMode -ImageOnly:$ImageOnly -KeepImage:$KeepImage -ProcessName $currentTarget.ProcessName -WindowTitle $currentTarget.WindowTitle -WindowClass $currentTarget.WindowClass -HasFilePickerControls ([bool]$currentTarget.HasFilePickerControls)
        $targetKey = $currentTarget | ConvertTo-Json -Compress
        $publication = New-ConversionPublication -Mode $PublicationMode -Path $Path -Payload $Payload
        try {
            for ($i = 0; $i -lt 10; $i++) {
                if (Get-ClipwarpPaused) { throw 'clipboard-changed' }
                if (((Get-ClipwarpForegroundTargetInfo) | ConvertTo-Json -Compress) -ne $targetKey) { throw 'clipboard-changed' }
                $now = [ClipwarpNative.Clip]::GetClipboardSequenceNumber()
                if (-not [ClipwarpTransport.ClipboardWriter]::SequenceMatches($seq0, $now)) { throw 'clipboard-changed' }
                try {
                    $Operation.PublicationAttempted = $true
                    # Native Publish compares seq0 under OpenClipboard before EmptyClipboard.
                    $formats = [ClipwarpTransport.ClipboardWriter]::PrepareNative($publication.Data)
                    $guard = [Func[bool]]{ ((Get-ClipwarpForegroundTargetInfo | ConvertTo-Json -Compress) -eq $targetKey) }
                    [void][ClipwarpTransport.ClipboardWriter]::PublishPrepared($formats, $seq0, $guard)
                    return
                } catch {
                    if ($_.Exception.Message -match 'clipboard-changed') { throw }
                    if ($i -eq 9) { throw 'clipboard write failed after retries' }
                    Start-Sleep -Milliseconds 100
                }
            }
        } finally {
            if ($publication.Image) { $publication.Image.Dispose() }
            if ($publication.Stream) { $publication.Stream.Dispose() }
        }
    }

    function Get-FilePayload {
        param([string]$Path, $Limits)
        if ($Path -match '\.(png|jpe?g|gif|webp|bmp)$' -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [ClipwarpImages.ImageHelper]::FromFile($Path, $Limits)
        }
        return $null
    }

    $seq0 = [ClipwarpNative.Clip]::GetClipboardSequenceNumber()
    $out = [pscustomobject]@{ Path = $null; Kind = $null; Error = $null }
    $operation = [pscustomobject]@{ PublicationAttempted = $false }
    $ownedFiles = New-Object 'System.Collections.Generic.List[string]'
    $payload = $null; $path = $null
    try {
        $limits = New-ConversionLimits (Get-ClipwarpConfig)
        $data = Invoke-Retry { [System.Windows.Forms.Clipboard]::GetDataObject() }
        if (-not $data) { $out.Error = 'no-image'; return $out }
        # All formats come from one snapshot, without automatic DIB conversion.
        if ($data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop, $false)) {
            foreach ($file in $data.GetData([System.Windows.Forms.DataFormats]::FileDrop, $false)) {
                $payload = Get-FilePayload $file $limits
                if ($payload) { $path = $file; $out.Kind = 'file'; break }
            }
        }
        if (-not $payload) {
            foreach ($format in @('PNG', 'image/png')) {
                if ($data.GetDataPresent($format, $false)) {
                    $bytes = Read-StreamBytes ($data.GetData($format, $false)) $limits.MaxSourceBytes
                    $payload = New-PngStreamPayload $bytes $limits
                    $out.Kind = 'png-stream'; break
                }
            }
        }
        if (-not $payload) {
            foreach ($format in @('Format17', [System.Windows.Forms.DataFormats]::Dib)) {
                if ($data.GetDataPresent($format, $false)) {
                    $bytes = Read-StreamBytes ($data.GetData($format, $false)) $limits.MaxSourceBytes
                    $payload = [ClipwarpImages.ImageHelper]::FromDib($bytes, $limits)
                    $out.Kind = 'dibv5'; break
                }
            }
        }
        if (-not $payload -and $data.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap, $false)) {
            $image = $data.GetData([System.Windows.Forms.DataFormats]::Bitmap, $false)
            if ($image -is [System.Drawing.Image]) {
                try { $payload = [ClipwarpImages.ImageHelper]::FromImage($image, $limits) }
                finally { $image.Dispose() }
                $out.Kind = 'bitmap'
            }
        }
        if (-not $payload -and $data.GetDataPresent([System.Windows.Forms.DataFormats]::Html, $false)) {
            $html = [string]$data.GetData([System.Windows.Forms.DataFormats]::Html, $false)
            if ($html.Length -gt [math]::Ceiling($limits.MaxSourceBytes * 4.0 / 3.0) + 4096) { throw 'HTML image source exceeds resource limits' }
            $match = [regex]::Match($html, 'data:image/(png|jpe?g|gif|webp|bmp);base64,([A-Za-z0-9+/=\s]+)')
            if ($match.Success) {
                $base64 = $match.Groups[2].Value -replace '\s', ''
                if ($base64.Length -gt [math]::Ceiling($limits.MaxSourceBytes / 3.0) * 4) { throw 'Image source exceeds resource limits' }
                $bytes = [Convert]::FromBase64String($base64)
                if ($match.Groups[1].Value -eq 'png') { $payload = New-PngStreamPayload $bytes $limits }
                else { $payload = [ClipwarpImages.ImageHelper]::FromBytes($bytes, $limits) }
                $out.Kind = 'html-data'
            } else {
                $match = [regex]::Match($html, 'src\s*=\s*["''](file:///[^"''\s>]+)')
                if ($match.Success) {
                    $uri = [Uri]$match.Groups[1].Value
                    if ($uri.IsFile -and -not $uri.IsUnc) {
                        $path = $uri.LocalPath
                        $payload = Get-FilePayload $path $limits
                        if ($payload) { $out.Kind = 'file' } else { $path = $null }
                    }
                }
            }
        }
        if (-not $payload -and $data.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText, $false)) {
            $text = [string]$data.GetData([System.Windows.Forms.DataFormats]::UnicodeText, $false)
            if ($text.Length -le 32767) {
                $path = $text.Trim().Trim('"').Trim("'")
                $payload = Get-FilePayload $path $limits
                if ($payload) { $out.Kind = 'file' } else { $path = $null }
            }
        }
        if (-not $payload) { $out.Error = 'no-image'; return $out }
        if (-not $path -or $path -match '\.bmp$') {
            if ($path) { $out.Kind = 'file-bmp' }
            $path = Save-OwnedPng $payload $OutDir $ownedFiles
        }
        Publish-Result -Path $path -Payload $payload -Operation $operation
        $out.Path = $path
        return $out
    } finally {
        if ($payload) { $payload.Dispose() }
        Remove-AbortedFiles $ownedFiles $operation.PublicationAttempted
    }
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.ThreadOptions = 'ReuseThread'
$rs.Open()
$ps = [powershell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript($work).AddArgument($OutDir).AddArgument([bool]$KeepImage).AddArgument([string]$resolvedMode).AddArgument($PSScriptRoot).AddArgument($TargetMode).AddArgument([bool]$ImageOnly)
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

# Opt-in cleanup runs after successful conversion and preserves its active file.
try {
    Invoke-ClipwarpRetention -OutDir $OutDir -ExcludePath $r.Path -Confirm:$false | Out-Null
} catch { if (-not $Quiet) { Write-Warning "clipwarp cleanup failed: $_" } }

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
        Write-Host 'image copied to clipboard (paste as image). Switch to your app and press Ctrl+V.' -ForegroundColor Cyan
    } else {
        Write-Host 'file path copied to clipboard (file picker / terminal target). Switch and press Ctrl+V.' -ForegroundColor Cyan
    }
}

# Show the same short-lived, non-blocking calendar prompt in manual and watcher
# conversions. It never reads or writes the clipboard.
try {
    Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
    if ((Get-ClipwarpPaused) -or -not (Get-ClipwarpCalendarEnabled)) { throw 'calendar-disabled' }
    Import-Module (Join-Path $PSScriptRoot 'clipwarp-calendar.psm1') -Force
    $imageTitle = 'Clipboard image ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Start-ClipwarpCalendarPopup -Kind Image -Title $imageTitle -ImagePath $r.Path -PointerX $PointerX -PointerY $PointerY -ScriptRoot $PSScriptRoot
} catch {
    if ($_.Exception.Message -ne 'calendar-disabled' -and -not $Quiet) { Write-Host "clipwarp: calendar popup could not be shown - $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Always emit the raw path last so it is usable in a pipeline too.
$r.Path
exit 0
