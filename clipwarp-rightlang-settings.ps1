# ClipWarp Settings 2.0: localized, responsive Windows Forms, no clipboard access.
[CmdletBinding()]
param()
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
$form.MinimumSize = New-Object Drawing.Size(720,600)
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
$heading.Anchor = 'Top,Left,Right'
$header.Controls.Add($heading)
$tagline = New-Label 'ไทยเกษมณี ↔ อังกฤษ · ประมวลผลในเครื่อง · ยกเลิกได้'
$tagline.SetBounds(78,54,610,32)
$tagline.Anchor = 'Top,Left,Right'
$header.Controls.Add($tagline)

$themePanel = New-Object Windows.Forms.Panel
$themePanel.Dock = 'Top'; $themePanel.Height = 65
$form.Controls.Add($themePanel)
$themeLabel = New-Label 'โหมดสี'
$themeLabel.SetBounds(22,6,75,46);$themePanel.Controls.Add($themeLabel)
$darkToggle = New-Object Windows.Forms.CheckBox
$darkToggle.Text = 'Dark Mode'
$darkToggle.SetBounds(97,13,180,37)
$darkToggle.Checked = [bool]$config.darkMode
$themePanel.Controls.Add($darkToggle)
$langBadge = New-Label 'กำลังตรวจสอบภาษา…'
$langBadge.SetBounds(625,12,270,38)
$langBadge.Anchor = 'Top,Right'
$langBadge.TextAlign = 'MiddleCenter'; $langBadge.BorderStyle = 'FixedSingle'
$themePanel.Controls.Add($langBadge)

$optionsPanel = New-Object Windows.Forms.Panel
$optionsPanel.Dock = 'Top'; $optionsPanel.Height = 150
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
$bridgeCheck.SetBounds(22,113,565,32);$optionsPanel.Controls.Add($bridgeCheck)
$learnCheck = New-Object Windows.Forms.CheckBox
$learnCheck.Text = 'เรียนรู้เมื่อผู้ใช้ยืนยัน'
$learnCheck.Checked = [bool]$config.learnAccepted
$learnCheck.SetBounds(605,113,280,32)
$learnCheck.Anchor = 'Top,Right';$optionsPanel.Controls.Add($learnCheck)

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

function Set-Colors([Windows.Forms.Control]$node,[bool]$dark) {
    $background=if($dark){[Drawing.Color]::FromArgb(28,32,40)}else{[Drawing.Color]::FromArgb(249,250,253)}
    $foreground=if($dark){[Drawing.Color]::FromArgb(238,242,247)}else{[Drawing.Color]::FromArgb(30,41,57)}
    $inputBg=if($dark){[Drawing.Color]::FromArgb(41,48,59)}else{[Drawing.Color]::White}
    $node.BackColor=$background;$node.ForeColor=$foreground
    if($node -is [Windows.Forms.TextBox] -or $node -is [Windows.Forms.ComboBox]){
        $node.BackColor=$inputBg;$node.ForeColor=$foreground
    }
    if($node -is [Windows.Forms.TabPage]){$node.BackColor=$background}
    foreach($child in $node.Controls){Set-Colors $child $dark}
}
$applyTheme = {
    Set-Colors $form ([bool]$darkToggle.Checked)
    $header.BackColor=if($darkToggle.Checked){[Drawing.Color]::FromArgb(22,42,70)}else{[Drawing.Color]::FromArgb(226,239,255)}
    $save.BackColor=if($darkToggle.Checked){[Drawing.Color]::FromArgb(52,117,213)}else{[Drawing.Color]::FromArgb(25,92,189)}
    $save.ForeColor=[Drawing.Color]::White
    $langBadge.BackColor=if($darkToggle.Checked){[Drawing.Color]::FromArgb(52,62,81)}else{[Drawing.Color]::White}
    $after.BackColor=if($darkToggle.Checked){[Drawing.Color]::FromArgb(42,60,75)}else{[Drawing.Color]::FromArgb(238,246,255)}
}
$darkToggle.Add_CheckedChanged($applyTheme)
& $applyTheme

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
        $settings.instant=$rules
        $settings.words=@($wordPage.Editor.Text -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
        $settings.allowedApps=@($allowPage.Editor.Text -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
        $settings.blockedApps=@($blockPage.Editor.Text -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
        $settings.darkMode=[bool]$darkToggle.Checked
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
    if($evt.KeyCode -eq [Windows.Forms.Keys]::Escape -and $tabs.SelectedTab -eq $previewPage){
        $before.Clear();$after.Text='ยกเลิกตัวอย่างแล้ว';$evt.Handled=$true
    }
})
$form.Add_FormClosed({
    $languageTimer.Stop();$languageTimer.Dispose()
    if($icon.Image){$icon.Image.Dispose()}
})
try{[void]$form.ShowDialog()}finally{$form.Dispose()}
