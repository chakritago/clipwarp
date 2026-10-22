# ClipWarp portable dictionary interchange. No API calls, clipboard, credentials or app permissions.
Import-Module (Join-Path $PSScriptRoot 'clipwarp-rightlang.psm1') -Force

function Assert-ClipwarpDictionaryPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.json') { throw 'Dictionary export/import requires a .json file.' }
    return $full
}
function Assert-ClipwarpDictionaryRules {
    param($Entries, [int]$Limit = 1000)
    $result = [ordered]@{}
    if ($null -eq $Entries) { return $result }
    if ($Entries -is [System.Collections.IDictionary]) {
        $pairs = @($Entries.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Entries[$_] } })
    } else {
        $pairs = @($Entries.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } |
                    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
    }
    if ($pairs.Count -gt $Limit) { throw 'Dictionary contains too many rules.' }
    foreach ($pair in $pairs) {
        $key = [string]$pair.Name
        $val = $pair.Value
        if ($val -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or
            [string]::IsNullOrWhiteSpace($val) -or $key.Length -gt 64 -or $val.Length -gt 128) {
            throw 'Dictionary contains an invalid or oversized correction rule.'
        }
        if ($result.Contains($key)) { throw 'Duplicate correction rule.' }
        $result[$key] = [string]$val
    }
    return $result
}
function Export-ClipwarpRightLangDictionary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$LearnedOnly,
          [switch]$Force, [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $target = Assert-ClipwarpDictionaryPath $Path
    if ((Test-Path -LiteralPath $target) -and -not $Force) { throw 'Export already exists; use -Force to replace intentionally.' }
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $rules = [ordered]@{}
    $learned = @($cfg.learnedKeys | Where-Object { $cfg.instant.Contains([string]$_) })
    if ($LearnedOnly) {
        foreach ($key in $learned) { $rules[[string]$key] = [string]$cfg.instant[$key] }
    } else {
        foreach ($key in $cfg.instant.Keys) { $rules[[string]$key] = [string]$cfg.instant[$key] }
    }
    $payload = [ordered]@{
        format = 'clipwarp-rightlang-dictionary'
        schema = 1
        kind = if ($LearnedOnly) { 'learned' } else { 'dictionary' }
        exportedAt = (Get-Date).ToUniversalTime().ToString('o')
        instant = $rules
        words = if ($LearnedOnly) { @() } else { @($cfg.words) }
        learnedKeys = @($learned)
    }
    $text = ConvertTo-Json -InputObject $payload -Depth 5
    $dir = [IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'Export directory does not exist.' }
    $tmp = Join-Path $dir ('.clipwarp-dictionary-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
        if ((Test-Path -LiteralPath $target) -and -not $Force) { throw 'Export already exists.' }
        Move-Item -LiteralPath $tmp -Destination $target -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    return [pscustomobject]@{ Path=$target; Kind=$payload.kind; Rules=$rules.Count; Learned=$learned.Count; Plaintext=$true }
}
function Import-ClipwarpRightLangDictionary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $source = Assert-ClipwarpDictionaryPath $Path
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Dictionary file not found.' }
    if ((Get-Item -LiteralPath $source).Length -gt 1048576) { throw 'Dictionary file exceeds 1 MiB.' }
    $json = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $json -or $json.format -cne 'clipwarp-rightlang-dictionary' -or
        $json.schema -ne 1 -or $json.kind -notin @('dictionary','learned') -or
        $null -eq $json.instant) { throw 'Not a supported ClipWarp dictionary export.' }
    $rules = Assert-ClipwarpDictionaryRules $json.instant
    $learning = @($json.learnedKeys)
    if ($learning.Count -gt 1000) { throw 'Too many learned entries.' }
    foreach ($key in $learning) {
        if ($key -isnot [string] -or -not $rules.Contains([string]$key)) { throw 'Learned entry has no matching correction rule.' }
    }
    $words = @()
    if ($json.kind -eq 'dictionary') {
        $words = @($json.words)
        if ($words.Count -gt 2000) { throw 'Too many custom words.' }
        foreach ($word in $words) {
            if ($word -isnot [string] -or [string]::IsNullOrWhiteSpace($word) -or $word.Length -gt 128) {
                throw 'Invalid custom word in imported dictionary.'
            }
        }
    } elseif (@($json.words).Count -gt 0) { throw 'Learned-only backup must not contain custom words.' }
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $added=0; $skipped=0; $learnedAdded=0
    foreach ($key in $rules.Keys) {
        if ($cfg.instant.Contains([string]$key)) { $skipped++; continue }
        if ($cfg.instant.Count -ge 1000) { throw 'Maximum correction count exceeded.' }
        $isLearned = $learning -ccontains [string]$key
        if ($isLearned -and @($cfg.learnedKeys).Count -ge $cfg.learningLimit) {
            $skipped++; continue
        }
        $cfg.instant[[string]$key] = [string]$rules[$key]
        $added++
        if ($isLearned) {
            $cfg.learnedKeys = @(@($cfg.learnedKeys) + @([string]$key) | Select-Object -Unique)
            $learnedAdded++
        }
    }
    if ($json.kind -eq 'dictionary') {
        $cfg.words = @(@($cfg.words) + @($words) | Select-Object -Unique)
    }
    # Only dictionary data changes; never import app allowlists, privacy toggles,
    # autostart, or correction mode. All validation completed before this write.
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return [pscustomobject]@{ Added=$added; Skipped=$skipped; Learned=$learnedAdded; CustomWords=$words.Count; Mode=$cfg.mode; AppPermissionsUnchanged=$true }
}
function Backup-ClipwarpRightLangLearnedWords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Backup directory not found.' }
    $target = Join-Path $Directory ('clipwarp-learned-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
    Export-ClipwarpRightLangDictionary -Path $target -LearnedOnly -ConfigPath $ConfigPath
}
Export-ModuleMember -Function Export-ClipwarpRightLangDictionary,Import-ClipwarpRightLangDictionary,Backup-ClipwarpRightLangLearnedWords
