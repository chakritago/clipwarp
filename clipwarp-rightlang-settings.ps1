# ClipWarp Settings 2.0: localized, responsive Windows Forms, no clipboard access.
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'clipwarp-rightlang.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force

$config = Get-ClipwarpRightLangConfig
$previewAvailable = $false
try {
    if (-not ('ClipwarpRightLang.Engine' -as [type])) {
        $engineSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-rightlang.cs'), [Text.Encoding]::UTF8)
        $bridgeSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-editor-bridge.cs'), [Text.Encoding]::UTF8)
        Add-Type -TypeDefinition ($engineSource + $bridgeSource) -ReferencedAssemblies @('System','System.Windows.Forms','System.Drawing') -ErrorAction Stop
    }
    $previewAvailable = $true
} catch { $previewAvailable = $false }

$form = New-Object Windows.Forms.Form
$form.Text = 'ClipWarp — ตั้งค่าแก้ข้อความผิดภาษา'
$form.MinimumSize = New-Object Drawing.Size(700,620)
$form.Size = New-Object Drawing.Size(930,730)
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'
$form.Font = New-Object Drawing.Font('Leelawadee UI',11)
$form.KeyPreview = $true

function New-Label([string]$title) {
    $c = New-Object Windows.Forms.Label
    $c.Text = $title; $c.AutoSize = $false
    $c.TextAlign = 'MiddleLeft'
    return $c
}
function New-Box([string]$value) {
    $c = New-Object Windows.Forms.TextBox
    $c.Multiline = $true; $c.ScrollBars = 'Vertical'; $c.AcceptsReturn = $true
    $c.Dock = 'Fill'; $c.Text = $value
    return $c
}
function New-Tab([string]$title, [string]$description, [string]$text) {
    $page = New-Object Windows.Forms.TabPage
    $page.Text = $title; $page.Padding = New-Object Windows.Forms.Padding(14)
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 2
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',66)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    $descriptionLabel = New-Label $description
    $descriptionLabel.Dock = 'Fill'
    $descriptionLabel.AutoEllipsis = $true
    $editor = New-Box $text
    $layout.Controls.Add($descriptionLabel,0,0)
    $layout.Controls.Add($editor,0,1)
    $page.Controls.Add($layout)
    return [pscustomobject]@{ Page=$page; Editor=$editor }
}

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 99
$form.Controls.Add($header)
$icon = New-Object Windows.Forms.PictureBox
$icon.Image = [Drawing.SystemIcons]::Information.ToBitmap()
$icon.Location = New-Object Drawing.Point(20,23)
$icon.Size = New-Object Drawing.Size(42,42)
$icon.SizeMode = 'Zoom'
$header.Controls.Add($icon)
$heading = New-Label 'ClipWarp · แก้ข้อความผิดภาษา'
$heading.SetBounds(77,13,610,42)
$heading.Font = New-Object Drawing.Font('Leelawadee UI',17,[Drawing.FontStyle]::Bold)
$header.Tag = 'premium-header'
$heading.Anchor = 'Top,Left,Right'
$header.Controls.Add($heading)
$tagline = New-Label 'ไทยเกษมณี ↔ อังกฤษ · ประมวลผลในเครื่อง · ยกเลิกได้'
$tagline.SetBounds(78,54,610,32)
$tagline.Anchor = 'Top,Left,Right'
$header.Controls.Add($tagline)

