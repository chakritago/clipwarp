# Portable dictionary/import backup safety; runs without keyboard hooks.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-rightlang-dictionary.psm1') -Force
Import-Module (Join-Path $root 'clipwarp-rightlang.psm1') -Force
function Assert-Dict([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    Write-Host "PASS: $Message"
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-dictionary-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp -Force)
try {
    $sourceCfg = Join-Path $tmp 'source.json'
    $targetCfg = Join-Path $tmp 'target.json'
    $export = Join-Path $tmp 'dictionary.json'
    $learned = Join-Path $tmp 'learned.json'
    $broken = Join-Path $tmp 'untrusted.json'
    $setup = Get-ClipwarpRightLangConfig -ConfigPath $sourceCfg
    $setup.instant['custom-portable-key'] = 'ทดสอบคำ'
    $setup.instant['learned-portable-key'] = 'คำเรียนรู้'
    $setup.learnedKeys = @('learned-portable-key')
    $setup.words = @($setup.words) + @('เพิ่มคำไทย')
    $setup.mode = 'auto'
    $setup.learnAccepted = $true
    $setup.allowedApps = @('notepad','winword')
    $setup.appPolicies = [ordered]@{ winword = 'auto,on' }
    [void](Save-ClipwarpRightLangConfig -Settings $setup -ConfigPath $sourceCfg)
    $result = Export-ClipwarpRightLangDictionary -Path $export -ConfigPath $sourceCfg
    Assert-Dict (Test-Path -LiteralPath $export) 'dictionary JSON exported'
    Assert-Dict ($result.Rules -gt 1 -and $result.Learned -eq 1) 'full dictionary exported with learned metadata'
    $doc = Get-Content -LiteralPath $export -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-Dict ($doc.format -eq 'clipwarp-rightlang-dictionary' -and $doc.schema -eq 2) 'versioned export schema'
    Assert-Dict ($null -eq $doc.allowedApps -and $null -eq $doc.appPolicies -and $null -eq $doc.password) 'dictionary export never includes app permissions or secrets'
    $protected = Get-ClipwarpRightLangConfig -ConfigPath $targetCfg
    $protected.mode = 'off'
    $protected.allowedApps = @('notepad')
    $protected.editorBridgeEnabled = $false
    [void](Save-ClipwarpRightLangConfig -Settings $protected -ConfigPath $targetCfg)
    $imported = Import-ClipwarpRightLangDictionary -Path $export -ConfigPath $targetCfg
    $loaded = Get-ClipwarpRightLangConfig -ConfigPath $targetCfg
    Assert-Dict ($loaded.instant['custom-portable-key'] -eq 'ทดสอบคำ' -and $imported.Added -gt 0) 'import merges portable corrections'
    Assert-Dict ($loaded.learnedKeys -contains 'learned-portable-key') 'learned-word provenance survives round trip'
    Assert-Dict ($loaded.mode -eq 'off' -and -not $loaded.editorBridgeEnabled -and $loaded.allowedApps.Count -eq 1) 'import never enables keyboard monitoring'
    Assert-Dict ($loaded.words -contains 'เพิ่มคำไทย') 'custom words restored'
    $again=Import-ClipwarpRightLangDictionary -Path $export -ConfigPath $targetCfg
    Assert-Dict ($again.Added -eq 0 -and $again.Skipped -gt 0) 'duplicate import skips existing rules'
    $saved=Export-ClipwarpRightLangDictionary -Path $learned -ConfigPath $sourceCfg -LearnedOnly
    $savedDoc=Get-Content -LiteralPath $learned -Encoding UTF8 -Raw | ConvertFrom-Json
    $exportedNames=@($savedDoc.instant.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { $_.Name })
    $nonemptyWords=@($savedDoc.words | Where-Object { $_ -is [string] -and $_.Length -gt 0 })
    Assert-Dict ($saved.Kind -eq 'learned' -and $exportedNames.Count -eq 1 -and
        $exportedNames -contains 'learned-portable-key' -and
        $exportedNames -notcontains 'custom-portable-key' -and
        $nonemptyWords.Count -eq 0) 'learned-only backup excludes manual rules'
    $backup=Backup-ClipwarpRightLangLearnedWords -Directory $tmp -ConfigPath $sourceCfg
    Assert-Dict (Test-Path -LiteralPath $backup.Path) 'automatic learned backup path is unique and created'
    $alreadyExists=$false
    try { [void](Export-ClipwarpRightLangDictionary -Path $export -ConfigPath $sourceCfg) } catch { $alreadyExists=$true }
    Assert-Dict $alreadyExists 'export refuses overwriting without explicit Force'
    $before=Get-Content -LiteralPath $targetCfg -Encoding UTF8 -Raw
    [IO.File]::WriteAllText($broken, '{"format":"clipwarp-rightlang-dictionary","schema":1,"kind":"dictionary","instant":{"bad":"ok"},"words":[""]}', (New-Object Text.UTF8Encoding($false)))
    $rejected=$false
    try { [void](Import-ClipwarpRightLangDictionary -Path $broken -ConfigPath $targetCfg) } catch { $rejected=$true }
    $after=Get-Content -LiteralPath $targetCfg -Encoding UTF8 -Raw
    Assert-Dict ($rejected -and $before -ceq $after) 'invalid import rejects atomically without touching existing configuration'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
