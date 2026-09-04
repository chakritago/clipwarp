[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
    [string]$Title,
    [string]$TitleBase64,
    [string]$TitleFileBase64,
    [string]$TitleFile,
    [string]$ImagePath,
    [string]$ImagePathBase64,
    [Nullable[int]]$PointerX,
    [Nullable[int]]$PointerY,
    [int]$TimeoutSeconds = 12
)

if ($TitleFileBase64) { $TitleFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleFileBase64)) }
if ($TitleFile) {
    try { $Title = [IO.File]::ReadAllText($TitleFile, [Text.Encoding]::UTF8) }
    finally { Remove-Item -LiteralPath $TitleFile -Force -ErrorAction SilentlyContinue }
} elseif ($TitleBase64) { $Title = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleBase64)) }
if ($ImagePathBase64) { $ImagePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ImagePathBase64)) }
if ([string]::IsNullOrWhiteSpace($Title)) { exit 1 }

Import-Module (Join-Path $PSScriptRoot 'clipwarp-calendar.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force
$popupMutex = New-Object Threading.Mutex($false, 'Local\clipwarp-calendar-popup')
$ownsPopupMutex = $false
try { $ownsPopupMutex = $popupMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsPopupMutex = $true }
if (-not $ownsPopupMutex) { $popupMutex.Dispose(); exit 0 }
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
[ClipwarpPopupNative]::EnableDpiAwareness()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$duration = Get-ClipwarpCalendarDefaultDuration
$event = if ($Kind -eq 'Text') { ConvertFrom-ClipwarpCalendarText -Text $Title -LocalDate (Get-Date) -DefaultDurationMinutes $duration } else { [pscustomobject]@{ Title=$Title; IsTimed=$false; LocalDate=(Get-Date).Date } }
$calendarTitle = $event.Title
$details = if ($Kind -eq 'Image') {
    Get-ClipwarpImageCalendarDetails -ImagePath $ImagePath -Mode (Get-ClipwarpCalendarImageDetails)
} elseif ($Title.Length -gt 120 -or $Title -match "`r|`n") {
    $calendarTitle = (Format-ClipwarpCalendarPayload -Title $event.Title).Title
    $Title
} else { $null }
$zone = Get-ClipwarpCalendarTimeZone
$url = if ($event.IsTimed) { New-ClipwarpCalendarUrl -Title $calendarTitle -Start $event.Start -End $event.End -Details $details -TimeZone $zone } else { New-ClipwarpCalendarUrl -Title $calendarTitle -LocalDate $event.LocalDate -Details $details }
$preview = Get-ClipwarpCalendarPreview -Event $event
$calendarUri = $null
if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$calendarUri) -or
    $calendarUri.Scheme -ne 'https' -or $calendarUri.Host -ne 'calendar.google.com') { exit 1 }

$pointer = if ($null -ne $PointerX -and $null -ne $PointerY) {
    New-Object Drawing.Point ([int]$PointerX), ([int]$PointerY)
} else { [Windows.Forms.Cursor]::Position }
$area = [Windows.Forms.Screen]::FromPoint($pointer).WorkingArea
$metrics = Get-ClipwarpPopupMetrics -Dpi ([ClipwarpPopupNative]::GetDpi($pointer.X, $pointer.Y))
$contentWidth = $metrics.Width - (2 * $metrics.Padding)
$location = Get-ClipwarpPopupLocation -PointerX $pointer.X -PointerY $pointer.Y -PopupWidth $metrics.Width -PopupHeight $metrics.Height -WorkingLeft $area.Left -WorkingTop $area.Top -WorkingRight $area.Right -WorkingBottom $area.Bottom -Gap $metrics.Gap

$form = New-Object Windows.Forms.Form
$form.Text = 'Send to Google Calendar'
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
$form.AccessibleName = 'Send clipboard data to Google Calendar'

$accent = New-Object Windows.Forms.Panel
$accent.Location = New-Object Drawing.Point 0, 0
$accent.Size = New-Object Drawing.Size $metrics.Width, ([Math]::Max(3, [int][Math]::Round($metrics.Gap / 3.0)))
$accent.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
$accent.TabStop = $false
$form.Controls.Add($accent)

$heading = New-Object Windows.Forms.Label
$heading.AutoSize = $false
$heading.Location = New-Object Drawing.Point $metrics.Padding, $metrics.HeadingTop
$heading.Size = New-Object Drawing.Size ($contentWidth - $metrics.CloseSize), $metrics.HeadingHeight
$heading.Font = New-Object Drawing.Font 'Segoe UI Semibold', 12
$heading.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
$heading.Text = 'Add to Google Calendar'
$heading.AccessibleName = $heading.Text
$form.Controls.Add($heading)

$close = New-Object Windows.Forms.Button
$close.Location = New-Object Drawing.Point ($metrics.Width - $metrics.Padding - $metrics.CloseSize), ([Math]::Max(4, $metrics.HeadingTop - 4))
$close.Size = New-Object Drawing.Size $metrics.CloseSize, $metrics.CloseSize
$close.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$close.FlatAppearance.BorderSize = 0
$close.BackColor = $form.BackColor
$close.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
$close.Font = New-Object Drawing.Font 'Segoe UI', 11
$close.Text = [char]0x00D7
$close.TabIndex = 1
$close.AccessibleName = 'Close calendar prompt'
$close.Add_Click({ $form.Close() })
$form.Controls.Add($close)

$message = New-Object Windows.Forms.Label
$message.AutoSize = $false
$message.Location = New-Object Drawing.Point $metrics.Padding, $metrics.MessageTop
$message.Size = New-Object Drawing.Size $contentWidth, $metrics.MessageHeight
$message.ForeColor = [Drawing.Color]::FromArgb(71, 85, 105)
$message.Text = $preview
$message.AccessibleName = $message.Text
$form.Controls.Add($message)

$button = New-Object Windows.Forms.Button
$button.Location = New-Object Drawing.Point $metrics.Padding, $metrics.ButtonTop
$button.Size = New-Object Drawing.Size $contentWidth, $metrics.ButtonHeight
$button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$button.FlatAppearance.BorderSize = 0
$button.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
$button.ForeColor = [Drawing.Color]::White
$button.Font = New-Object Drawing.Font 'Segoe UI Semibold', 9
$button.Cursor = [Windows.Forms.Cursors]::Hand
$button.Text = if ($Kind -eq 'Image') { 'Create event and select image' } elseif ($event.IsTimed) { 'Create timed event' } else { 'Create all-day event' }
$button.AccessibleName = $button.Text
$button.TabIndex = 0
$form.AcceptButton = $button
$form.Controls.Add($button)

$button.Add_Click({
    $browser = New-Object Diagnostics.ProcessStartInfo
    $browser.FileName = $calendarUri.AbsoluteUri
    $browser.UseShellExecute = $true
    [Diagnostics.Process]::Start($browser) | Out-Null
    if ($Kind -eq 'Image' -and $ImagePath -and (Test-Path -LiteralPath $ImagePath)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $ImagePath + '"')
    }
    $form.Close()
})
$form.Add_KeyDown({ if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) { $form.Close() } })
$form.Add_Paint({
    param($sender, $e)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(203, 213, 225)), 1
    try { $e.Graphics.DrawRectangle($pen, 0, 0, ($form.ClientSize.Width - 1), ($form.ClientSize.Height - 1)) }
    finally { $pen.Dispose() }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = [Math]::Max(1, $TimeoutSeconds) * 1000
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
$form.Add_Shown({
    $button.Focus()
    $timer.Start()
})
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
try { $popupMutex.ReleaseMutex() } finally { $popupMutex.Dispose() }
