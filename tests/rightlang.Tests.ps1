$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-rightlang.psm1') -Force

function Assert-Equal($expected, $actual, [string]$name) {
    if ($expected -ne $actual) { throw "$name : expected <$expected> got <$actual>" }
    Write-Host "PASS: $name"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-rightlang-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
$path = Join-Path $temp 'settings.json'
try {
    $default = Get-ClipwarpRightLangConfig -ConfigPath $path
    Assert-Equal 'manual' $default.mode 'safe default is manual mode'
    Assert-Equal $false $default.editorBridgeEnabled 'experimental editors default to off'
    Assert-Equal $false $default.learnAccepted 'learning disabled until explicitly enabled'
    Assert-Equal $false $default.darkMode 'light mode remains default'
    Assert-Equal $false $default.highContrast 'High Contrast disabled by default'
    Assert-Equal 11 $default.uiFontSize 'accessibility font default 11'
    Assert-Equal 650 $default.suggestionDelayMs 'hint delay default 650ms'
    Assert-Equal 5000 $default.suggestionCooldownMs 'hint cooldown default 5 seconds'
    Assert-Equal 200 $default.learningLimit 'learned words capped by default'
    Assert-Equal $false $default.smartSuggestions 'passive suggestions disabled until enabled'
    Assert-Equal $false $default.undoHistory 'undo history is opt-in and memory-only'
    Assert-Equal $true ($default.allowedApps -contains 'notepad') 'allowed apps are explicitly scoped'
    Assert-Equal $true ($default.blockedApps -contains 'bitwarden') 'password manager excluded'

    [IO.File]::WriteAllText($path, '{"version":1,"targetMode":"dual","calendar":{"enabled":false}}')
    $default.instant['example'] = 'ตัวอย่าง'
    $default.words = @('สวัสดี','ขอบคุณ','hello')
    $default.allowedApps = @('Notepad.EXE','WINWORD.EXE')
    $default.mode = 'auto'
    [void](Save-ClipwarpRightLangConfig -Settings $default -ConfigPath $path)
    $reload = Get-ClipwarpRightLangConfig -ConfigPath $path
    Assert-Equal 'auto' $reload.mode 'mode saved and restored'
    Assert-Equal 'ตัวอย่าง' $reload.instant['example'] 'UTF-8 instant corrections restored'
    Assert-Equal 3 $reload.words.Count 'custom words restored'
    Assert-Equal 'notepad' $reload.allowedApps[0] 'app name normalized'
    Assert-Equal 'winword' $reload.allowedApps[1] 'second app name normalized'
    $all = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-Equal 'dual' $all.targetMode 'other ClipWarp settings preserved'
    Assert-Equal $false $all.calendar.enabled 'Calendar setting preserved'
    $optIn = Get-ClipwarpRightLangConfig -ConfigPath $path
    $optIn.editorBridgeEnabled = $true
    $optIn.darkMode = $true
    $optIn.highContrast = $true
    $optIn.uiFontSize = 16
    $optIn.suggestionDelayMs = 1200
    $optIn.suggestionCooldownMs = 15000
    $optIn.learningLimit = 10
    $optIn.ignoredSuggestions = @('repeatme')
    $optIn.learnAccepted = $true
    $optIn.smartSuggestions = $true
    $optIn.undoHistory = $true
    [void](Save-ClipwarpRightLangConfig -Settings $optIn -ConfigPath $path)
    $opts = Get-ClipwarpRightLangConfig -ConfigPath $path
    Assert-Equal $true $opts.editorBridgeEnabled 'explicit UI Automation opt-in persisted'
    Assert-Equal $true $opts.darkMode 'Dark Mode setting persisted'
    Assert-Equal $true $opts.highContrast 'High Contrast setting persisted'
    Assert-Equal 16 $opts.uiFontSize 'Large font setting persisted'
    Assert-Equal 1200 $opts.suggestionDelayMs 'suggestion idle delay persisted'
    Assert-Equal 15000 $opts.suggestionCooldownMs 'repeated suggestion cooldown persisted'
    Assert-Equal 10 $opts.learningLimit 'learning cap persisted'
    Assert-Equal $true ($opts.ignoredSuggestions -contains 'repeatme') 'ignored suggestion persisted'
    Assert-Equal $false (Add-ClipwarpRightLangLearnedWord -Typed 'repeatme' -Corrected 'ไม่บันทึก' -ConfigPath $path) 'ignored words never learned'
    Assert-Equal $true $opts.learnAccepted 'learning opt-in persisted'
    Assert-Equal $true $opts.smartSuggestions 'passive suggestions opt-in persisted'
    Assert-Equal $true $opts.undoHistory 'memory-only history preference persisted'
    Assert-Equal $true (Add-ClipwarpRightLangLearnedWord -Typed 'misspelling' -Corrected 'คำที่ยืนยัน' -ConfigPath $path) 'confirmed word can be learned'
    $learned = Get-ClipwarpRightLangConfig -ConfigPath $path
    Assert-Equal 'คำที่ยืนยัน' $learned.instant['misspelling'] 'confirmed correction remembered'
    Assert-Equal $true ($learned.learnedKeys -contains 'misspelling') 'learned correction distinguished from user rules'
    Assert-Equal $false ($learned.learnedKeys -contains 'example') 'explicit instant rule not marked as learned'
    Assert-Equal $true (Remove-ClipwarpRightLangLearnedWord -Typed 'misspelling' -ConfigPath $path) 'individual learned word can be removed'
    Assert-Equal $false ((Get-ClipwarpRightLangConfig -ConfigPath $path).instant.Contains('misspelling')) 'deleted learned correction no longer active'
    Assert-Equal $true (Add-ClipwarpRightLangLearnedWord -Typed 'example' -Corrected 'ตัวอย่าง' -ConfigPath $path) 'same explicit mapping accepted without changing provenance'
    Assert-Equal $false (Add-ClipwarpRightLangLearnedWord -Typed 'example' -Corrected 'ไม่ควรแทนที่' -ConfigPath $path) 'learned correction cannot overwrite explicit rule'
    Assert-Equal 'ตัวอย่าง' (Get-ClipwarpRightLangConfig -ConfigPath $path).instant['example'] 'user-authored instant rule remains unchanged'
    Assert-Equal $true ((Get-ClipwarpRightLangConfig -ConfigPath $path).instant.Contains('example')) 'explicit correction survives learned deletion'
    Assert-Equal $true (Add-ClipwarpRightLangLearnedWord -Typed 'again' -Corrected 'อีกครั้ง' -ConfigPath $path) 'learn again'
    Assert-Equal 1 (Clear-ClipwarpRightLangLearnedWords -ConfigPath $path) 'clear learned entries reports count'
    Assert-Equal 0 @((Get-ClipwarpRightLangConfig -ConfigPath $path).learnedKeys).Count 'learned list cleared'
    $learned.learnAccepted = $false
    [void](Save-ClipwarpRightLangConfig -Settings $learned -ConfigPath $path)
    Assert-Equal $false (Add-ClipwarpRightLangLearnedWord -Typed 'ignoredword' -Corrected 'ไม่บันทึก' -ConfigPath $path) 'disabled learning ignores corrections'
    Assert-Equal $false ((Get-ClipwarpRightLangConfig -ConfigPath $path).instant.Contains('ignoredword')) 'no correction stored without consent'
    [void](Set-ClipwarpRightLangMode -Mode off -ConfigPath $path)
    Assert-Equal 'off' (Get-ClipwarpRightLangConfig -ConfigPath $path).mode 'off mode persists'
    [void](Set-ClipwarpRightLangMode -Mode manual -ConfigPath $path)
    Assert-Equal 'manual' (Get-ClipwarpRightLangConfig -ConfigPath $path).mode 'manual mode persists'
    $bad = Get-ClipwarpRightLangConfig -ConfigPath $path
    $bad.mode = 'invalid'
    $caught = $false
    try { [void](Save-ClipwarpRightLangConfig -Settings $bad -ConfigPath $path) } catch { $caught = $true }
    Assert-Equal $true $caught 'reject invalid mode'
    Assert-Equal 'manual' (Get-ClipwarpRightLangConfig -ConfigPath $path).mode 'invalid mode leaves settings untouched'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
