# Independent RightLang-inspired configuration; no changes to clipboard history or publishing.
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force

function Get-ClipwarpRightLangDefaults {
    [pscustomobject]@{
        mode = 'manual'
        instant = [ordered]@{ 'l;ylfu' = 'สวัสดี'; '-v[86I' = 'ขอบคุณ'; '้ำสสน' = 'hello' }
        words = @('สวัสดี', 'ขอบคุณ', 'ครับ', 'ค่ะ', 'วันนี้', 'ไปมา', 'hello', 'twitter', 'correct')
        allowedApps = @('notepad')
        editorBridgeEnabled = $false
        learnAccepted = $false
        darkMode = $false
        smartSuggestions = $false
        suggestionDelayMs = 650
        suggestionCooldownMs = 5000
        ignoredSuggestions = @()
        learningLimit = 200
        undoHistory = $false
        learnedKeys = @()
        blockedApps = @('keepass', 'keepassxc', 'bitwarden', '1password', 'lastpass', 'putty',
            'windowsterminal', 'powershell', 'pwsh', 'cmd', 'conhost')
    }
}

function Get-ClipwarpRightLangConfig {
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $defaults = Get-ClipwarpRightLangDefaults
    $config = Get-ClipwarpConfig -ConfigPath $ConfigPath
    $rl = $config.rightlang
    if ($null -eq $rl) { return $defaults }
    $mode = if ($rl.mode -in @('auto', 'manual', 'off')) { [string]$rl.mode } else { 'manual' }
    $instant = [ordered]@{}
    if ($null -ne $rl.instant) {
        if ($rl.instant -is [System.Collections.IDictionary]) {
            foreach ($key in $rl.instant.Keys) { $instant[[string]$key] = [string]$rl.instant[$key] }
        } else {
            foreach ($prop in $rl.instant.PSObject.Properties) {
                if ($prop.MemberType -eq 'NoteProperty') { $instant[[string]$prop.Name] = [string]$prop.Value }
            }
        }
    } else { $instant = $defaults.instant }
    $words = if ($null -ne $rl.words) { @($rl.words | Where-Object { $_ -is [string] }) } else { $defaults.words }
    $allowed = if ($null -ne $rl.allowedApps) { @($rl.allowedApps | Where-Object { $_ -is [string] }) } else { $defaults.allowedApps }
    $blocked = if ($null -ne $rl.blockedApps) { @($rl.blockedApps | Where-Object { $_ -is [string] }) } else { $defaults.blockedApps }
    [pscustomobject]@{
        mode = $mode
        instant = $instant
        words = @($words)
        allowedApps = @($allowed)
        blockedApps = @($blocked)
        editorBridgeEnabled = ($rl.editorBridgeEnabled -is [bool] -and $rl.editorBridgeEnabled)
        learnAccepted = ($rl.learnAccepted -is [bool] -and $rl.learnAccepted)
        darkMode = ($rl.darkMode -is [bool] -and $rl.darkMode)
        smartSuggestions = ($rl.smartSuggestions -is [bool] -and $rl.smartSuggestions)
        suggestionDelayMs = if ($rl.suggestionDelayMs -ge 350 -and $rl.suggestionDelayMs -le 2000) { [int]$rl.suggestionDelayMs } else { 650 }
        suggestionCooldownMs = if ($rl.suggestionCooldownMs -ge 500 -and $rl.suggestionCooldownMs -le 120000) { [int]$rl.suggestionCooldownMs } else { 5000 }
        ignoredSuggestions = @($rl.ignoredSuggestions | Where-Object { $_ -is [string] -and $_.Length -le 64 -and $_.Trim() } | Select-Object -Unique)
        learningLimit = if ($rl.learningLimit -ge 10 -and $rl.learningLimit -le 500) { [int]$rl.learningLimit } else { 200 }
        undoHistory = ($rl.undoHistory -is [bool] -and $rl.undoHistory)
        learnedKeys = @($rl.learnedKeys | Where-Object { $_ -is [string] -and $instant.Contains($_) } | Select-Object -Unique)
    }
}

