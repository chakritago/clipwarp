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
Assert-Release ($version.version -eq '1.19.0') 'release candidate version is 1.19.0'
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
$dictionaryModule = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang-dictionary.psm1'))
$evidenceScript = [IO.File]::ReadAllText((Join-Path $root 'tests\verify-rightlang-e2e.ps1'))
Assert-Release ($bridge.Contains('TrySelectionContext') -and $bridge.Contains('BeforeContext') -and
    $bridge.Contains('AfterContext') -and $bridge.Contains('StyleFingerprint')) 'rich editor selection context is revalidated'
Assert-Release ($engine.Contains('RecentUndoDetails') -and $engine.Contains('WhenUtc') -and
    $engine.Contains('Application') -and $engine.Contains('Undo sent; restoration could not be verified') -and
    $engine.Contains('EditorBridge.MatchesCaretTail')) 'Undo state is context-checked and reports uncertain native results'
Assert-Release ($dictionaryModule.Contains('Export-ClipwarpRightLangDictionary') -and
    $dictionaryModule.Contains('Import-ClipwarpRightLangDictionary') -and
    $dictionaryModule.Contains('Backup-ClipwarpRightLangLearnedWords') -and
    -not $dictionaryModule.Contains('Invoke-WebRequest')) 'portable dictionary and backup never upload data'
Assert-Release ($installer.Contains('clipwarp-rightlang-dictionary.psm1') -and
    $uninstall.Contains('clipwarp-rightlang-dictionary.psm1')) 'dictionary tools packaged and removed symmetrically'
Assert-Release ($settings.Contains('พจนานุกรม 3.0') -and
    $settings.Contains('Export-ClipwarpRightLangDictionary') -and
    $settings.Contains('Import-ClipwarpRightLangDictionary')) 'dictionary UI provides explicit import and export actions'
Assert-Release ($evidenceScript.Contains('RealDesktopGateSatisfied') -and
    $evidenceScript.Contains('StableReleaseApproved=$false') -and
    $evidenceScript.Contains('GITHUB_ACTIONS')) 'physical E2E attestation cannot promote a CI run to Stable'
Assert-Release ($engine.Contains('EvaluateInputTransaction') -and $engine.Contains('EvaluateUndoTransaction') -and
    $engine.Contains('IsExpectedTextAfterReplacement') -and $engine.Contains('Partial input; inspect the editor')) 'editor changes use explicit transaction states and exact postconditions'
Assert-Release ($bridge.Contains('prior.BeforeContext+replacement') -and
    $bridge.Contains('prior.AfterContext') -and $bridge.Contains('MatchesCaretTail')) 'native Undo checks selection prefix, replacement and suffix context'
$managerModule = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang-dictionary.psm1'))
$managerTests = [IO.File]::ReadAllText((Join-Path $root 'tests\rightlang-manager.Tests.ps1'))
Assert-Release ($settings.Contains('พจนานุกรม 3.0') -and $settings.Contains('DataGridView') -and
    $settings.Contains('ตรวจและบันทึก') -and $settings.Contains('ดูตัวอย่าง Import') -and
    $settings.Contains('Refresh-DictionaryStatuses')) 'Dictionary Manager grid, duplicate validation and import preview are wired'
Assert-Release ($managerModule.Contains('Get-ClipwarpRightLangDictionaryPreview') -and
    $managerModule.Contains('Test-ClipwarpRightLangDictionaryRows') -and
    $managerModule.Contains('Save-ClipwarpRightLangDictionaryRows') -and
    $managerModule.Contains('schema=2') -and $managerModule.Contains('dictionaryGroups')) 'dictionary manager model persists groups and validates before saving'
Assert-Release ($managerTests.Contains('ConflictingRules') -and $managerTests.Contains('invalid duplicate table cannot partially save') -and
    $managerTests.Contains('new custom words and groups import together')) 'dictionary manager regression suite covers conflicts and grouped import'
Write-Host 'PASS: static release guards completed. Physical keyboard and rich-text editor validation remain manual prerequisites.'
