[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(ParameterSetName = 'Direct', Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
    [Parameter(ParameterSetName = 'Direct')][string]$Title,
    [Parameter(ParameterSetName = 'Direct')][string]$TitleBase64,
    [Parameter(ParameterSetName = 'Direct')][string]$TitleFileBase64,
    [Parameter(ParameterSetName = 'Direct')][string]$TitleFile,
    [Parameter(ParameterSetName = 'Direct')][string]$ImagePath,
    [Parameter(ParameterSetName = 'Direct')][string]$ImagePathBase64,
    [Parameter(ParameterSetName = 'Direct')][Nullable[int]]$PointerX,
    [Parameter(ParameterSetName = 'Direct')][Nullable[int]]$PointerY,
    [Parameter(ParameterSetName = 'Direct')][ValidateRange(1,300)][int]$TimeoutSeconds = 3,
    [Parameter(ParameterSetName = 'Direct')][uint32]$ExpectedSequence = 0,
    [Parameter(ParameterSetName = 'HostMode', Mandatory = $true)][switch]$HostMode
)

Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'clipwarp-calendar.psm1') -Force

if (-not ('ClipwarpPopupNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipwarpPopupNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
    public static void EnableDpiAwareness() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }
    public static int GetDpi(int x, int y) {
        try {
            uint dx, dy;
            IntPtr monitor = MonitorFromPoint(new POINT { X = x, Y = y }, 2);
            if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out dx, out dy) == 0 && dx >= 48 && dx <= 768) return (int)dx;
        } catch { }
        return 96;
    }
}
'@
}
[ClipwarpPopupNative]::EnableDpiAwareness()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('ClipwarpPassiveForm' -as [type])) {
    $passiveReferences = @([Windows.Forms.Form].Assembly.Location)
    if ($PSVersionTable.PSEdition -eq 'Core') { $passiveReferences += @('System.Runtime','System.ComponentModel.Primitives') }
    Add-Type -TypeDefinition @'
public class ClipwarpPassiveForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
        get { var value = base.CreateParams; value.ExStyle |= 0x00000080; return value; }
    }
}
'@ -ReferencedAssemblies $passiveReferences
}

if (-not ('ClipwarpPopupHost.PopupRequest' -as [type])) {
    $hostHelperPath = Join-Path $PSScriptRoot 'clipwarp-popup-host.cs'
    if (Test-Path -LiteralPath $hostHelperPath) {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($hostHelperPath))
    }
}

