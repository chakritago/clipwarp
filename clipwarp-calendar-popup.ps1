[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Text', 'Image')][string]$Kind,
    [string]$Title,
    [string]$TitleBase64,
    [string]$ImagePath,
    [int]$TimeoutSeconds = 12
)

if ($TitleBase64) { $Title = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleBase64)) }
if ([string]::IsNullOrWhiteSpace($Title)) { exit 1 }

Import-Module (Join-Path $PSScriptRoot 'clipwarp-calendar.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$url = New-ClipwarpCalendarUrl -Title $Title -LocalDate (Get-Date)
$form = New-Object Windows.Forms.Form
$form.Text = 'Send to Google Calendar'
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedToolWindow
$form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.ClientSize = New-Object Drawing.Size 360, 96
$form.KeyPreview = $true
$form.AccessibleName = 'Send clipboard data to Google Calendar'

$message = New-Object Windows.Forms.Label
$message.AutoSize = $false
$message.Location = New-Object Drawing.Point 12, 10
$message.Size = New-Object Drawing.Size 336, 38
$message.Text = if ($Kind -eq 'Image') { 'Create today''s event, then attach the selected image file manually.' } else { 'Create an all-day event today using the copied text as its title.' }
$form.Controls.Add($message)

$button = New-Object Windows.Forms.Button
$button.Location = New-Object Drawing.Point 12, 52
$button.Size = New-Object Drawing.Size 336, 32
$button.Text = if ($Kind -eq 'Image') { 'Create event + select image (Enter)' } else { 'Create Google Calendar event (Enter)' }
$button.AccessibleName = $button.Text
$form.AcceptButton = $button
$form.Controls.Add($button)

$button.Add_Click({
    Start-Process $url
    if ($Kind -eq 'Image' -and $ImagePath -and (Test-Path -LiteralPath $ImagePath)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $ImagePath + '"')
    }
    $form.Close()
})
$form.Add_KeyDown({ if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) { $form.Close() } })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = [Math]::Max(1, $TimeoutSeconds) * 1000
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
$form.Add_Shown({
    $area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $x = [Math]::Min([Windows.Forms.Cursor]::Position.X + 16, $area.Right - $form.Width)
    $y = [Math]::Min([Windows.Forms.Cursor]::Position.Y + 20, $area.Bottom - $form.Height)
    $form.Location = New-Object Drawing.Point ([Math]::Max($area.Left, $x)), ([Math]::Max($area.Top, $y))
    $button.Focus()
    $timer.Start()
})
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