$themePanel = New-Object Windows.Forms.Panel
$themePanel.Dock = 'Top'; $themePanel.Height = 118
$themePanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($themePanel)
$themeLabel = New-Label 'โหมดสี'
$themeLabel.SetBounds(22,6,75,46);$themePanel.Controls.Add($themeLabel)
$darkToggle = New-Object Windows.Forms.CheckBox
$darkToggle.Text = 'Dark Mode'
$darkToggle.SetBounds(97,13,180,37)
$darkToggle.Checked = [bool]$config.darkMode
$themePanel.Controls.Add($darkToggle)
$contrastToggle = New-Object Windows.Forms.CheckBox
$contrastToggle.Text = 'High Contrast'
$contrastToggle.Checked = [bool]$config.highContrast
$contrastToggle.SetBounds(260,13,155,34)
$themePanel.Controls.Add($contrastToggle)
$fontLabel = New-Label 'ขนาดตัวอักษร'
$fontLabel.SetBounds(422,10,125,38)
$themePanel.Controls.Add($fontLabel)
$fontSizePicker = New-Object Windows.Forms.NumericUpDown
$fontSizePicker.Minimum = 10; $fontSizePicker.Maximum = 18; $fontSizePicker.Increment = 1
$fontSizePicker.Value = [decimal]$config.uiFontSize
$fontSizePicker.SetBounds(550,15,75,34)
$themePanel.Controls.Add($fontSizePicker)
$editorFontLabel=New-Label 'ข้อความในรายการ'
$editorFontLabel.SetBounds(22,51,145,30); $themePanel.Controls.Add($editorFontLabel)
$editorFontPicker=New-Object Windows.Forms.NumericUpDown
$editorFontPicker.Minimum=10; $editorFontPicker.Maximum=24
$editorFontPicker.Value=[decimal]$config.editorFontSize
$editorFontPicker.SetBounds(171,51,72,31); $themePanel.Controls.Add($editorFontPicker)
$previewFontLabel=New-Label 'ข้อความตัวอย่าง'
$previewFontLabel.SetBounds(274,51,145,30); $themePanel.Controls.Add($previewFontLabel)
$previewFontPicker=New-Object Windows.Forms.NumericUpDown
$previewFontPicker.Minimum=10; $previewFontPicker.Maximum=24
$previewFontPicker.Value=[decimal]$config.previewFontSize
$previewFontPicker.SetBounds(423,51,72,31); $themePanel.Controls.Add($previewFontPicker)
$langBadge = New-Label 'กำลังตรวจสอบภาษา…'
$langBadge.SetBounds(22,88,570,27)
$langBadge.Anchor = 'Top,Left,Right'
$langBadge.TextAlign = 'MiddleCenter'; $langBadge.BorderStyle = 'FixedSingle'
$langBadge.Font = New-Object Drawing.Font('Leelawadee UI',10,[Drawing.FontStyle]::Bold)
$themePanel.Controls.Add($langBadge)

$optionsPanel = New-Object Windows.Forms.Panel
$optionsPanel.Dock = 'Top'; $optionsPanel.Height = 181
$optionsPanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($optionsPanel)
$modeLabel = New-Label 'รูปแบบการแก้ไข'
$modeLabel.SetBounds(22,3,170,34)
$optionsPanel.Controls.Add($modeLabel)
$mode = New-Object Windows.Forms.ComboBox
$mode.DropDownStyle = 'DropDownList'
[void]$mode.Items.Add('แก้ด้วยปุ่มลัด (แนะนำ)')
[void]$mode.Items.Add('แก้อัตโนมัติ เฉพาะคำที่รู้จัก')
[void]$mode.Items.Add('ปิดระบบแก้ไขภาษา')
$mode.SelectedIndex = switch($config.mode){'auto'{1};'off'{2};default{0}}
$mode.SetBounds(22,37,430,35)
$mode.Anchor = 'Top,Left,Right'
$optionsPanel.Controls.Add($mode)
$shortcuts = New-Label 'เลือกข้อความ: Shift+Caps Lock   |   ยืนยัน: Enter   |   ยกเลิก: Esc   |   ย้อนกลับ: F8'
$shortcuts.SetBounds(22,78,860,28)
$shortcuts.Anchor = 'Top,Left,Right'
$optionsPanel.Controls.Add($shortcuts)
$bridgeCheck = New-Object Windows.Forms.CheckBox
$bridgeCheck.Text = 'ทดลองรองรับ Notepad ใหม่ / Word / VS Code (เฉพาะแอปที่อนุญาต)'
$bridgeCheck.Checked = [bool]$config.editorBridgeEnabled
$bridgeCheck.SetBounds(22,113,815,32)
$bridgeCheck.Anchor = 'Top,Left,Right'
$optionsPanel.Controls.Add($bridgeCheck)
$learnCheck = New-Object Windows.Forms.CheckBox
$learnCheck.Text = 'เรียนรู้เมื่อผู้ใช้ยืนยัน'
$learnCheck.Checked = [bool]$config.learnAccepted
$learnCheck.SetBounds(22,146,410,32)
$learnCheck.Anchor = 'Top,Left';$optionsPanel.Controls.Add($learnCheck)
$hintCheck = New-Object Windows.Forms.CheckBox
$hintCheck.Text = 'แนะนำคำเมื่อหยุดพิมพ์ (ไม่แทรกคำอัตโนมัติ)'
$hintCheck.Checked = [bool]$config.smartSuggestions
$hintCheck.SetBounds(15,10,640,31)
$hintCheck.Anchor = 'Top,Left,Right'
$historyCheck = New-Object Windows.Forms.CheckBox
$historyCheck.Text = 'เก็บประวัติ Undo ในหน่วยความจำเท่านั้น (ไม่บันทึกลงดิสก์)'
$historyCheck.Checked = [bool]$config.undoHistory
$historyCheck.SetBounds(15,46,685,31)
$historyCheck.Anchor = 'Top,Left,Right'