function Show-ClipwarpSinglePopup {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
        [string]$Title,
        [string]$ImagePath,
        [Nullable[int]]$PointerX,
        [Nullable[int]]$PointerY,
        [int]$TimeoutSeconds = 3,
        [uint32]$ExpectedSequence = 0,
        [switch]$FromHost
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return }

    $popupMutex = New-Object Threading.Mutex($false, 'Local\clipwarp-calendar-popup')
    $ownsPopupMutex = $false
    try { $ownsPopupMutex = $popupMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsPopupMutex = $true }
    if (-not $ownsPopupMutex) { $popupMutex.Dispose(); return }

    try {
        $config = Get-ClipwarpConfigStatus
        if ($config.Paused) { return }
        $calendarEnabled = $config.CalendarEnabled
        $chatGptEnabled = $config.ChatGptEnabled
        $runCommandEnabled = $config.RunCommandEnabled
        if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $config.PopupDurationSeconds }
        if (-not $calendarEnabled -and ($Kind -eq 'Image' -or (-not $chatGptEnabled -and -not $runCommandEnabled))) { return }
        $duration = Get-ClipwarpCalendarDefaultDuration
        $event = if ($Kind -eq 'Text') { ConvertFrom-ClipwarpCalendarText -Text $Title -LocalDate (Get-Date) -DefaultDurationMinutes $duration } else { [pscustomobject]@{ Title=$Title; IsTimed=$false; LocalDate=(Get-Date).Date.AddDays(1); Location=$null } }
        $calendarTitle = $event.Title
        $details = if ($Kind -eq 'Image') {
            Get-ClipwarpImageCalendarDetails -ImagePath $ImagePath -Mode (Get-ClipwarpCalendarImageDetails)
        } elseif ($Title.Length -gt 120 -or $Title -match "`r|`n") {
            $calendarTitle = (Format-ClipwarpCalendarPayload -Title $event.Title).Title
            $Title
        } else { $null }
        $zone = Get-ClipwarpCalendarTimeZone
        $calendarWarnings = @()
        $url = if ($event.IsTimed) { New-ClipwarpCalendarUrl -Title $calendarTitle -Start $event.Start -End $event.End -Details $details -TimeZone $zone -Location $event.Location -WarningVariable +calendarWarnings } else { New-ClipwarpCalendarUrl -Title $calendarTitle -LocalDate $event.LocalDate -Details $details -Location $event.Location -WarningVariable +calendarWarnings }
        $isCommand = if ($Kind -eq 'Text') { Test-ClipwarpCommandLine -Text $Title } else { $false }
        $commandText = if ($Kind -eq 'Text') { Get-ClipwarpCommandText -Text $Title } else { $null }
        $preview = if ($isCommand) {
            $firstLine = ($commandText -split "`r?`n")[0].Trim()
            if ($firstLine.Length -gt 55) { $firstLine = $firstLine.Substring(0, 52) + '...' }
            if (($commandText -split "`r?`n").Count -gt 1) { $firstLine += ' [...]' }
            "> $firstLine"
        } else {
            Get-ClipwarpCalendarPreview -Event $event
        }
        $calendarUri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$calendarUri) -or
            $calendarUri.Scheme -ne 'https' -or $calendarUri.Host -ne 'calendar.google.com') { return }

        $pointer = if ($null -ne $PointerX -and $null -ne $PointerY) {
            New-Object Drawing.Point ([int]$PointerX), ([int]$PointerY)
        } else { [Windows.Forms.Cursor]::Position }
        $area = [Windows.Forms.Screen]::FromPoint($pointer).WorkingArea
        $metrics = Get-ClipwarpPopupMetrics -Dpi ([ClipwarpPopupNative]::GetDpi($pointer.X, $pointer.Y))
        $contentWidth = $metrics.Width - (2 * $metrics.Padding)
        if ($Kind -eq 'Text') {
            $metrics.Height += [int][Math]::Round(70 * ($metrics.Width / 400.0))
        }
        $location = Get-ClipwarpPopupLocation -PointerX $pointer.X -PointerY $pointer.Y -PopupWidth $metrics.Width -PopupHeight $metrics.Height -WorkingLeft $area.Left -WorkingTop $area.Top -WorkingRight $area.Right -WorkingBottom $area.Bottom -Gap $metrics.Gap

        $form = New-Object ClipwarpPassiveForm
        $form.Text = if ($isCommand) { 'Run in PowerShell' } else { 'Send to Google Calendar' }
        $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ShowIcon = $false
        $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
        $form.ClientSize = New-Object Drawing.Size $metrics.Width, $metrics.Height
        $form.Location = New-Object Drawing.Point $location.X, $location.Y
        $form.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)
        $form.Font = New-Object Drawing.Font 'Segoe UI', 9
        $form.KeyPreview = $true
        $form.AccessibleName = if ($isCommand) { 'Run command in PowerShell' } else { 'Send clipboard data to Google Calendar' }

        $accent = New-Object Windows.Forms.Panel
        $accent.Location = New-Object Drawing.Point 0, 0
        $accent.Size = New-Object Drawing.Size $metrics.Width, ([Math]::Max(3, [int][Math]::Round($metrics.Gap / 3.0)))
        $accent.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
        $accent.TabStop = $false
        $form.Controls.Add($accent)

        $localRemainingSeconds = [Math]::Max(1, $TimeoutSeconds)
        $scale = $metrics.Width / 400.0
        $countdownWidth = [int][Math]::Round(36 * $scale)
        $countdownLeft = $metrics.Width - $metrics.Padding - $metrics.CloseSize - $countdownWidth - [int][Math]::Round(4 * $scale)

        $heading = New-Object Windows.Forms.Label
        $heading.AutoSize = $false
        $heading.Location = New-Object Drawing.Point $metrics.Padding, $metrics.HeadingTop
        $heading.Size = New-Object Drawing.Size ($countdownLeft - $metrics.Padding - [int][Math]::Round(4 * $scale)), $metrics.HeadingHeight
        $heading.Font = New-Object Drawing.Font 'Segoe UI Semibold', 12
        $heading.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $heading.Text = if ($isCommand) { 'Run in PowerShell' } else { 'Add to Google Calendar' }
        $heading.AccessibleName = $heading.Text
        $form.Controls.Add($heading)

        $countdown = New-Object Windows.Forms.Label
        $countdown.AutoSize = $false
        $countdown.Location = New-Object Drawing.Point $countdownLeft, $metrics.HeadingTop
        $countdown.Size = New-Object Drawing.Size $countdownWidth, $metrics.HeadingHeight
        $countdown.Font = New-Object Drawing.Font 'Segoe UI', 9
        $countdown.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
        $countdown.TextAlign = [Drawing.ContentAlignment]::MiddleRight
        $countdown.Text = "${localRemainingSeconds}s"
        $countdown.AccessibleName = "Auto close in ${localRemainingSeconds} seconds"
        $form.Controls.Add($countdown)

        $close = New-Object Windows.Forms.Button
        $close.Location = New-Object Drawing.Point ($metrics.Width - $metrics.Padding - $metrics.CloseSize), ([Math]::Max(4, $metrics.HeadingTop - 4))
        $close.Size = New-Object Drawing.Size $metrics.CloseSize, $metrics.CloseSize
        $close.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $close.FlatAppearance.BorderSize = 0
        $close.BackColor = $form.BackColor
        $close.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
        $close.Font = New-Object Drawing.Font 'Segoe UI', 11
        $close.Text = [char]0x00D7
        $close.TabIndex = 2
        $close.AccessibleName = 'Close prompt'
        $close.Add_Click({ $form.Close() })
        $form.Controls.Add($close)

        $message = New-Object Windows.Forms.Label
        $message.AutoSize = $false
        $message.Location = New-Object Drawing.Point $metrics.Padding, $metrics.MessageTop
        $message.Size = New-Object Drawing.Size $contentWidth, $metrics.MessageHeight
        $message.ForeColor = [Drawing.Color]::FromArgb(71, 85, 105)
        if ($isCommand) { $message.Font = New-Object Drawing.Font 'Consolas', 9 }
        $message.Text = $preview
        $message.AccessibleName = $message.Text
        $form.Controls.Add($message)

        if ($Kind -eq 'Text') {
            $btnGap = [int][Math]::Round(8 * $scale)
            $runBtnWidth = [int][Math]::Floor(($contentWidth - $btnGap) / 2.0)
            $calBtnWidth = $contentWidth - $runBtnWidth - $btnGap

            $runButton = New-Object Windows.Forms.Button
            $runButton.Location = New-Object Drawing.Point $metrics.Padding, $metrics.ButtonTop
            $runButton.Size = New-Object Drawing.Size $runBtnWidth, $metrics.ButtonHeight
            $runButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
            $runButton.Cursor = [Windows.Forms.Cursors]::Hand
            $runButton.Text = 'Run with PowerShell'
            $runButton.AccessibleName = 'Run with PowerShell'

            $calButton = New-Object Windows.Forms.Button
            $calButton.Location = New-Object Drawing.Point ($metrics.Padding + $runBtnWidth + $btnGap), $metrics.ButtonTop
            $calButton.Size = New-Object Drawing.Size $calBtnWidth, $metrics.ButtonHeight
            $calButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
            $calButton.Cursor = [Windows.Forms.Cursors]::Hand
            $baseCalText = if ($event.IsTimed) { 'Create timed event' } else { 'Add to Calendar' }
            $calButton.Text = $baseCalText
            $calButton.AccessibleName = $baseCalText

            if ($isCommand) {
                $runButton.FlatAppearance.BorderSize = 0
                $runButton.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
                $runButton.ForeColor = [Drawing.Color]::White
                $runButton.Font = New-Object Drawing.Font 'Segoe UI Semibold', 9
                $runButton.TabIndex = 0

                $calButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203, 213, 225)
                $calButton.FlatAppearance.BorderSize = 1
                $calButton.BackColor = [Drawing.Color]::FromArgb(241, 245, 249)
                $calButton.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
                $calButton.Font = New-Object Drawing.Font 'Segoe UI', 9
                $calButton.TabIndex = 1
            } else {
                $calButton.FlatAppearance.BorderSize = 0
                $calButton.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
                $calButton.ForeColor = [Drawing.Color]::White
                $calButton.Font = New-Object Drawing.Font 'Segoe UI Semibold', 9
                $calButton.TabIndex = 0
                $form.AcceptButton = $calButton

                $runButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203, 213, 225)
                $runButton.FlatAppearance.BorderSize = 1
                $runButton.BackColor = [Drawing.Color]::FromArgb(241, 245, 249)
                $runButton.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
                $runButton.Font = New-Object Drawing.Font 'Segoe UI', 9
                $runButton.TabIndex = 1
            }

            $form.Controls.Add($runButton)
            $form.Controls.Add($calButton)

            $chatGptButton = New-Object Windows.Forms.Button
            $chatGptButton.Location = New-Object Drawing.Point $metrics.Padding, ($metrics.ButtonTop + $metrics.ButtonHeight + $btnGap)
            $chatGptButton.Size = New-Object Drawing.Size $contentWidth, $metrics.ButtonHeight
            $chatGptButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
            $chatGptButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203, 213, 225)
            $chatGptButton.BackColor = [Drawing.Color]::FromArgb(241, 245, 249)
            $chatGptButton.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
            $chatGptButton.Cursor = [Windows.Forms.Cursors]::Hand
            $chatGptButton.Text = 'Open ChatGPT (paste && send yourself)'
            $chatGptButton.AccessibleName = 'Open temporary ChatGPT; paste and send manually'
            $chatGptButton.AccessibleDescription = 'Copies only if the clipboard still matches this snapshot, then opens a temporary chat. Paste and send yourself.'
            $chatGptButton.TabIndex = 2
            $close.TabIndex = 3
            $form.Controls.Add($chatGptButton)

            $handoffHint = New-Object Windows.Forms.Label
            $handoffHint.Location = New-Object Drawing.Point $metrics.Padding, ($chatGptButton.Bottom + [int][Math]::Round(4 * $scale))
            $handoffHint.Size = New-Object Drawing.Size $contentWidth, ([int][Math]::Round(20 * $scale))
            $handoffHint.Text = 'Manual handoff. Nothing is sent automatically.'
            $handoffHint.AccessibleName = $handoffHint.Text
            $form.Controls.Add($handoffHint)

            $chatGptButton.Add_Click({
                try { if ($null -ne $timer) { $timer.Stop() } } catch { }
                if ($form.PSObject.Methods['Hide']) { $form.Hide() }
                try {
                    $result = Start-ClipwarpChatGptHandoff -Message $Title -ExpectedSequence $ExpectedSequence
                    $statusText = if ($result.Status -eq 'manual-required') { 'Copied and opened temporary ChatGPT. Paste and send yourself. Nothing was sent.' } elseif ($result.Status -eq 'cancelled') { 'Cancelled: the clipboard changed or its snapshot could not be verified. Copy again and retry.' } else { 'Handoff failed. Copied: ' + $result.Copied + '; opened: ' + $result.Opened + '. Nothing was sent.' }
                    [void][Windows.Forms.MessageBox]::Show($statusText, 'Clipwarp - ChatGPT')
                    $form.Close()
                } catch {
                    [void][Windows.Forms.MessageBox]::Show('ChatGPT manual handoff failed. Nothing was sent.', 'Clipwarp - ChatGPT', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
                    $form.Close()
                }
            })

            $runButton.Visible = $runCommandEnabled
            $calButton.Visible = $calendarEnabled
            $chatGptButton.Visible = $chatGptEnabled
            $handoffHint.Visible = $chatGptEnabled
            $calButton.Enabled = -not $event.NeedsReview
            if ($event.NeedsReview) { $calButton.Text = 'Date needs review' }
            $runButton.Text = 'Review PowerShell script...'
            $runButton.AccessibleName = 'Review full script before running'
            $runButton.Add_Click({
                $timer.Stop()
                try {
                    if (Confirm-ClipwarpCommand -CommandText $commandText -WorkingDirectory $env:USERPROFILE -Owner $form) {
                        Start-ClipwarpCommand -CommandText $commandText -ReviewedSnapshot -WorkingDirectory $env:USERPROFILE
                        $form.Close()
                    }
                } catch { [void][Windows.Forms.MessageBox]::Show('Command could not be launched.', 'Clipwarp') }
                finally { if (-not $form.IsDisposed) { $timer.Start() } }
            })

            $calButton.Add_Click({
                if ($calendarWarnings.Count) { [void][Windows.Forms.MessageBox]::Show(($calendarWarnings -join "`r`n"), 'Calendar URL fields omitted') }
                $browser = New-Object Diagnostics.ProcessStartInfo
                $browser.FileName = $calendarUri.AbsoluteUri
                $browser.UseShellExecute = $true
                [Diagnostics.Process]::Start($browser) | Out-Null
                $form.Close()
            })
        } else {
            $button = New-Object Windows.Forms.Button
            $button.Location = New-Object Drawing.Point $metrics.Padding, $metrics.ButtonTop
            $button.Size = New-Object Drawing.Size $contentWidth, $metrics.ButtonHeight
            $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
            $button.FlatAppearance.BorderSize = 0
            $button.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
            $button.ForeColor = [Drawing.Color]::White
            $button.Font = New-Object Drawing.Font 'Segoe UI Semibold', 9
            $button.Cursor = [Windows.Forms.Cursors]::Hand
            $button.Text = 'Create event and select image'
            $button.AccessibleName = $button.Text
            $button.TabIndex = 0
            $form.AcceptButton = $button
            $form.Controls.Add($button)

            $button.Add_Click({
                $browser = New-Object Diagnostics.ProcessStartInfo
                $browser.FileName = $calendarUri.AbsoluteUri
                $browser.UseShellExecute = $true
                [Diagnostics.Process]::Start($browser) | Out-Null
                if ($ImagePath -and (Test-Path -LiteralPath $ImagePath)) {
                    Start-Process explorer.exe -ArgumentList ('/select,"' + $ImagePath + '"')
                }
                $form.Close()
            })
        }

        $form.Add_KeyDown({
            if ($Kind -eq 'Text' -and $_.KeyCode -eq [Windows.Forms.Keys]::Enter -and $isCommand -and -not $runButton.Focused) {
                $_.Handled = $true
                $_.SuppressKeyPress = $true
            }
        })
        $form.Add_KeyDown({ if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) { $form.Close() } })
        $form.Add_Paint({
            param($sender, $e)
            $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(203, 213, 225)), 1
            try { $e.Graphics.DrawRectangle($pen, 0, 0, ($form.ClientSize.Width - 1), ($form.ClientSize.Height - 1)) }
            finally { $pen.Dispose() }
        })

        $timer = New-Object Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            $hovering = $form.Bounds.Contains([Windows.Forms.Cursor]::Position)
            if ($hovering -or $form.ContainsFocus) { return }
            $localRemainingSeconds--
            if ($localRemainingSeconds -le 0) {
                $timer.Stop()
                $form.Close()
            } else {
                $countdown.Text = "${localRemainingSeconds}s"
            }
        })
        $form.Add_Shown({ $timer.Start() })

        if ($FromHost) {
            [void]$form.ShowDialog()
        } else {
            [Windows.Forms.Application]::Run($form)
        }

        $timer.Dispose()
        $form.Dispose()
    } finally {
        try { $popupMutex.ReleaseMutex() } finally { $popupMutex.Dispose() }
    }
}

