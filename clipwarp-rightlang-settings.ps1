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

$headerPanel = New-Object Windows.Forms.Panel
$headerPanel.Location = New-Object Drawing.Point(0,0)
$headerPanel.Size = New-Object Drawing.Size(765,87)
$headerPanel.Anchor = 'Top,Left,Right'
$headerPanel.BackColor = [Drawing.Color]::FromArgb(228,239,254)
$form.Controls.Add($headerPanel)
$headerIcon = New-Object Windows.Forms.PictureBox
$headerIcon.Location = New-Object Drawing.Point(22,19)
$headerIcon.Size = New-Object Drawing.Size(42,42)
$headerIcon.SizeMode = 'Zoom'
$headerIcon.Image = [Drawing.SystemIcons]::Information.ToBitmap()
$headerPanel.Controls.Add($headerIcon)
$headerPanel.Controls.Add((New-Label 'Language correction' 81 16 470 38 19 $true))
$headerPanel.Controls.Add((New-Label 'English ↔ Thai Kedmanee · Offline keyboard helper' 82 53 475 22 10 $false))
$languageBadge = New-Label 'Keyboard: detecting…' 558 29 190 34 10 $true
$languageBadge.TextAlign = 'MiddleCenter'
$languageBadge.BackColor = [Drawing.Color]::White
$languageBadge.ForeColor = [Drawing.Color]::FromArgb(25,91,186)
$languageBadge.BorderStyle = 'FixedSingle'
$languageBadge.Anchor = 'Top,Right'
$headerPanel.Controls.Add($languageBadge)
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipwarpRightLangKeyboardProbe {
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
}
'@ -ErrorAction Stop
} catch { }
$languageTimer = New-Object Windows.Forms.Timer
$languageTimer.Interval = 400
$languageTimer.Add_Tick({
    try {
        $current = [ClipwarpRightLangKeyboardProbe]::GetKeyboardLayout(0).ToInt64() -band 0xFFFF
        $languageBadge.Text = switch ($current) {
            0x41e { 'TH · ภาษาไทย'; break }
            0x409 { 'EN · English'; break }
            default { 'Keyboard: 0x{0:X4}' -f $current }
        }
    } catch { $languageBadge.Text = 'Language unavailable' }
})
$languageTimer.Start()
$form.Add_FormClosed({ $languageTimer.Stop(); $languageTimer.Dispose(); if ($headerIcon.Image) { $headerIcon.Image.Dispose() } })

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
$previewEngineAvailable = $false
try {
    if (-not ('ClipwarpRightLang.Engine' -as [type])) {
        $engineSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-rightlang.cs'))
        Add-Type -TypeDefinition $engineSource -ReferencedAssemblies @('System','System.Windows.Forms','System.Drawing') -ErrorAction Stop
    }
    $previewEngineAvailable = $true
} catch { $previewEngineAvailable = $false }

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(23,185)
$tabs.Size = New-Object Drawing.Size(715,350)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tabs.Appearance = 'Normal'
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

$previewTab = New-Object Windows.Forms.TabPage('Try correction')
[void]$tabs.TabPages.Add($previewTab)
$previewTab.Controls.Add((New-Label 'Type a sample to preview its conversion' 15 15 650 26 11 $true))
$previewTab.Controls.Add((New-Label 'No changes are made to other apps. This preview never uses the clipboard.' 15 43 665 28 9 $false))
$sampleBox = New-Object Windows.Forms.TextBox
$sampleBox.Location = New-Object Drawing.Point(16,88)
$sampleBox.Size = New-Object Drawing.Size(645,31)
$sampleBox.Anchor = 'Top,Left,Right'
$sampleBox.Text = 'l;ylfu'
$previewTab.Controls.Add($sampleBox)
$previewResult = New-Label ' ' 17 148 630 75 13 $true
$previewResult.ForeColor = [Drawing.Color]::FromArgb(30,95,175)
$previewResult.Anchor = 'Top,Left,Right'
$previewTab.Controls.Add($previewResult)
$previewCancel = New-Object Windows.Forms.Button
$previewCancel.Text = 'Cancel preview'
$previewCancel.Location = New-Object Drawing.Point(16,245)
$previewCancel.Size = New-Object Drawing.Size(165,35)
$previewCancel.BackColor = [Drawing.Color]::FromArgb(239,242,247)
$previewCancel.FlatStyle = 'Flat'
$previewTab.Controls.Add($previewCancel)
$refreshPreview = {
    $sample = $sampleBox.Text
    if (-not $sample) { $previewResult.Text = 'Enter text to preview'; return }
    if ($sample.Length -gt 64) { $previewResult.Text = 'Maximum 64 characters'; return }
    $rule = $null
    if ($cfg.instant.Contains($sample)) { $rule = [string]$cfg.instant[$sample] }
    if (-not $rule -and $previewEngineAvailable) {
        try { $rule = [ClipwarpRightLang.Engine]::ConvertLayout($sample) } catch { }
    }
    $previewResult.Text = if ($rule -and $rule -ne $sample) { "$sample    →    $rule" }
        else { 'No eligible correction for this sample' }
}
$sampleBox.Add_TextChanged($refreshPreview)
$previewCancel.Add_Click({ $sampleBox.Clear(); $previewResult.Text = 'Preview cancelled — no text was changed' })
& $refreshPreview


$autostartBox = New-Object Windows.Forms.CheckBox
$autostartBox.Text = 'Start ClipWarp and language correction when signing in to Windows'
$autostartBox.Location = New-Object Drawing.Point(23,550)
$autostartBox.Size = New-Object Drawing.Size(560,26)
$autostartBox.Anchor = 'Left,Bottom'
try { $autostartBox.Checked = [bool](Get-ClipwarpAutostartEnabled) } catch {}
$form.Controls.Add($autostartBox)

$saveButton = New-Object Windows.Forms.Button
$saveButton.Text = 'Save changes'
$saveButton.Size = New-Object Drawing.Size(140,35)
$saveButton.Location = New-Object Drawing.Point(598,545)
$saveButton.Anchor = 'Right,Bottom'
$saveButton.BackColor = [Drawing.Color]::FromArgb(30,95,190)
$saveButton.ForeColor = [Drawing.Color]::White
$saveButton.FlatStyle = 'Flat'
$saveButton.FlatAppearance.BorderSize = 0
$form.Controls.Add($saveButton)
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender,$e)
    if ($tabs.SelectedTab -eq $previewTab -and $e.KeyCode -eq [Windows.Forms.Keys]::Escape) {
        $sampleBox.Clear()
        $previewResult.Text = 'Preview cancelled — no text was changed'
        $e.Handled = $true
    }
})
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