$footer = New-Object Windows.Forms.Panel
$footer.Dock = 'Bottom'; $footer.Height = 85
$form.Controls.Add($footer)
$autostart = New-Object Windows.Forms.CheckBox
$autostart.Text = 'เริ่ม ClipWarp พร้อม Windows'
$autostart.SetBounds(20,12,490,34)
$autostart.Anchor = 'Top,Left'
try { $autostart.Checked = [bool](Get-ClipwarpAutostartEnabled) } catch {}
$footer.Controls.Add($autostart)
$save = New-Object Windows.Forms.Button
$save.Text = 'บันทึกการตั้งค่า'
$save.FlatStyle = 'Flat'; $save.FlatAppearance.BorderSize = 0
$save.SetBounds(717,18,175,44)
$save.Anchor = 'Right,Bottom'
$footer.Controls.Add($save)
$note = New-Label 'การเปลี่ยนคำใน Word อาจเปลี่ยนรูปแบบภายในข้อความที่เลือก — ทดสอบก่อนใช้งานจริง'
$note.SetBounds(20,47,670,27)
$note.Anchor = 'Bottom,Left,Right'
$footer.Controls.Add($note)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = New-Object Drawing.Font('Leelawadee UI',10)
$form.Controls.Add($tabs)
$tabs.BringToFront()

$instantPage = New-Tab 'คำแก้ไขทันที' "หนึ่งบรรทัดต่อหนึ่งกฎ: คำที่พิมพ์ผิด=คำที่ถูกต้อง (เช่น l;ylfu=สวัสดี)" (($config.instant.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join [Environment]::NewLine)
$wordPage = New-Tab 'คำที่กำหนดเอง' 'ระบุคำที่ถูกต้องหนึ่งคำต่อบรรทัด ใช้กับโหมดแก้อัตโนมัติ' ($config.words -join [Environment]::NewLine)
$allowPage = New-Tab 'แอปที่อนุญาต' 'ชื่อโปรเซส .exe ที่ยอมให้ตรวจคำ เช่น notepad, winword, code — ไม่ใช่ทุก Editor จะรองรับ' ($config.allowedApps -join [Environment]::NewLine)
$blockPage = New-Tab 'แอปที่ยกเว้น' 'ห้ามแก้ไขในแอปเหล่านี้ แม้จะอยู่ในรายการอนุญาต' ($config.blockedApps -join [Environment]::NewLine)
foreach($p in @($instantPage,$wordPage,$allowPage,$blockPage)){[void]$tabs.TabPages.Add($p.Page)}

$previewPage = New-Object Windows.Forms.TabPage
$previewPage.Text = 'ก่อน / หลัง'
$previewPage.Padding = New-Object Windows.Forms.Padding(15)
$previewLayout = New-Object Windows.Forms.TableLayoutPanel
$previewLayout.Dock='Fill';$previewLayout.ColumnCount=2;$previewLayout.RowCount=3
[void]$previewLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)))
[void]$previewLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)))
[void]$previewLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',48)))
[void]$previewLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$previewLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',57)))
$beforeLabel=New-Label 'ก่อนแก้ไข'
$afterLabel=New-Label 'หลังแก้ไข (ตัวอย่าง ไม่เปลี่ยนข้อความจริง)'
$beforeLabel.Dock='Fill';$afterLabel.Dock='Fill'
$previewLayout.Controls.Add($beforeLabel,0,0);$previewLayout.Controls.Add($afterLabel,1,0)
$before=New-Box 'l;ylfu'
$after=New-Box ''
$after.ReadOnly=$true
$previewLayout.Controls.Add($before,0,1);$previewLayout.Controls.Add($after,1,1)
$cancelPreview = New-Object Windows.Forms.Button
$cancelPreview.Text = 'ล้างตัวอย่าง'
$cancelPreview.Dock = 'Right';$cancelPreview.Width=170
$previewLayout.Controls.Add($cancelPreview,1,2)
$help=New-Label 'ระบบจะไม่คัดลอกหรือส่งข้อมูลตัวอย่างออกจากเครื่อง'
$help.Dock='Fill';$previewLayout.Controls.Add($help,0,2)
$previewPage.Controls.Add($previewLayout)
[void]$tabs.TabPages.Add($previewPage)

