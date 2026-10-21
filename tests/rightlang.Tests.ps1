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
