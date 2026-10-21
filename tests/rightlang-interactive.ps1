# Real, opt-in Windows desktop integration check.
# Run interactively in a non-elevated PowerShell 5.1 window:
#   powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File .\tests\rightlang-interactive.ps1
# Requires a visible desktop; never runs in unattended CI or changes user clipboard.
[CmdletBinding()]
param([switch]$EditorBridge)
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Windows desktop required.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang.cs')) + [IO.File]::ReadAllText((Join-Path $root 'clipwarp-editor-bridge.cs'))
Add-Type -TypeDefinition $source -ReferencedAssemblies @('System','System.Windows.Forms','System.Drawing') -ErrorAction Stop

$form = New-Object Windows.Forms.Form
$form.Text = 'ClipWarp – Real keyboard integration test (no clipboard)'
$form.Size = New-Object Drawing.Size(870,790)
$form.MinimumSize = New-Object Drawing.Size(780,650)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.KeyPreview = $false

$intro = New-Object Windows.Forms.Label
$intro.Text = 'Use your REAL keyboard. The hook deliberately ignores synthetic SendInput typing. Select the sample text, test the shortcuts, and verify each result below.'
$intro.SetBounds(18,15,800,50)
$form.Controls.Add($intro)

$inputBox = New-Object Windows.Forms.TextBox
$inputBox.SetBounds(18,80,800,38)
$inputBox.Font = New-Object Drawing.Font('Segoe UI',15)
$inputBox.Text = 'l;ylfu'
$form.Controls.Add($inputBox)

$passwordBox = New-Object Windows.Forms.TextBox
$passwordBox.SetBounds(18,132,330,34)
$passwordBox.PasswordChar = '*'
$passwordBox.Text = 'l;ylfu'
$form.Controls.Add($passwordBox)
$pwLabel = New-Object Windows.Forms.Label
$pwLabel.Text = 'Password field (must NOT correct)'
$pwLabel.SetBounds(360,139,400,28)
$form.Controls.Add($pwLabel)

$engine = New-Object ClipwarpRightLang.Engine
$rules = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$rules.Add('l;ylfu','สวัสดี')
$allowedProcesses = [string[]]@('powershell','notepad','winword','code')
$engine.Configure('manual',$rules,[string[]]@('สวัสดี','hello'),$allowedProcesses,[string[]]@(),[bool]$EditorBridge,$false)
$engine.Start()
$state = New-Object Windows.Forms.Label
$state.Text = if ($engine.Installed) { 'Keyboard hooks installed · UI Automation available=' + [ClipwarpRightLang.EditorBridge]::Available + ' · enabled=' + $EditorBridge } else { 'HOOK FAILED: close other conflicting apps or check privileges' }
$state.SetBounds(18,182,810,28)
$state.ForeColor = if ($engine.Installed) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DarkRed }
$form.Controls.Add($state)

$manualButton = New-Object Windows.Forms.Button
$manualButton.Text = 'Manual mode'
$manualButton.SetBounds(18,218,160,35)
$manualButton.Add_Click({ $engine.Configure('manual',$rules,[string[]]@('สวัสดี','hello'),$allowedProcesses,[string[]]@(),[bool]$EditorBridge,$false); $state.Text = 'Mode: manual'; $inputBox.Focus() })
$form.Controls.Add($manualButton)

$autoButton = New-Object Windows.Forms.Button
$autoButton.Text = 'Automatic mode'
$autoButton.SetBounds(193,218,175,35)
$autoButton.Add_Click({ $engine.Configure('auto',$rules,[string[]]@('สวัสดี','hello'),$allowedProcesses,[string[]]@(),[bool]$EditorBridge,$false); $state.Text = 'Mode: automatic (known words)'; $inputBox.Focus() })
$form.Controls.Add($autoButton)

$offButton = New-Object Windows.Forms.Button
$offButton.Text = 'Off'
$offButton.SetBounds(384,218,110,35)
$offButton.Add_Click({ $engine.Configure('off',$rules,[string[]]@('สวัสดี','hello'),$allowedProcesses,[string[]]@(),[bool]$EditorBridge,$false); $state.Text = 'Mode: off'; $inputBox.Focus() })
$form.Controls.Add($offButton)

$instructions = @(
    '1. Manual: type l;ylfu, Shift+Backspace, see preview, Enter: สวัสดี'
    '2. Undo: immediately press F8 after correction: l;ylfu returns'
    '3. Selection: select l;ylfu, Shift+Caps Lock, Enter: สวัสดี'
    '4. Cancel: invoke preview, Esc: original text remains'
    '5. Automatic: click Automatic, type l;ylfu + Space: converts'
    '6. Password and Off: shortcuts must not correct'
    '7. Compatibility: without -EditorBridge, Word/VS Code and rich editors unchanged'
    '8. Modern Notepad: selection preview/accept/undo in supported TextPattern provider'
    '9. Word: select formatted text, correct; verify styles outside selected span and native Undo'
    '10. VS Code: verify selection when accessibility TextPattern is supported; else fail closed'
    '11. Switch windows during preview; ensure no text changes'
    '12. While typing rapidly, verify no hangs from global keyboard hook'
    '13. Run with -EditorBridge and verify excluded browser/password fields unchanged'
)
$listPanel = New-Object Windows.Forms.Panel
$listPanel.SetBounds(18,268,810,405)
$listPanel.AutoScroll = $true
$listPanel.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($listPanel)
$checks = @()
for ($i = 0; $i -lt $instructions.Count; $i++) {
    $check = New-Object Windows.Forms.CheckBox
    $check.Text = $instructions[$i]
    $check.AutoSize = $false
    $check.SetBounds(8,($i*34),770,31)
    $listPanel.Controls.Add($check)
    $checks += $check
}
$finish = New-Object Windows.Forms.Button
$finish.Text = 'Summarize checked scenarios'
$finish.SetBounds(18,690,300,38)
$finish.Anchor = 'Bottom,Left'
$finish.Add_Click({
    $passCount = @($checks | Where-Object Checked).Count
    $summary = [pscustomobject]@{
        TestedAt = (Get-Date).ToString('o')
        Computer = [Environment]::OSVersion.VersionString
        EditorBridgeEnabled = [bool]$EditorBridge
        Total = $checks.Count
        Pass = $passCount
        AllConfirmed = ($passCount -eq $checks.Count)
        Scenarios = @($checks | ForEach-Object { [pscustomobject]@{ Name=$_.Text; Confirmed=$_.Checked } })
    }
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-e2e-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    [IO.File]::WriteAllText($outFile,($summary | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    [Windows.Forms.MessageBox]::Show(
        "ตรวจจริงแล้ว $passCount / $($checks.Count) รายการ`nบันทึกผลที่: $outFile`nบันทึกเฉพาะผลการตรวจ ไม่บันทึกข้อความที่พิมพ์",
        'Windows E2E checklist') | Out-Null
})
$form.Controls.Add($finish)
$form.Add_Shown({ $inputBox.Focus() })
try { [void]$form.ShowDialog() }
finally { $engine.Dispose(); $form.Dispose() }