# Learned words can be removed without deleting user-authored instant rules.
$learnedPage = New-Object Windows.Forms.TabPage
$learnedPage.Text = 'คำที่เรียนรู้'
$learnedPage.Padding = New-Object Windows.Forms.Padding(14)
$learnedLayout = New-Object Windows.Forms.TableLayoutPanel
$learnedLayout.Dock = 'Fill'; $learnedLayout.RowCount = 3; $learnedLayout.ColumnCount = 1
[void]$learnedLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',100)))
[void]$learnedLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$learnedLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',54)))
$learnedInfo = New-Label 'รายการที่จดจำหลังคุณยืนยัน · เลือกลบได้โดยไม่กระทบคำที่เพิ่มเอง'
$learnedToolbar=New-Object Windows.Forms.Panel
$learnedToolbar.Dock='Fill'
$learnedInfo.SetBounds(0,0,630,31)
$learnedToolbar.Controls.Add($learnedInfo)
$learnedSearch=New-Object Windows.Forms.TextBox
$learnedSearch.SetBounds(0,39,345,32)
$learnedSearch.Anchor='Top,Left,Right'
$learnedSearch.AccessibleName='ค้นหาคำที่เรียนรู้'
$learnedToolbar.Controls.Add($learnedSearch)
$learnedFilter=New-Object Windows.Forms.ComboBox
$learnedFilter.DropDownStyle='DropDownList'
[void]$learnedFilter.Items.Add('มีคำค้นหา')
[void]$learnedFilter.Items.Add('ขึ้นต้นด้วย')
$learnedFilter.SelectedIndex=0
$learnedFilter.SetBounds(358,39,155,32)
$learnedToolbar.Controls.Add($learnedFilter)
$learnedCount=New-Label '0 รายการ'
$learnedCount.SetBounds(525,39,100,32)
$learnedToolbar.Controls.Add($learnedCount)
$learnedLayout.Controls.Add($learnedToolbar,0,0)
$learnedList = New-Object Windows.Forms.ListBox
$learnedList.Dock = 'Fill'
$learnedLayout.Controls.Add($learnedList,0,1)
$learnedActions = New-Object Windows.Forms.FlowLayoutPanel
$learnedActions.Dock = 'Fill'
$removeLearned = New-Object Windows.Forms.Button
$removeLearned.Text = 'ลบคำที่เลือก';$removeLearned.Width=155;$removeLearned.Height=36
$clearLearned = New-Object Windows.Forms.Button
$clearLearned.Text = 'ลบทั้งหมด';$clearLearned.Width=155;$clearLearned.Height=36
[void]$learnedActions.Controls.Add($removeLearned)
[void]$learnedActions.Controls.Add($clearLearned)
$ignoreSelected = New-Object Windows.Forms.Button
$ignoreSelected.Text='ไม่แนะนำคำที่เลือก';$ignoreSelected.Width=180;$ignoreSelected.Height=36
[void]$learnedActions.Controls.Add($ignoreSelected)
$learnedLayout.Controls.Add($learnedActions,0,2)
$learnedPage.Controls.Add($learnedLayout)
[void]$tabs.TabPages.Add($learnedPage)