if ($HostMode) {
    $mailbox = New-Object ClipwarpPopupHost.PopupMailbox
    $pipeStream = [Console]::OpenStandardInput()
    $readerThread = New-Object Threading.Thread([Threading.ThreadStart]{
        try {
            while ($true) {
                $req = [ClipwarpPopupHost.PopupRequest]::Deserialize($pipeStream)
                if ($null -eq $req) { break }
                $mailbox.Post($req)
            }
        } catch { }
    })
    $readerThread.IsBackground = $true
    $readerThread.Start()

    $context = New-Object Windows.Forms.ApplicationContext
    $drainTimer = New-Object Windows.Forms.Timer
    $drainTimer.Interval = 40
    $drainTimer.Add_Tick({
        if (-not $readerThread.IsAlive -and $null -eq $mailbox.PeekLatest()) {
            $drainTimer.Stop()
            $context.ExitThread()
            return
        }
        $nextReq = $mailbox.TakeLatest()
        if ($null -ne $nextReq) {
            $px = if ($nextReq.HasPointer) { $nextReq.PointerX } else { $null }
            $py = if ($nextReq.HasPointer) { $nextReq.PointerY } else { $null }
            Show-ClipwarpSinglePopup -Kind 'Text' -Title $nextReq.Text -PointerX $px -PointerY $py -ExpectedSequence $nextReq.ExpectedSequence -FromHost
        }
    })
    $drainTimer.Start()
    [Windows.Forms.Application]::Run($context)
    $drainTimer.Dispose()
    exit 0
}

if ($TitleFileBase64) { $TitleFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleFileBase64)) }
if ($TitleFile) {
    $Title = Read-ClipwarpOwnedTitleFile -Path $TitleFile
} elseif ($TitleBase64) { $Title = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleBase64)) }
if ($ImagePathBase64) { $ImagePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ImagePathBase64)) }
if ([string]::IsNullOrWhiteSpace($Title)) { exit 1 }

Show-ClipwarpSinglePopup -Kind $Kind -Title $Title -ImagePath $ImagePath -PointerX $PointerX -PointerY $PointerY -TimeoutSeconds $TimeoutSeconds -ExpectedSequence $ExpectedSequence
