# Real, opt-in Windows desktop integration check.
# Run interactively in a non-elevated PowerShell 5.1 window:
#   powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File .\tests\rightlang-interactive.ps1
# Requires a visible desktop; never runs in unattended CI or changes user clipboard.
[CmdletBinding()]
param()
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Windows desktop required.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang.cs'))
Add-Type -TypeDefinition $source -ReferencedAssemblies @('System','System.Windows.Forms','System.Drawing') -ErrorAction Stop

$form = New-Object Windows.Forms.Form
$form.Text = 'ClipWarp – Real keyboard integration test (no clipboard)'
$form.Size = New-Object Drawing.Size(800,600)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.KeyPreview = $false

$intro = New-Object Windows.Forms.Label
$intro.Text = 'Use your REAL keyboard. The hook deliberately ignores synthetic SendInput typing. Select the sample text, test the shortcuts, and verify each result below.'
$intro.SetBounds(18,15,740,50)
$form.Controls.Add($intro)

$inputBox = New-Object Windows.Forms.TextBox
$inputBox.SetBounds(18,80,740,38)
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
$engine.Configure('manual',$rules,[string[]]@('สวัสดี','hello'),[string[]]@('powershell'),[string[]]@())
$engine.Start()
$state = New-Object Windows.Forms.Label
$state.Text = if ($engine.Installed) { 'Keyboard + pointer hooks: installed (manual)' } else { 'HOOK FAILED: close other conflicting apps or check privileges' }
$state.SetBounds(18,182,740,28)
$state.ForeColor = if ($engine.Installed) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DarkRed }
$form.Controls.Add($state)

$manualButton = New-Object Windows.Forms.Button
$manualButton.Text = 'Manual mode'
$manualButton.SetBounds(18,218,160,35)
$manualButton.Add_Click({ $engine.Configure('manual',$rules,[string[]]@('สวัสดี','hello'),[string[]]@('powershell'),[string[]]@()); $state.Text = 'Mode: manual'; $inputBox.Focus() })
$form.Controls.Add($manualButton)

$autoButton = New-Object Windows.Forms.Button
$autoButton.Text = 'Automatic mode'
$autoButton.SetBounds(193,218,175,35)
$autoButton.Add_Click({ $engine.Configure('auto',$rules,[string[]]@('สวัสดี','hello'),[string[]]@('powershell'),[string[]]@()); $state.Text = 'Mode: automatic (known words)'; $inputBox.Focus() })
$form.Controls.Add($autoButton)

$offButton = New-Object Windows.Forms.Button
$offButton.Text = 'Off'
$offButton.SetBounds(384,218,110,35)
$offButton.Add_Click({ $engine.Configure('off',$rules,[string[]]@('สวัสดี','hello'),[string[]]@('powershell'),[string[]]@()); $state.Text = 'Mode: off'; $inputBox.Focus() })
$form.Controls.Add($offButton)

$instructions = @(
    '1. Manual: type l;ylfu, Shift+Backspace, see preview, Enter: สวัสดี'
    '2. Undo: immediately press F8 after correction: l;ylfu returns'
    '3. Selection: select l;ylfu, Shift+Caps Lock, Enter: สวัสดี'
    '4. Cancel: invoke preview, Esc: original text remains'
    '5. Automatic: click Automatic, type l;ylfu + Space: converts'
    '6. Password and Off: shortcuts must not correct'
    '7. Compatibility: confirm VS Code, Word, browsers are untouched by default'
)
$checks = @()
for ($i = 0; $i -lt $instructions.Count; $i++) {
    $check = New-Object Windows.Forms.CheckBox
    $check.Text = $instructions[$i]
    $check.AutoSize = $false
    $check.SetBounds(18,(270+$i*34),740,31)
    $form.Controls.Add($check)
    $checks += $check
}
$finish = New-Object Windows.Forms.Button
$finish.Text = 'Summarize checked scenarios'
$finish.SetBounds(18,516,270,34)
$finish.Add_Click({
    $passCount = @($checks | Where-Object Checked).Count
    [Windows.Forms.MessageBox]::Show(
        "Manually confirmed: $passCount / $($checks.Count) scenarios.`nThis is not a passing test report until you verify every scenario on your Windows machine.",
        'Integration test result') | Out-Null
})
$form.Controls.Add($finish)
$form.Add_Shown({ $inputBox.Focus() })
try { [void]$form.ShowDialog() }
finally { $engine.Dispose(); $form.Dispose() }