function Save-ClipwarpRightLangConfig {
    param([Parameter(Mandatory=$true)]$Settings,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    if ($Settings.mode -notin @('auto','manual','off')) { throw 'Invalid RightLang mode.' }
    $rules = [ordered]@{}
    if ($Settings.instant -is [System.Collections.IDictionary]) {
        foreach ($name in $Settings.instant.Keys) {
            $value = [string]$Settings.instant[$name]
            if ([string]::IsNullOrWhiteSpace([string]$name) -or [string]::IsNullOrWhiteSpace($value)) { continue }
            if (([string]$name).Length -gt 64 -or $value.Length -gt 128) { throw 'Correction rule too long.' }
            $rules[[string]$name] = $value
            if ($rules.Count -gt 1000) { throw 'Too many correction rules.' }
        }
    }
    $normalized = [ordered]@{
        mode = [string]$Settings.mode
        instant = $rules
        editorBridgeEnabled = [bool]$Settings.editorBridgeEnabled
        learnAccepted = [bool]$Settings.learnAccepted
        darkMode = [bool]$Settings.darkMode
        smartSuggestions = [bool]$Settings.smartSuggestions
        suggestionDelayMs = 650
        suggestionCooldownMs = 5000
        learningLimit = 200
        undoHistory = [bool]$Settings.undoHistory
    }
    foreach ($setting in @(
        @{ Name = 'suggestionDelayMs'; Min = 350; Max = 2000 },
        @{ Name = 'suggestionCooldownMs'; Min = 500; Max = 120000 },
        @{ Name = 'learningLimit'; Min = 10; Max = 500 }
    )) {
        $val = $Settings.($setting.Name)
        if ($null -ne $val -and [string]$val -match '^\d+ | Where-Object {
        $_ -is [string] -and $rules.Contains($_)
    } | Select-Object -Unique)
    foreach ($field in @('words','allowedApps','blockedApps')) {
        $values = @($Settings.$field | Where-Object { $_ -is [string] -and $_.Trim() })
        if ($values.Count -gt 2000) { throw "Too many $field entries." }
        if ($field -in @('allowedApps','blockedApps')) {
            $values = @($values | ForEach-Object { $_.Trim().ToLowerInvariant() -replace '\.exe$', '' } | Select-Object -Unique)
        }
        $normalized[$field] = $values
    }
    $config = Get-ClipwarpConfig -ConfigPath $ConfigPath
    $config | Add-Member -NotePropertyName rightlang -NotePropertyValue ([pscustomobject]$normalized) -Force
    Save-ClipwarpConfig -Config $config -ConfigPath $ConfigPath
    Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
}

function Set-ClipwarpRightLangMode {
    param([Parameter(Mandatory=$true)][ValidateSet('auto','manual','off')][string]$Mode,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $settings = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $settings.mode = $Mode
    [void](Save-ClipwarpRightLangConfig -Settings $settings -ConfigPath $ConfigPath)
    $Mode
}

function Add-ClipwarpRightLangLearnedWord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Typed,
          [Parameter(Mandatory=$true)][string]$Corrected,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    if (-not $cfg.learnAccepted) { return $false }
    if ($Typed.Length -lt 2 -or $Typed.Length -gt 64 -or
        $Corrected.Length -lt 2 -or $Corrected.Length -gt 128 -or $Typed -ceq $Corrected) { return $false }
    if ($cfg.ignoredSuggestions -contains $Typed) { return $false }
    if ($cfg.instant.Count -ge 1000 -and -not $cfg.instant.Contains($Typed)) { return $false }
    if ($cfg.learnedKeys.Count -ge $cfg.learningLimit -and $cfg.learnedKeys -notcontains $Typed) { return $false }
    if ($cfg.instant.Contains($Typed) -and ($cfg.learnedKeys -notcontains $Typed)) {
        # Never overwrite or reclassify a user-authored instant rule.
        return ($cfg.instant[$Typed] -ceq $Corrected)
    }
    $cfg.instant[$Typed] = $Corrected
    $cfg.learnedKeys = @($cfg.learnedKeys) + @($Typed) | Select-Object -Unique
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $true
}
function Remove-ClipwarpRightLangLearnedWord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Typed,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    if ($cfg.learnedKeys -notcontains $Typed) { return $false }
    [void]$cfg.instant.Remove($Typed)
    $cfg.learnedKeys = @($cfg.learnedKeys | Where-Object { $_ -cne $Typed })
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $true
}