$suggestPage = New-Object Windows.Forms.TabPage
$suggestPage.Text = 'ปรับคำแนะนำ'
$suggestPage.Padding = New-Object Windows.Forms.Padding(12)
$suggestTop = New-Object Windows.Forms.Panel
$suggestTop.Dock = 'Top'
$suggestTop.Height = 175
$suggestPage.Controls.Add($suggestTop)
$suggestTop.Controls.Add($hintCheck)
$suggestTop.Controls.Add($historyCheck)
$delayLabel = New-Label 'หน่วงคำแนะนำ (ms)'
$delayLabel.SetBounds(15,83,175,29)
$suggestTop.Controls.Add($delayLabel)
$delayPicker = New-Object Windows.Forms.NumericUpDown
$delayPicker.Minimum=350;$delayPicker.Maximum=2000;$delayPicker.Increment=50
$delayPicker.Value=[decimal]$config.suggestionDelayMs
$delayPicker.SetBounds(15,115,140,32)
$suggestTop.Controls.Add($delayPicker)
$cooldownLabel=New-Label 'ไม่แนะนำคำเดิมซ้ำ (ms)'
$cooldownLabel.SetBounds(170,83,210,29)
$suggestTop.Controls.Add($cooldownLabel)
$cooldownPicker=New-Object Windows.Forms.NumericUpDown
$cooldownPicker.Minimum=500;$cooldownPicker.Maximum=120000;$cooldownPicker.Increment=500
$cooldownPicker.Value=[decimal]$config.suggestionCooldownMs
$cooldownPicker.SetBounds(170,115,155,32)
$suggestTop.Controls.Add($cooldownPicker)
$capLabel=New-Label 'เก็บคำที่เรียนรู้สูงสุด'
$capLabel.SetBounds(344,83,190,29)
$suggestTop.Controls.Add($capLabel)
$limitPicker=New-Object Windows.Forms.NumericUpDown
$limitPicker.Minimum=10;$limitPicker.Maximum=500;$limitPicker.Increment=10
$limitPicker.Value=[decimal]$config.learningLimit
$limitPicker.SetBounds(344,115,135,32)
$suggestTop.Controls.Add($limitPicker)
$ignoredPanel=New-Object Windows.Forms.Panel
$ignoredPanel.Dock='Fill'
$suggestPage.Controls.Add($ignoredPanel)
$ignoredPanel.BringToFront()
$ignoredLabel=New-Label 'ไม่แนะนำคำเหล่านี้ (หนึ่งคำต่อบรรทัด)'
$ignoredLabel.Dock='Top';$ignoredLabel.Height=29
$ignoredPanel.Controls.Add($ignoredLabel)
$ignoredEditor=New-Box ($config.ignoredSuggestions -join [Environment]::NewLine)
$ignoredPanel.Controls.Add($ignoredEditor)
$ignoredEditor.BringToFront()
[void]$tabs.TabPages.Add($suggestPage)
# Per-app policy never grants monitoring permission: allowlist and global Off always win.
$appPage=New-Tab 'การทำงานรายแอป' 'หนึ่งบรรทัด: process=inherit|manual|auto|off,inherit|on|off เช่น notepad=manual,off' (($config.appPolicies.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join [Environment]::NewLine)
[void]$tabs.TabPages.Add($appPage)

$removedLearned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$learnedOriginal = @($config.learnedKeys)
$reloadLearned = {
    $selected=[string]$learnedList.SelectedItem
    $learnedList.BeginUpdate()
    try {
        $learnedList.Items.Clear()
        $search=[string]$learnedSearch.Text
        foreach($key in $learnedOriginal){
            if($removedLearned.Contains([string]$key) -or -not $config.instant.Contains($key)) { continue }
            if($search) {
                $matches=if($learnedFilter.SelectedIndex -eq 1) {
                    ([string]$key).StartsWith($search,[StringComparison]::OrdinalIgnoreCase)
                } else {
                    ([string]$key).IndexOf($search,[StringComparison]::OrdinalIgnoreCase) -ge 0
                }
                if(-not $matches){continue}
            }
            [void]$learnedList.Items.Add([string]$key)
        }
        $learnedCount.Text=("{0} รายการ" -f $learnedList.Items.Count)
        if($selected -and $learnedList.Items.Contains($selected)) { $learnedList.SelectedItem=$selected }
    } finally { $learnedList.EndUpdate() }
}
$learnedSearch.Add_TextChanged($reloadLearned)
$learnedFilter.Add_SelectedIndexChanged($reloadLearned)
& $reloadLearned
$removeLearned.Add_Click({
    if($learnedList.SelectedItem){
        $key=[string]$learnedList.SelectedItem
        [void]$removedLearned.Add($key)
        & $reloadLearned
    }
})
$clearLearned.Add_Click({
    foreach($key in $learnedOriginal) { [void]$removedLearned.Add([string]$key) }
    & $reloadLearned
})
$ignoreSelected.Add_Click({
    if(-not $learnedList.SelectedItem){return}
    $key=[string]$learnedList.SelectedItem
    $existing=@($ignoredEditor.Text -split '\r?\n' | Where-Object { $_.Trim() })
    if($existing -notcontains $key){$ignoredEditor.Text=(@($existing)+@($key) -join [Environment]::NewLine)}
})

$refresh = {
    $inputText=$before.Text
    if(-not $inputText){$after.Text='';return}
    if($inputText.Length -gt 64){$after.Text='จำกัดข้อความไม่เกิน 64 ตัวอักษร';return}
    $answer=$null
    foreach($line in ($instantPage.Editor.Text -split '\r?\n')){
        $parts=$line.Split([char[]]@('='),2)
        if($parts.Count -eq 2 -and $parts[0].Trim() -ceq $inputText){
            $answer=$parts[1].Trim();break
        }
    }
    if(-not $answer -and $previewAvailable){
        try{$answer=[ClipwarpRightLang.Engine]::ConvertLayout($inputText)}catch{}
    }
    $after.Text=if($answer){$answer}else{'ไม่พบคำแปลงที่เหมาะสม'}
}
$before.Add_TextChanged($refresh)
$instantPage.Editor.Add_TextChanged($refresh)
$cancelPreview.Add_Click({$before.Clear();$after.Text='ยกเลิกตัวอย่างแล้ว'})
& $refresh

# Use current keyboard layout of the active window (not the settings UI thread).
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipwarpUiLayout {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
}
'@ -ErrorAction Stop
} catch {}
$languageTimer=New-Object Windows.Forms.Timer
$languageTimer.Interval=500
$languageTimer.Add_Tick({
    try {
        [uint32]$proc=0
        $win=[ClipwarpUiLayout]::GetForegroundWindow()
        $thread=[ClipwarpUiLayout]::GetWindowThreadProcessId($win,[ref]$proc)
        $lang=[ClipwarpUiLayout]::GetKeyboardLayout($thread).ToInt64() -band 65535
        $langBadge.Text=switch($lang){0x41e{'TH · ภาษาไทย';break};0x409{'EN · English';break};default{'ภาษาอื่น'}}
    } catch {$langBadge.Text='ตรวจสอบภาษาไม่ได้'}
})
$languageTimer.Start()

