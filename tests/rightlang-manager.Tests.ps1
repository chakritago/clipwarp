# Dictionary Manager 3.0: group persistence, validation, duplicate preview and safe import.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-rightlang-dictionary.psm1') -Force
Import-Module (Join-Path $root 'clipwarp-rightlang.psm1') -Force
function Assert-Manager([bool]$value,[string]$message){
    if(-not $value){throw "DICTIONARY MANAGER: $message"}
    Write-Host "PASS: $message"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-manager-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp -Force)
try {
    $targetCfg=Join-Path $temp 'target.json'
    $sourceCfg=Join-Path $temp 'source.json'
    $export=Join-Path $temp 'portable.json'
    $target=Get-ClipwarpRightLangConfig -ConfigPath $targetCfg
    $target.instant=[ordered]@{ typoA='ค่าดั้งเดิม' }
    $target.words=@('สวัสดี')
    $target.learnedKeys=@()
    $target.dictionaryGroups=[ordered]@{ 'rule|typoA'='งาน'; 'word|สวัสดี'='ทักทาย' }
    [void](Save-ClipwarpRightLangConfig -Settings $target -ConfigPath $targetCfg)
    $loaded=Get-ClipwarpRightLangConfig -ConfigPath $targetCfg
    Assert-Manager ($loaded.dictionaryGroups['rule|typoA'] -eq 'งาน' -and $loaded.dictionaryGroups['word|สวัสดี'] -eq 'ทักทาย') 'group metadata persists in local configuration'
    $rows=@(Get-ClipwarpRightLangDictionaryRows -ConfigPath $targetCfg)
    $rule=@($rows | Where-Object { $_.Kind -eq 'Rule' -and $_.Source -eq 'typoA' })[0]
    Assert-Manager ($rule.Group -eq 'งาน' -and $rule.Origin -eq 'กำหนดเอง') 'manager model includes group and rule origin'
    $rule.Replacement='แก้ไขแล้ว';$rule.Group='ภาษาไทย'
    $saved=Save-ClipwarpRightLangDictionaryRows -Rows $rows -ConfigPath $targetCfg
    $after=Get-ClipwarpRightLangConfig -ConfigPath $targetCfg
    Assert-Manager ($saved.Saved -and $after.instant['typoA'] -eq 'แก้ไขแล้ว') 'edited table mapping saves correctly'
    Assert-Manager ($after.dictionaryGroups['rule|typoA'] -eq 'ภาษาไทย') 'edited group saves correctly'
    $badRows=@($rows)+@([pscustomobject]@{Kind='Rule';Source='TYPOA';Replacement='ชน';Group='ภาษาไทย';Origin='กำหนดเอง';OriginalSource='';OriginalReplacement=''})
    $bad=Test-ClipwarpRightLangDictionaryRows -Rows $badRows
    Assert-Manager (-not $bad.Valid -and @($bad.Errors | Where-Object { $_ -match 'ซ้ำ' }).Count -gt 0) 'duplicate source keys are rejected case-insensitively'
    $before=Get-Content -LiteralPath $targetCfg -Encoding UTF8 -Raw
    $saveRejected=$false
    try { [void](Save-ClipwarpRightLangDictionaryRows -Rows $badRows -ConfigPath $targetCfg) } catch { $saveRejected=$true }
    $afterRejected=Get-Content -LiteralPath $targetCfg -Encoding UTF8 -Raw
    Assert-Manager ($saveRejected -and $before -ceq $afterRejected) 'invalid duplicate table cannot partially save'
    $source=Get-ClipwarpRightLangConfig -ConfigPath $sourceCfg
    $source.instant=[ordered]@{ typoA='ค่าจากไฟล์';newrule='คำใหม่' }
    $source.words=@('สวัสดี','hello2')
    $source.learnedKeys=@()
    $source.dictionaryGroups=[ordered]@{ 'rule|newrule'='กลุ่มใหม่';'word|hello2'='English' }
    [void](Save-ClipwarpRightLangConfig -Settings $source -ConfigPath $sourceCfg)
    [void](Export-ClipwarpRightLangDictionary -Path $export -ConfigPath $sourceCfg)
    $json=Get-Content -LiteralPath $export -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-Manager ($json.schema -eq 2 -and $json.groups.'rule|newrule' -eq 'กลุ่มใหม่') 'schema v2 export includes group assignments'
    $preview=Get-ClipwarpRightLangDictionaryPreview -Path $export -ConfigPath $targetCfg
    Assert-Manager ($preview.NewRules -eq 1 -and $preview.ConflictingRules -eq 1 -and
        $preview.NewWords -eq 1 -and $preview.DuplicateWords -eq 1) 'import preview distinguishes new, duplicate and conflicting items'
    $import=Import-ClipwarpRightLangDictionary -Path $export -ConfigPath $targetCfg
    $final=Get-ClipwarpRightLangConfig -ConfigPath $targetCfg
    Assert-Manager ($final.instant['typoA'] -eq 'แก้ไขแล้ว') 'conflicting imported rule never overwrites existing mapping'
    Assert-Manager ($final.instant['newrule'] -eq 'คำใหม่' -and $final.dictionaryGroups['rule|newrule'] -eq 'กลุ่มใหม่') 'new rules and groups import together'
    Assert-Manager (($final.words -contains 'hello2') -and $final.dictionaryGroups['word|hello2'] -eq 'English') 'new custom words and groups import together'
    Assert-Manager ($import.Skipped -ge 2 -and $import.CustomWords -eq 1) 'duplicate/conflicting entries are reported as skipped'
    $learnedOnly=Join-Path $temp 'learned-only.json'
    $learnCfg=Get-ClipwarpRightLangConfig -ConfigPath $sourceCfg
    $learnCfg.learnedKeys=@('newrule')
    [void](Save-ClipwarpRightLangConfig -Settings $learnCfg -ConfigPath $sourceCfg)
    [void](Export-ClipwarpRightLangDictionary -Path $learnedOnly -LearnedOnly -ConfigPath $sourceCfg)
    $learnedPreview=Get-ClipwarpRightLangDictionaryPreview -Path $learnedOnly -ConfigPath $targetCfg
    Assert-Manager ($learnedPreview.Kind -eq 'learned' -and $learnedPreview.NewRules -eq 0) 'learned-only export remains valid when the learned rule already exists'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