function Clear-ClipwarpRightLangLearnedWords {
    [CmdletBinding()]
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $count = @($cfg.learnedKeys).Count
    foreach ($key in @($cfg.learnedKeys)) { [void]$cfg.instant.Remove([string]$key) }
    $cfg.learnedKeys = @()
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $count
}
Export-ModuleMember -Function Get-ClipwarpRightLangDefaults,Get-ClipwarpRightLangConfig,Save-ClipwarpRightLangConfig,Set-ClipwarpRightLangMode,Add-ClipwarpRightLangLearnedWord,Remove-ClipwarpRightLangLearnedWord,Clear-ClipwarpRightLangLearnedWords
 -and
            [int]$val -ge $setting.Min -and [int]$val -le $setting.Max) {
            $normalized[$setting.Name] = [int]$val
        }
    }
    $ignored = @($Settings.ignoredSuggestions | Where-Object {
        $_ -is [string] -and $_.Length -ge 2 -and $_.Length -le 64 -and $_.Trim()
    } | Select-Object -Unique)
    if ($ignored.Count -gt 1000) { throw 'Too many ignored suggestions.' }
    $normalized['ignoredSuggestions'] = $ignored
    $normalized['learnedKeys'] = @($Settings.learnedKeys | Where-Object {
        $_ -is [string] -and $rules.Contains($_)
    } | Select-Object -Unique)
    foreach ($field in @('words','allowedApps','blockedApps')) {
        $values = @($Settings.$field | Where-Object { $_ -is [string] -and $_.Trim() })
        if ($values.Count -gt 2000) { throw "Too many $field entries." }
        if ($field -in @('allowedApps','blockedApps')) {
            $values = @($values | ForEach-Object { $_.Trim().ToLowerInvariant() -replace '\.exe$', '' } | Select-Object -Unique)
        }
        $normalized[$field] = $values
    }
    $config = Get-ClipwarpConfig -ConfigPath $ConfigPath
    $config | Add-Member -NotePropertyName rightlang -NotePropertyValue ([pscustomobject]$normalized) -Force
    Save-ClipwarpConfig -Config $config -ConfigPath $ConfigPath
    Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
}

function Set-ClipwarpRightLangMode {
    param([Parameter(Mandatory=$true)][ValidateSet('auto','manual','off')][string]$Mode,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $settings = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $settings.mode = $Mode
    [void](Save-ClipwarpRightLangConfig -Settings $settings -ConfigPath $ConfigPath)
    $Mode
}

function Add-ClipwarpRightLangLearnedWord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Typed,
          [Parameter(Mandatory=$true)][string]$Corrected,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    if (-not $cfg.learnAccepted) { return $false }
    if ($Typed.Length -lt 2 -or $Typed.Length -gt 64 -or
        $Corrected.Length -lt 2 -or $Corrected.Length -gt 128 -or $Typed -ceq $Corrected) { return $false }
    if ($cfg.instant.Count -ge 1000 -and -not $cfg.instant.Contains($Typed)) { return $false }
    if ($cfg.instant.Contains($Typed) -and ($cfg.learnedKeys -notcontains $Typed)) {
        # A user-authored instant rule must never be silently reclassified.
        if ($cfg.instant[$Typed] -ceq $Corrected) { return $true }
    }
    $cfg.instant[$Typed] = $Corrected
    $cfg.learnedKeys = @($cfg.learnedKeys) + @($Typed) | Select-Object -Unique
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $true
}
function Remove-ClipwarpRightLangLearnedWord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Typed,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    if ($cfg.learnedKeys -notcontains $Typed) { return $false }
    [void]$cfg.instant.Remove($Typed)
    $cfg.learnedKeys = @($cfg.learnedKeys | Where-Object { $_ -cne $Typed })
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $true
}

function Clear-ClipwarpRightLangLearnedWords {
    [CmdletBinding()]
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    $count = @($cfg.learnedKeys).Count
    foreach ($key in @($cfg.learnedKeys)) { [void]$cfg.instant.Remove([string]$key) }
    $cfg.learnedKeys = @()
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $count
}
Export-ModuleMember -Function Get-ClipwarpRightLangDefaults,Get-ClipwarpRightLangConfig,Save-ClipwarpRightLangConfig,Set-ClipwarpRightLangMode,Add-ClipwarpRightLangLearnedWord,Remove-ClipwarpRightLangLearnedWord,Clear-ClipwarpRightLangLearnedWords