function Set-Colors([Windows.Forms.Control]$node,[bool]$dark,[bool]$contrast) {
    $background=if($contrast){[Drawing.SystemColors]::Window}elseif($dark){[Drawing.Color]::FromArgb(28,32,40)}else{[Drawing.Color]::FromArgb(249,250,253)}
    $foreground=if($contrast){[Drawing.SystemColors]::WindowText}elseif($dark){[Drawing.Color]::FromArgb(238,242,247)}else{[Drawing.Color]::FromArgb(30,41,57)}
    $inputBg=if($contrast){[Drawing.SystemColors]::Window}elseif($dark){[Drawing.Color]::FromArgb(41,48,59)}else{[Drawing.Color]::White}
    $node.BackColor=$background;$node.ForeColor=$foreground
    if($node -is [Windows.Forms.TextBox] -or $node -is [Windows.Forms.ComboBox] -or
       $node -is [Windows.Forms.NumericUpDown] -or $node -is [Windows.Forms.ListBox]){
        $node.BackColor=$inputBg;$node.ForeColor=$foreground
    }
    foreach($child in $node.Controls){Set-Colors $child $dark $contrast}
}
$applyTheme = {
    $hc=[bool]$contrastToggle.Checked
    $dark=[bool]$darkToggle.Checked
    Set-Colors $form $dark $hc
    $header.BackColor=if($hc){[Drawing.SystemColors]::Window}elseif($dark){[Drawing.Color]::FromArgb(22,42,70)}else{[Drawing.Color]::FromArgb(226,239,255)}
    $save.BackColor=if($hc){[Drawing.SystemColors]::Highlight}elseif($dark){[Drawing.Color]::FromArgb(52,117,213)}else{[Drawing.Color]::FromArgb(25,92,189)}
    $save.ForeColor=if($hc){[Drawing.SystemColors]::HighlightText}else{[Drawing.Color]::White}
    $heading.BackColor=$header.BackColor
    $tagline.BackColor=$header.BackColor
    $icon.BackColor=$header.BackColor
    $langBadge.BackColor=if($hc){[Drawing.SystemColors]::Window}elseif($dark){[Drawing.Color]::FromArgb(52,62,81)}else{[Drawing.Color]::White}
    $after.BackColor=if($hc){[Drawing.SystemColors]::Window}elseif($dark){[Drawing.Color]::FromArgb(42,60,75)}else{[Drawing.Color]::FromArgb(238,246,255)}
}
$applyFont = {
    $size=[float]$fontSizePicker.Value
    if ($form.Font.Size -ne $size) { $form.Font=New-Object Drawing.Font('Leelawadee UI',$size) }
    if ($tabs.Font.Size -ne $size) { $tabs.Font=New-Object Drawing.Font('Leelawadee UI',$size) }
    $hc=($form.ClientSize.Width -lt 820)
    $heading.Font=New-Object Drawing.Font('Leelawadee UI',($size + $(if($hc){2}else{5})),[Drawing.FontStyle]::Bold)
    $langBadge.Font=New-Object Drawing.Font('Leelawadee UI',$size,[Drawing.FontStyle]::Bold)
    $editorSize=[float]$editorFontPicker.Value
    foreach($editor in @($instantPage.Editor,$wordPage.Editor,$allowPage.Editor,$blockPage.Editor,$ignoredEditor,$appPage.Editor)) {
        if($editor.Font.Size -ne $editorSize){$editor.Font=New-Object Drawing.Font('Leelawadee UI',$editorSize)}
    }
    $previewSize=[float]$previewFontPicker.Value
    foreach($editor in @($before,$after)) {
        if($editor.Font.Size -ne $previewSize){$editor.Font=New-Object Drawing.Font('Leelawadee UI',$previewSize)}
    }
    $shortcuts.Font=New-Object Drawing.Font('Leelawadee UI',[Math]::Max(9,$size - 1))
}
$darkToggle.Add_CheckedChanged($applyTheme)
$contrastToggle.Add_CheckedChanged($applyTheme)
$fontSizePicker.Add_ValueChanged($applyFont)
$editorFontPicker.Add_ValueChanged($applyFont)
$previewFontPicker.Add_ValueChanged($applyFont)
$form.Add_SizeChanged({
    $compact=$form.ClientSize.Width -lt 820
    $heading.Width=[Math]::Max(345,$form.ClientSize.Width - 120)
    $tagline.Width=[Math]::Max(345,$form.ClientSize.Width - 120)
    $save.Width=if($compact){155}else{175}
    # Do not reset Form.Font here: AutoScale can recursively fire SizeChanged.
})
& $applyTheme
& $applyFont

