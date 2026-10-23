# ClipWarp dictionary tools: validated local JSON import/export and editable grouped dictionary.
Import-Module (Join-Path $PSScriptRoot 'clipwarp-rightlang.psm1') -ErrorAction Stop

function Assert-ClipwarpDictionaryPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.json') { throw 'Dictionary import/export requires a .json file.' }
    return $full
}
function Assert-ClipwarpDictionaryRules {
    param($Entries, [int]$Limit = 1000)
    $result = [ordered]@{}
    if ($null -eq $Entries) { return $result }
    if ($Entries -is [System.Collections.IDictionary]) {
        $pairs = @($Entries.Keys | ForEach-Object { [pscustomobject]@{ Name=[string]$_; Value=$Entries[$_] } })
    } else {
        $pairs = @($Entries.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } |
            ForEach-Object { [pscustomobject]@{ Name=$_.Name; Value=$_.Value } })
    }
    if ($pairs.Count -gt $Limit) { throw 'Dictionary contains too many rules.' }
    foreach ($pair in $pairs) {
        $key=[string]$pair.Name; $value=$pair.Value
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or
            [string]::IsNullOrWhiteSpace($value) -or $key.Length -lt 2 -or $key.Length -gt 64 -or $value.Length -gt 128) {
            throw 'Dictionary contains an invalid or oversized correction rule.'
        }
        if ($result.Contains($key)) { throw 'Duplicate correction rule.' }
        $result[$key]=[string]$value
    }
    return $result
}
function Read-ClipwarpRightLangDictionaryPayload {
    param([Parameter(Mandatory)][string]$Path)
    $source=Assert-ClipwarpDictionaryPath $Path
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Dictionary file not found.' }
    if ((Get-Item -LiteralPath $source).Length -gt 1048576) { throw 'Dictionary file exceeds 1 MiB.' }
    $json=[IO.File]::ReadAllText($source,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $json -or $json.format -cne 'clipwarp-rightlang-dictionary' -or
        $json.schema -notin @(1,2) -or $json.kind -notin @('dictionary','learned') -or $null -eq $json.instant) {
        throw 'Not a supported ClipWarp dictionary export.'
    }
    $rules=Assert-ClipwarpDictionaryRules $json.instant
    $learning=@($json.learnedKeys)
    if ($learning.Count -gt 1000) { throw 'Too many learned entries.' }
    foreach ($key in $learning) {
        if ($key -isnot [string] -or -not $rules.Contains([string]$key)) { throw 'Learned entry has no matching correction rule.' }
    }
    if ($json.kind -eq 'learned') {
        foreach ($key in $rules.Keys) {
            if ($learning -cnotcontains [string]$key) { throw 'Learned-only backup contains a non-learned rule.' }
        }
    }
    $words=@()
    if ($json.kind -eq 'dictionary') {
        $words=@($json.words)
        if ($words.Count -gt 2000) { throw 'Too many custom words.' }
        foreach ($word in $words) {
            if ($word -isnot [string] -or [string]::IsNullOrWhiteSpace($word) -or $word.Length -gt 128) {
                throw 'Invalid custom word in imported dictionary.'
            }
        }
    } elseif (@($json.words).Count -gt 0) { throw 'Learned-only backup must not contain custom words.' }
    $groups=Get-ClipwarpRightLangDictionaryGroups $json.groups
    foreach ($groupKey in $groups.Keys) {
        $kind=[string]$groupKey.Substring(0,4)
        $entryKey=[string]$groupKey.Substring(5)
        if ($kind -eq 'rule') {
            if (-not $rules.Contains($entryKey)) { throw "Group refers to a missing rule: $entryKey" }
        } elseif ($kind -eq 'word') {
            if ($words -cnotcontains $entryKey) { throw "Group refers to a missing custom word: $entryKey" }
        } else { throw 'Unsupported dictionary group kind.' }
    }
    return [pscustomobject]@{ Path=$source; Json=$json; Rules=$rules; LearnedKeys=$learning; Words=$words; Groups=$groups }
}
function Export-ClipwarpRightLangDictionary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[switch]$LearnedOnly,[switch]$Force,
          [string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $target=Assert-ClipwarpDictionaryPath $Path
    if ((Test-Path -LiteralPath $target) -and -not $Force) { throw 'Export already exists; use -Force to replace intentionally.' }
    $cfg=Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $rules=[ordered]@{}
    $learned=@($cfg.learnedKeys | Where-Object { $cfg.instant.Contains([string]$_) })
    if ($LearnedOnly) {
        foreach ($key in $learned) { $rules[[string]$key]=[string]$cfg.instant[$key] }
    } else {
        foreach ($key in $cfg.instant.Keys) { $rules[[string]$key]=[string]$cfg.instant[$key] }
    }
    $groups=[ordered]@{}
    foreach ($groupKey in $cfg.dictionaryGroups.Keys) {
        if (-not $LearnedOnly) { $groups[[string]$groupKey]=[string]$cfg.dictionaryGroups[$groupKey]; continue }
        if ([string]$groupKey -like 'rule|*' -and $learned -ccontains ([string]$groupKey).Substring(5)) {
            $groups[[string]$groupKey]=[string]$cfg.dictionaryGroups[$groupKey]
        }
    }
    $payload=[ordered]@{
        format='clipwarp-rightlang-dictionary'; schema=2
        kind=if($LearnedOnly){'learned'}else{'dictionary'}
        exportedAt=(Get-Date).ToUniversalTime().ToString('o')
        instant=$rules; words=if($LearnedOnly){@()}else{@($cfg.words)}
        learnedKeys=@($learned); groups=$groups
    }
    $text=ConvertTo-Json -InputObject $payload -Depth 6
    $dir=[IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'Export directory does not exist.' }
    $tmp=Join-Path $dir ('.clipwarp-dictionary-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllText($tmp,$text,(New-Object Text.UTF8Encoding($false)))
        if ((Test-Path -LiteralPath $target) -and -not $Force) { throw 'Export already exists.' }
        Move-Item -LiteralPath $tmp -Destination $target -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
    return [pscustomobject]@{ Path=$target; Kind=$payload.kind; Rules=$rules.Count; Learned=$learned.Count; Groups=$groups.Count; Schema=2; Plaintext=$true }
}
function Get-ClipwarpRightLangDictionaryPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $payload=Read-ClipwarpRightLangDictionaryPayload -Path $Path
    $cfg=Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $newRules=0; $duplicateRules=0; $conflictingRules=0; $newWords=0; $duplicateWords=0
    foreach ($key in $payload.Rules.Keys) {
        $source=[string]$key; $replacement=[string]$payload.Rules[$key]
        $status='ใหม่'; $conflict=$false
        if ($cfg.instant.Contains($source)) {
            if ([string]$cfg.instant[$source] -ceq $replacement) { $status='ซ้ำ · จะคงกฎเดิม'; $duplicateRules++ }
            else { $status='ชนกับกฎเดิม · จะไม่เขียนทับ'; $conflictingRules++; $conflict=$true }
        } else { $newRules++ }
        $group=if($payload.Groups.Contains("rule|$source")){[string]$payload.Groups["rule|$source"]}else{'ทั่วไป'}
        $rows.Add([pscustomobject]@{Kind='Rule';Source=$source;Replacement=$replacement;Group=$group;Status=$status;Duplicate=($status -ne 'ใหม่');Conflict=$conflict})
    }
    $existingWords=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($word in $cfg.words) { [void]$existingWords.Add([string]$word) }
    foreach ($word in $payload.Words) {
        $source=[string]$word; $status='ใหม่'
        if ($existingWords.Contains($source)) { $status='ซ้ำ · จะคงคำเดิม'; $duplicateWords++ } else { $newWords++ }
        $group=if($payload.Groups.Contains("word|$source")){[string]$payload.Groups["word|$source"]}else{'ทั่วไป'}
        $rows.Add([pscustomobject]@{Kind='Word';Source=$source;Replacement='';Group=$group;Status=$status;Duplicate=($status -ne 'ใหม่');Conflict=$false})
    }
    return [pscustomobject]@{
        Path=$payload.Path; Schema=$payload.Json.schema; Kind=$payload.Json.kind
        Rows=@($rows.ToArray()); NewRules=$newRules; DuplicateRules=$duplicateRules
        ConflictingRules=$conflictingRules; NewWords=$newWords; DuplicateWords=$duplicateWords
        CanImport=(($newRules+$newWords) -gt 0)
    }
}
function Import-ClipwarpRightLangDictionary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $payload=Read-ClipwarpRightLangDictionaryPayload -Path $Path
    $cfg=Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $added=0; $skipped=0; $learnedAdded=0; $addedWords=0; $groupsAdded=0
    $newRuleKeys=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $newWordKeys=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $payload.Rules.Keys) {
        if ($cfg.instant.Contains([string]$key)) { $skipped++; continue }
        if ($cfg.instant.Count -ge 1000) { throw 'Maximum correction count exceeded.' }
        $isLearned=$payload.LearnedKeys -ccontains [string]$key
        if ($isLearned -and @($cfg.learnedKeys).Count -ge $cfg.learningLimit) { $skipped++; continue }
        $cfg.instant[[string]$key]=[string]$payload.Rules[$key]
        $added++; [void]$newRuleKeys.Add([string]$key)
        if ($isLearned) {
            $cfg.learnedKeys=@(@($cfg.learnedKeys)+@([string]$key)|Select-Object -Unique); $learnedAdded++
        }
    }
    $existingWords=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($word in $cfg.words) { [void]$existingWords.Add([string]$word) }
    foreach ($word in $payload.Words) {
        if ($existingWords.Contains([string]$word)) { $skipped++; continue }
        if ($existingWords.Count -ge 2000) { throw 'Maximum custom word count exceeded.' }
        [void]$existingWords.Add([string]$word); [void]$newWordKeys.Add([string]$word); $addedWords++
    }
    $cfg.words=@($existingWords | ForEach-Object { [string]$_ })
    foreach ($groupKey in $payload.Groups.Keys) {
        $entryKey=[string]$groupKey.Substring(5)
        if ([string]$groupKey.StartsWith('rule|') -and $newRuleKeys.Contains($entryKey)) {
            $cfg.dictionaryGroups[[string]$groupKey]=[string]$payload.Groups[$groupKey]; $groupsAdded++
        } elseif ([string]$groupKey.StartsWith('word|') -and $newWordKeys.Contains($entryKey)) {
            $cfg.dictionaryGroups[[string]$groupKey]=[string]$payload.Groups[$groupKey]; $groupsAdded++
        }
    }
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return [pscustomobject]@{ Added=$added; Skipped=$skipped; Learned=$learnedAdded; CustomWords=$addedWords; Groups=$groupsAdded; Mode=$cfg.mode; AppPermissionsUnchanged=$true }
}
function Get-ClipwarpRightLangDictionaryRows {
    [CmdletBinding()]
    param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $cfg=Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $cfg.instant.Keys) {
        $source=[string]$key; $target=[string]$cfg.instant[$key]
        $origin=if($cfg.learnedKeys -ccontains $source){'เรียนรู้'}else{'กำหนดเอง'}
        $groupKey="rule|$source"; $group=if($cfg.dictionaryGroups.Contains($groupKey)){[string]$cfg.dictionaryGroups[$groupKey]}else{'ทั่วไป'}
        $rows.Add([pscustomobject]@{Kind='Rule';Source=$source;Replacement=$target;Group=$group;Origin=$origin;Status='ปกติ';OriginalSource=$source;OriginalReplacement=$target})
    }
    foreach ($word in $cfg.words) {
        $source=[string]$word; $groupKey="word|$source"; $group=if($cfg.dictionaryGroups.Contains($groupKey)){[string]$cfg.dictionaryGroups[$groupKey]}else{'ทั่วไป'}
        $rows.Add([pscustomobject]@{Kind='Word';Source=$source;Replacement='';Group=$group;Origin='คำกำหนดเอง';Status='ปกติ';OriginalSource=$source;OriginalReplacement=''})
    }
    return @($rows.ToArray())
}
function Test-ClipwarpRightLangDictionaryRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Rows)
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $normalized=New-Object 'System.Collections.Generic.List[object]'
    $seenRules=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $seenWords=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $index=0
    foreach ($row in $Rows) {
        $index++; $kind=([string]$row.Kind).Trim(); $source=([string]$row.Source).Trim()
        $replacement=([string]$row.Replacement).Trim(); $group=([string]$row.Group).Trim()
        if (-not $group) { $group='ทั่วไป' }
        if ($kind -notin @('Rule','Word')) { $errors.Add("แถว $index: ประเภทต้องเป็น Rule หรือ Word"); continue }
        if ($group.Length -gt 40 -or $group -match '[\r\n\t]') { $errors.Add("แถว $index: ชื่อกลุ่มต้องไม่เกิน 40 ตัวอักษร"); continue }
        if ($kind -eq 'Rule') {
            if ($source.Length -lt 2 -or $source.Length -gt 64 -or [string]::IsNullOrWhiteSpace($replacement) -or $replacement.Length -gt 128) {
                $errors.Add("แถว $index: กฎต้องมีคำต้นทาง 2–64 ตัวและคำแก้ไข 1–128 ตัว"); continue
            }
            if ($seenRules.ContainsKey($source)) { $errors.Add("แถว $index: คำต้นทางซ้ำกับแถวก่อนหน้า ($source)"); continue }
            $seenRules[$source]=$replacement
            $origin=if(([string]$row.Origin -eq 'เรียนรู้') -and ([string]$row.OriginalSource -ceq $source) -and ([string]$row.OriginalReplacement -ceq $replacement)){'เรียนรู้'}else{'กำหนดเอง'}
        } else {
            if ([string]::IsNullOrWhiteSpace($source) -or $source.Length -gt 128 -or $replacement) {
                $errors.Add("แถว $index: คำกำหนดเองต้องมีคำ 1–128 ตัวและช่องคำแก้ไขต้องว่าง"); continue
            }
            if (-not $seenWords.Add($source)) { $errors.Add("แถว $index: คำกำหนดเองซ้ำ ($source)"); continue }
            $origin='คำกำหนดเอง'
        }
        $normalized.Add([pscustomobject]@{Kind=$kind;Source=$source;Replacement=$replacement;Group=$group;Origin=$origin;Status='พร้อมบันทึก';OriginalSource=[string]$row.OriginalSource;OriginalReplacement=[string]$row.OriginalReplacement})
    }
    if ($seenRules.Count -gt 1000) { $errors.Add('จำนวนกฎเกิน 1,000 รายการ') }
    if ($seenWords.Count -gt 2000) { $errors.Add('จำนวนคำกำหนดเองเกิน 2,000 รายการ') }
    return [pscustomobject]@{Valid=($errors.Count -eq 0);Errors=@($errors.ToArray());Rows=@($normalized.ToArray());Rules=$seenRules.Count;Words=$seenWords.Count}
}
function Save-ClipwarpRightLangDictionaryRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Rows,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $check=Test-ClipwarpRightLangDictionaryRows -Rows $Rows
    if (-not $check.Valid) { throw ('ตรวจพจนานุกรมไม่ผ่าน: '+($check.Errors -join '; ')) }
    $cfg=Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $instant=[ordered]@{}; $words=New-Object 'System.Collections.Generic.List[string]'
    $learned=New-Object 'System.Collections.Generic.List[string]'; $groups=[ordered]@{}
    foreach ($row in $check.Rows) {
        if ($row.Kind -eq 'Rule') {
            $instant[[string]$row.Source]=[string]$row.Replacement
            if ($row.Origin -eq 'เรียนรู้') { $learned.Add([string]$row.Source) }
            $groups["rule|$($row.Source)"]=[string]$row.Group
        } else {
            $words.Add([string]$row.Source)
            $groups["word|$($row.Source)"]=[string]$row.Group
        }
    }
    $cfg.instant=$instant; $cfg.words=@($words.ToArray()); $cfg.learnedKeys=@($learned.ToArray()); $cfg.dictionaryGroups=$groups
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return [pscustomobject]@{Saved=$true;Rules=$check.Rules;Words=$check.Words;Groups=$groups.Count;Learned=$learned.Count}
}
function Backup-ClipwarpRightLangLearnedWords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Backup directory not found.' }
    $target=Join-Path $Directory ('clipwarp-learned-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
    Export-ClipwarpRightLangDictionary -Path $target -LearnedOnly -ConfigPath $ConfigPath
}
Export-ModuleMember -Function Export-ClipwarpRightLangDictionary,Import-ClipwarpRightLangDictionary,Backup-ClipwarpRightLangLearnedWords,Get-ClipwarpRightLangDictionaryPreview,Get-ClipwarpRightLangDictionaryRows,Test-ClipwarpRightLangDictionaryRows,Save-ClipwarpRightLangDictionaryRows
