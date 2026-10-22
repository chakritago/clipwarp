$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert-Release([bool]$Test, [string]$Name) {
    if (-not $Test) { throw "RELEASE GATE: $Name" }
    Write-Host "PASS: $Name"
}
$engine = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang.cs'))
$bridge = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-editor-bridge.cs'))
$settings = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang-settings.ps1'))
$module = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang.psm1'))
$watcher = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-watch.ps1'))
$installer = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
$uninstall = [IO.File]::ReadAllText((Join-Path $root 'uninstall.ps1'))
$interactive = [IO.File]::ReadAllText((Join-Path $root 'tests\rightlang-interactive.ps1'))
$version = Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Release ($version.version -eq '1.18.0') 'release candidate version is 1.18.0'
Assert-Release ($module.Contains('editorBridgeEnabled = $false') -and
    $module.Contains('learnAccepted = $false') -and
    $module.Contains('smartSuggestions = $false') -and
    $module.Contains('undoHistory = $false')) 'all optional input features are disabled on upgrade'
Assert-Release ($engine.Contains('WH_KEYBOARD_LL') -and
    $engine.Contains('LLKHF_INJECTED') -and
    $engine.Contains('Thread worker = new Thread') -and
    $engine.Contains('worker.SetApartmentState(System.Threading.ApartmentState.STA)')) 'UIA work runs in an isolated STA worker without consuming synthetic keystrokes'
Assert-Release ($bridge.Contains('MaxAncestors = 4') -and
    $bridge.Contains('IsPassword') -and
    $bridge.Contains('SameSelection') -and
    $bridge.Contains('TryWordStyleFingerprint') -and
    -not $bridge.Contains('Clipboard.') -and
    -not $bridge.Contains('SetValue(')) 'editor bridge is bounded, password-aware, revalidated and read-only'
Assert-Release ($engine.Contains('if (!passive && vk == VK_RETURN') -and
    $engine.Contains('if (!passive && vk == VK_ESCAPE') -and
    $engine.Contains('CheckSmartSuggestion()')) 'passive hints never steal Enter or Esc'
Assert-Release ($engine.Contains('recentCorrections.Count > 6') -and
    $engine.Contains('public void ClearRecentCorrections')) 'undo history is bounded and clearable'
Assert-Release ($watcher.Contains('[bool]$cfg.smartSuggestions') -and
    $watcher.Contains('[bool]$cfg.undoHistory') -and
    $watcher.Contains('ClearRecentCorrections()')) 'watcher respects optional hint and history settings'
Assert-Release ($settings.Contains('คำที่เรียนรู้') -and
    $settings.Contains('Dark Mode') -and
    $settings.Contains('Set-Colors') -and
    $settings.Contains('$form.Add_SizeChanged') -and $settings.Contains('High Contrast') -and
    $settings.Contains('ก่อนแก้ไข')) 'premium UI exposes theme, responsive layout and dictionary controls'
Assert-Release ($installer.Contains('clipwarp-editor-bridge.cs') -and
    $uninstall.Contains('clipwarp-editor-bridge.cs')) 'installation and removal remain symmetrical'
Assert-Release ($interactive.Contains('[switch]$EditorBridge') -and
    $interactive.Contains('Windows E2E checklist') -and
    $interactive.Contains('Password')) 'real keyboard and app compatibility remain an explicit manual release gate'
Assert-Release ($bridge.Contains('TryWordStyleFingerprint') -and
    $bridge.Contains('MixedAttributeValue') -and
    $bridge.Contains('StyleFingerprint = styleFingerprint') -and
    $bridge.Contains('SameSelection')) 'Word formatting is fingerprinted and selection revalidated'
Assert-Release ($engine.Contains('suggestionDelayMs') -and
    $engine.Contains('suggestionCooldownMs') -and
    $engine.Contains('ignoredHints.Contains(token)') -and
    $engine.Contains('recentCorrections.Count > 6')) 'hint sensitivity and Undo memory are bounded'
Assert-Release ($module.Contains('highContrast = $false') -and
    $module.Contains('uiFontSize = 11') -and
    $module.Contains('learningLimit = 200') -and
    $module.Contains('Too many ignored suggestions')) 'accessibility and learning limits validated'
Assert-Release ($settings.Contains('AutoScaleMode') -and
    $settings.Contains('contrastToggle') -and
    $settings.Contains('fontSizePicker') -and
    $settings.Contains('ignoredEditor')) 'accessible Settings and personalized hints wired'
Write-Host 'PASS: static release guards completed. Physical keyboard and rich-text editor validation remain manual prerequisites.'