$save.Add_Click({
    try {
        $settings = Get-ClipwarpRightLangConfig
        $settings.mode = @('manual','auto','off')[$mode.SelectedIndex]
        $rules=[ordered]@{}
        foreach($line in ($instantPage.Editor.Text -split '\r?\n')){
            if(-not $line.Trim()){continue}
            $parts=$line.Split([char[]]@('='),2)
            if($parts.Count -ne 2 -or -not $parts[0].Trim() -or -not $parts[1].Trim()){throw "กฎคำผิดรูปแบบ: $line"}
            $rules[$parts[0].Trim()]=$parts[1].Trim()
        }
        foreach($key in $removedLearned){[void]$rules.Remove([string]$key)}
        $settings.instant=$rules
        $settings.learnedKeys=@($learnedOriginal | Where-Object { -not $removedLearned.Contains([string]$_) })
        $settings.smartSuggestions=[bool]$hintCheck.Checked
        $settings.undoHistory=[bool]$historyCheck.Checked
        $settings.suggestionDelayMs=[int]$delayPicker.Value
        $settings.suggestionCooldownMs=[int]$cooldownPicker.Value
        $settings.learningLimit=[int]$limitPicker.Value
        $settings.ignoredSuggestions=@($ignoredEditor.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $settings.words=@($wordPage.Editor.Text -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
        $settings.allowedApps=@($allowPage.Editor.Text -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
        $settings.blockedApps=@($blockPage.Editor.Text -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
        $settings.darkMode=[bool]$darkToggle.Checked
        $settings.highContrast=[bool]$contrastToggle.Checked
        $settings.uiFontSize=[int]$fontSizePicker.Value
        $settings.editorFontSize=[int]$editorFontPicker.Value
        $settings.previewFontSize=[int]$previewFontPicker.Value
        $appRules=[ordered]@{}
        foreach($line in ($appPage.Editor.Text -split '\r?\n')){
            if(-not $line.Trim()){continue}
            $parts=$line.Split([char[]]@('='),2)
            if($parts.Count -ne 2){throw "กฎแอปไม่ถูกต้อง: $line"}
            $appRules[$parts[0].Trim()]=$parts[1].Trim()
        }
        $settings.appPolicies=$appRules
        $settings.editorBridgeEnabled=[bool]$bridgeCheck.Checked
        $settings.learnAccepted=[bool]$learnCheck.Checked
        [void](Save-ClipwarpRightLangConfig -Settings $settings)
        $previous=[bool](Get-ClipwarpAutostartEnabled)
        if($previous -ne $autostart.Checked){
            Set-ClipwarpAutostart -Enabled ([bool]$autostart.Checked) -WatchScriptPath (Join-Path $PSScriptRoot 'clipwarp-watch.ps1') -ErrorAction Stop
        }
        [Windows.Forms.MessageBox]::Show('บันทึกการตั้งค่าแล้ว ClipWarp จะอ่านค่าใหม่โดยอัตโนมัติ','ClipWarp') | Out-Null
        $form.Close()
    }catch{
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'ไม่สามารถบันทึกได้') | Out-Null
    }
})
$form.Add_KeyDown({
    param($sender,$evt)
    if($evt.Control -and $evt.KeyCode -eq [Windows.Forms.Keys]::S){
        $save.PerformClick();$evt.SuppressKeyPress=$true;return
    }
    if($evt.Control -and $evt.KeyCode -eq [Windows.Forms.Keys]::F){
        $tabs.SelectedTab=$learnedPage
        $learnedSearch.Focus()
        $evt.SuppressKeyPress=$true;return
    }
    if($evt.KeyCode -eq [Windows.Forms.Keys]::F6){
        $tabs.Focus();$evt.SuppressKeyPress=$true;return
    }
    if($tabs.SelectedTab -eq $learnedPage -and $evt.KeyCode -eq [Windows.Forms.Keys]::Delete -and
       $learnedList.Focused -and $learnedList.SelectedItem){
        $removeLearned.PerformClick();$evt.SuppressKeyPress=$true;return
    }
    if($evt.KeyCode -eq [Windows.Forms.Keys]::Escape -and $tabs.SelectedTab -eq $previewPage){
        $before.Clear();$after.Text='ยกเลิกตัวอย่างแล้ว';$evt.Handled=$true
    }
})
$save.AccessibleName='บันทึกการตั้งค่า ClipWarp'
$removeLearned.AccessibleName='ลบคำที่เรียนรู้ที่เลือก'
$ignoreSelected.AccessibleName='ปิดคำแนะนำสำหรับคำที่เลือก'
$learnedList.AccessibleName='รายการคำที่เรียนรู้'
foreach($btn in @($save,$removeLearned,$clearLearned,$ignoreSelected,$cancelPreview)) {
    $btn.Add_Enter({ param($sender,$args) $sender.FlatStyle='Flat';$sender.FlatAppearance.BorderSize=2;$sender.FlatAppearance.BorderColor=[Drawing.SystemColors]::Highlight })
    $btn.Add_Leave({ param($sender,$args) $sender.FlatAppearance.BorderSize=0 })
}
$form.Add_FormClosed({
    $languageTimer.Stop();$languageTimer.Dispose()
    if($icon.Image){$icon.Image.Dispose()}
})
if($SelfTest){
    try {
        if($tabs.TabPages.Count -ne 8){throw "Expected eight settings tabs"}
        if($mode.Items.Count -ne 3){throw "Expected three correction modes"}
        $darkToggle.Checked = $true
        if($form.BackColor.R -ne 28){throw "Dark theme did not apply"}
        $darkToggle.Checked = $false
        if($form.BackColor.R -ne 249){throw "Light theme did not apply"}
        $before.Text = 'l;ylfu'
        if($after.Text -ne 'สวัสดี'){throw "Before/after preview was not rendered"}
        if(-not $bridgeCheck -or -not $learnCheck -or -not $hintCheck -or -not $historyCheck){throw "Missing opt-in controls"}
        if($optionsPanel.Height -lt 175){throw "Missing responsive options area"}
        if($delayPicker.Value -lt 350 -or $limitPicker.Value -lt 10){throw "Missing suggestion settings"}
        $contrastToggle.Checked=$true
        if($form.BackColor.ToArgb() -ne [Drawing.SystemColors]::Window.ToArgb()){throw "High contrast palette unavailable"}
        $contrastToggle.Checked=$false
        $fontSizePicker.Value=14
        if($form.Font.Size -ne 14){throw "Font scaling did not apply"}
        $editorFontPicker.Value=16
        $previewFontPicker.Value=17
        if($instantPage.Editor.Font.Size -ne 16 -or $before.Font.Size -ne 17){throw "Independent font scaling failed"}
        $learnedSearch.Text="nomatch"
        if($learnedList.Items.Count -ne 0){throw "Learned search filtering failed"}
        $learnedSearch.Clear()
        if($appPage.Text -ne "การทำงานรายแอป"){throw "App policy tab missing"}
        $tabs.SelectedTab=$learnedPage
        if(-not $learnedSearch.TabStop){throw "Learned search keyboard focus disabled"}
        foreach ($dimensions in @(@(700,620),@(780,650),@(930,730))) {
            $form.Size=New-Object Drawing.Size($dimensions[0],$dimensions[1])
            $form.PerformLayout()
            if($tabs.Width -lt 10 -or $tabs.Height -lt 10){throw "Responsive tabs have invalid bounds"}
            if($save.Width -lt 150){throw "Save button inaccessible at width $($dimensions[0])"}
        }
        if($form.AutoScaleMode -ne [Windows.Forms.AutoScaleMode]::Dpi){throw "DPI autoscaling disabled"}
        if($learnedPage.Text -ne 'คำที่เรียนรู้'){throw "Missing learned-word management"}
        Write-Host 'PASS: Thai Settings 2.0 structure, theme switching, local before/after and opt-ins'
    } finally {
        $languageTimer.Stop()
        $languageTimer.Dispose()
        if($icon.Image){$icon.Image.Dispose()}
        $form.Dispose()
    }
    return
}
try{[void]$form.ShowDialog()}finally{$form.Dispose()}
