# Windows-only settings UI for ClipWarp's original RightLang-inspired feature.
[CmdletBinding()]
param()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'clipwarp-rightlang.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force

$cfg = Get-ClipwarpRightLangConfig
$form = New-Object Windows.Forms.Form
$form.Text = 'ClipWarp  |  Language correction'
$form.Size = New-Object Drawing.Size(780, 650)
$form.MinimumSize = New-Object Drawing.Size(700, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(248,249,251)

function New-Label($text, $left, $top, $width, $height, $size, $bold) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $text; $label.Location = New-Object Drawing.Point($left,$top)
    $label.Size = New-Object Drawing.Size($width,$height)
    $label.ForeColor = [Drawing.Color]::FromArgb(38,44,55)
    $style = if($bold){ [Drawing.FontStyle]::Bold }else{ [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font('Segoe UI',$size,$style)
    $label
}
function New-TextEditor($parent, $text, $left, $top, $width, $height) {
    $editor = New-Object Windows.Forms.TextBox
    $editor.Multiline = $true; $editor.ScrollBars = 'Vertical'
    $editor.AcceptsReturn = $true
    $editor.Text = $text
    $editor.Location = New-Object Drawing.Point($left,$top)
    $editor.Size = New-Object Drawing.Size($width,$height)
    $editor.Anchor = 'Top,Bottom,Left,Right'
    $parent.Controls.Add($editor)
    $editor
}
$form.Controls.Add((New-Label 'Language correction' 22 18 700 37 19 $true))
$form.Controls.Add((New-Label 'Fix text typed using the wrong Thai / English keyboard layout.' 23 57 720 25 10 $false))
$form.Controls.Add((New-Label 'Correction mode' 23 99 170 25 11 $true))
$modePicker = New-Object Windows.Forms.ComboBox
$modePicker.DropDownStyle = 'DropDownList'
[void]$modePicker.Items.Add('Manual — shortcut only')
[void]$modePicker.Items.Add('Automatic — known words only')
[void]$modePicker.Items.Add('Off — no correction')
$modePicker.SelectedIndex = switch($cfg.mode){'auto'{1};'off'{2};default{0}}
$modePicker.Location = New-Object Drawing.Point(23,128)
$modePicker.Size = New-Object Drawing.Size(350,32)
$form.Controls.Add($modePicker)
$form.Controls.Add((New-Label 'Shortcut: Shift + Backspace or Ctrl + Alt + R (last typed word).' 392 128 360 46 9 $false))
$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(23,185)
$tabs.Size = New-Object Drawing.Size(715,350)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabs)

$instantTab = New-Object Windows.Forms.TabPage('Instant corrections')
[void]$tabs.TabPages.Add($instantTab)
$instantTab.Controls.Add((New-Label 'One rule per line: typed text = corrected text' 15 15 660 24 10 $true))
$instantTab.Controls.Add((New-Label 'Applied automatically at word boundaries in Automatic mode.' 15 40 650 22 9 $false))
$instantText = ($cfg.instant.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join [Environment]::NewLine
$instantBox = New-TextEditor $instantTab $instantText 15 70 675 240

$wordsTab = New-Object Windows.Forms.TabPage('Custom words')
[void]$tabs.TabPages.Add($wordsTab)
$wordsTab.Controls.Add((New-Label 'Known correct words: one Thai or English word per line.' 15 15 670 24 10 $true))
$wordsTab.Controls.Add((New-Label 'Only words in this list (or an instant rule) qualify for automatic layout correction.' 15 40 680 25 9 $false))
$wordsBox = New-TextEditor $wordsTab ($cfg.words -join [Environment]::NewLine) 15 70 675 240

$appsTab = New-Object Windows.Forms.TabPage('App compatibility')
[void]$tabs.TabPages.Add($appsTab)
$appsTab.Controls.Add((New-Label 'Allowed applications (executable names)' 15 12 650 23 10 $true))
$appsTab.Controls.Add((New-Label 'Nothing is monitored outside this list. Do not include apps used for passwords.' 15 35 680 23 9 $false))
$allowBox = New-TextEditor $appsTab ($cfg.allowedApps -join [Environment]::NewLine) 15 64 675 97
$appsTab.Controls.Add((New-Label 'Blocked applications (always ignored)' 15 180 660 23 10 $true))
$blockBox = New-TextEditor $appsTab ($cfg.blockedApps -join [Environment]::NewLine) 15 211 675 99

$autostartBox = New-Object Windows.Forms.CheckBox
$autostartBox.Text = 'Start ClipWarp and language correction when signing in to Windows'
$autostartBox.Location = New-Object Drawing.Point(23,550)
$autostartBox.Size = New-Object Drawing.Size(560,26)
$autostartBox.Anchor = 'Left,Bottom'
try { $autostartBox.Checked = [bool](Get-ClipwarpAutostartEnabled) } catch {}
$form.Controls.Add($autostartBox)

$saveButton = New-Object Windows.Forms.Button
$saveButton.Text = 'Save settings'
$saveButton.Size = New-Object Drawing.Size(140,35)
$saveButton.Location = New-Object Drawing.Point(598,545)
$saveButton.Anchor = 'Right,Bottom'
$saveButton.BackColor = [Drawing.Color]::FromArgb(45,110,221)
$saveButton.ForeColor = [Drawing.Color]::White
$saveButton.FlatStyle = 'Flat'
$saveButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($saveButton)
$saveButton.Add_Click({
    try {
        $now = Get-ClipwarpRightLangConfig
        $now.mode = @('manual','auto','off')[$modePicker.SelectedIndex]
        $instant = [ordered]@{}
        foreach ($line in ($instantBox.Text -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line.Split([char[]]@('='),2)
            if ($parts.Count -ne 2 -or -not $parts[0].Trim() -or -not $parts[1].Trim()) {
                throw "Invalid instant correction line: $line"
            }
            $instant[$parts[0].Trim()] = $parts[1].Trim()
        }
        $now.instant = $instant
        $now.words = @($wordsBox.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $now.allowedApps = @($allowBox.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $now.blockedApps = @($blockBox.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        [void](Save-ClipwarpRightLangConfig -Settings $now)
        $oldAutostart = [bool](Get-ClipwarpAutostartEnabled)
        if ($oldAutostart -ne $autostartBox.Checked) {
            Set-ClipwarpAutostart -Enabled ([bool]$autostartBox.Checked) -WatchScriptPath (Join-Path $PSScriptRoot 'clipwarp-watch.ps1') -ErrorAction Stop
        }
        [Windows.Forms.MessageBox]::Show('Saved. The correction engine will reload your changes automatically.',
            'ClipWarp', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $form.Close()
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Unable to save',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
[void]$form.ShowDialog()
$form.Dispose()
