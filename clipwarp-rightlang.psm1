# ClipWarp's independent, privacy-scoped language correction preferences.
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force

function Get-ClipwarpRightLangDefaults {
    [pscustomobject]@{
        mode = 'manual'
        instant = [ordered]@{ 'l;ylfu' = 'สวัสดี'; '-v[86I' = 'ขอบคุณ'; '้ำสสน' = 'hello' }
        words = @('สวัสดี', 'ขอบคุณ', 'ครับ', 'ค่ะ', 'วันนี้', 'ไปมา', 'hello', 'twitter', 'correct')
        allowedApps = @('notepad')
        blockedApps = @('keepass', 'keepassxc', 'bitwarden', '1password', 'lastpass', 'putty',
                        'windowsterminal', 'powershell', 'pwsh', 'cmd', 'conhost')
        editorBridgeEnabled = $false
        learnAccepted = $false
        darkMode = $false
        highContrast = $false
        uiFontSize = 11
        editorFontSize = 12
        previewFontSize = 12
        appPolicies = [ordered]@{}
        smartSuggestions = $false
        suggestionDelayMs = 650
        suggestionCooldownMs = 5000
        ignoredSuggestions = @()
        learningLimit = 200
        undoHistory = $false
        learnedKeys = @()
    }
}

function Get-ClipwarpRightLangBoundedInt {
    param($Value, [int]$Minimum, [int]$Maximum, [int]$Fallback)
    $number = 0
    if ([int]::TryParse([string]$Value, [ref]$number) -and $number -ge $Minimum -and $number -le $Maximum) {
        return $number
    }
    return $Fallback
}

function Get-ClipwarpRightLangAppPolicies {
    param($Rules)
    $result = [ordered]@{}
    if ($null -eq $Rules) { return $result }
    $entries = @()
    if ($Rules -is [System.Collections.IDictionary]) {
        foreach ($key in $Rules.Keys) { $entries += [pscustomobject]@{ Key=[string]$key; Value=[string]$Rules[$key] } }
    } else {
        foreach ($p in $Rules.PSObject.Properties) {
            if ($p.MemberType -eq 'NoteProperty') { $entries += [pscustomobject]@{ Key=[string]$p.Name; Value=[string]$p.Value } }
        }
    }
    foreach ($entry in $entries) {
        $name = $entry.Key.Trim().ToLowerInvariant() -replace '\.exe$',''
        $rule = $entry.Value.Trim().ToLowerInvariant()
        if ($name -notmatch '^[a-z0-9_\- ]{1,64}$') { throw "Invalid application policy process: $name" }
        if ($rule -notmatch '^(inherit|manual|auto|off),(inherit|on|off)$') { throw "Invalid application policy: $rule" }
        $result[$name] = $rule
        if ($result.Count -gt 100) { throw 'Too many application policies.' }
    }
    return $result
}

function Get-ClipwarpRightLangConfig {
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $defaults = Get-ClipwarpRightLangDefaults
    $raw = Get-ClipwarpConfig -ConfigPath $ConfigPath
    $rl = $raw.rightlang
    if ($null -eq $rl) { return $defaults }
    $instant = [ordered]@{}
    if ($null -ne $rl.instant) {
        if ($rl.instant -is [System.Collections.IDictionary]) {
            foreach ($key in $rl.instant.Keys) { $instant[[string]$key] = [string]$rl.instant[$key] }
        } else {
            foreach ($prop in $rl.instant.PSObject.Properties) {
                if ($prop.MemberType -eq 'NoteProperty') { $instant[[string]$prop.Name] = [string]$prop.Value }
            }
        }
    } else {
        $instant = $defaults.instant
    }
    $words = if ($null -ne $rl.words) { @($rl.words | Where-Object { $_ -is [string] }) } else { $defaults.words }
    $allowed = if ($null -ne $rl.allowedApps) { @($rl.allowedApps | Where-Object { $_ -is [string] }) } else { $defaults.allowedApps }
    $blocked = if ($null -ne $rl.blockedApps) { @($rl.blockedApps | Where-Object { $_ -is [string] }) } else { $defaults.blockedApps }
    $keys = @($rl.learnedKeys | Where-Object { $_ -is [string] -and $instant.Contains($_) } | Select-Object -Unique)
    [pscustomobject]@{
        mode = if ($rl.mode -in @('manual', 'auto', 'off')) { [string]$rl.mode } else { 'manual' }
        instant = $instant
        words = @($words)
        allowedApps = @($allowed)
        blockedApps = @($blocked)
        editorBridgeEnabled = ($rl.editorBridgeEnabled -is [bool] -and $rl.editorBridgeEnabled)
        learnAccepted = ($rl.learnAccepted -is [bool] -and $rl.learnAccepted)
        darkMode = ($rl.darkMode -is [bool] -and $rl.darkMode)
        highContrast = ($rl.highContrast -is [bool] -and $rl.highContrast)
        uiFontSize = Get-ClipwarpRightLangBoundedInt $rl.uiFontSize 10 18 11
        editorFontSize = Get-ClipwarpRightLangBoundedInt $rl.editorFontSize 10 24 12
        previewFontSize = Get-ClipwarpRightLangBoundedInt $rl.previewFontSize 10 24 12
        appPolicies = Get-ClipwarpRightLangAppPolicies $rl.appPolicies
        smartSuggestions = ($rl.smartSuggestions -is [bool] -and $rl.smartSuggestions)
        suggestionDelayMs = Get-ClipwarpRightLangBoundedInt $rl.suggestionDelayMs 350 2000 650
        suggestionCooldownMs = Get-ClipwarpRightLangBoundedInt $rl.suggestionCooldownMs 500 120000 5000
        ignoredSuggestions = @($rl.ignoredSuggestions | Where-Object {
            $_ -is [string] -and $_.Length -ge 2 -and $_.Length -le 64 -and $_.Trim()
        } | Select-Object -Unique)
        learningLimit = Get-ClipwarpRightLangBoundedInt $rl.learningLimit 10 500 200
        undoHistory = ($rl.undoHistory -is [bool] -and $rl.undoHistory)
        learnedKeys = $keys
    }
}

function Save-ClipwarpRightLangConfig {
    param([Parameter(Mandatory=$true)]$Settings,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    if ($Settings.mode -notin @('manual','auto','off')) { throw 'Invalid RightLang mode.' }
    $rules = [ordered]@{}
    if ($Settings.instant -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.instant.Keys) {
            $name = [string]$key
            $value = [string]$Settings.instant[$key]
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) { continue }
            if ($name.Length -gt 64 -or $value.Length -gt 128) { throw 'Correction rule too long.' }
            $rules[$name] = $value
            if ($rules.Count -gt 1000) { throw 'Too many correction rules.' }
        }
    }
    $normalized = [ordered]@{
        mode = [string]$Settings.mode
        instant = $rules
        editorBridgeEnabled = [bool]$Settings.editorBridgeEnabled
        learnAccepted = [bool]$Settings.learnAccepted
        darkMode = [bool]$Settings.darkMode
        highContrast = [bool]$Settings.highContrast
        smartSuggestions = [bool]$Settings.smartSuggestions
        appPolicies = Get-ClipwarpRightLangAppPolicies $Settings.appPolicies
        undoHistory = [bool]$Settings.undoHistory
    }
    foreach ($field in @('uiFontSize','editorFontSize','previewFontSize','suggestionDelayMs','suggestionCooldownMs','learningLimit')) {
        $bounds = switch ($field) {
            'uiFontSize' { @(10,18,11) }
            'editorFontSize' { @(10,24,12) }
            'previewFontSize' { @(10,24,12) }
            'suggestionDelayMs' { @(350,2000,650) }
            'suggestionCooldownMs' { @(500,120000,5000) }
            'learningLimit' { @(10,500,200) }
        }
        $normalized[$field] = Get-ClipwarpRightLangBoundedInt $Settings.$field $bounds[0] $bounds[1] $bounds[2]
    }
    $ignored = @($Settings.ignoredSuggestions | Where-Object {
        $_ -is [string] -and $_.Length -ge 2 -and $_.Length -le 64 -and $_.Trim()
    } | Select-Object -Unique)
    if ($ignored.Count -gt 1000) { throw 'Too many ignored suggestions.' }
    $normalized['ignoredSuggestions'] = @($ignored)
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
    param([Parameter(Mandatory=$true)][ValidateSet('manual','auto','off')][string]$Mode,
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
    if (-not $cfg.learnAccepted -or $cfg.ignoredSuggestions -contains $Typed) { return $false }
    if ($Typed.Length -lt 2 -or $Typed.Length -gt 64 -or
        $Corrected.Length -lt 2 -or $Corrected.Length -gt 128 -or $Typed -ceq $Corrected) { return $false }
    if ($cfg.instant.Count -ge 1000 -and -not $cfg.instant.Contains($Typed)) { return $false }
    if (@($cfg.learnedKeys).Count -ge $cfg.learningLimit -and $cfg.learnedKeys -notcontains $Typed) { return $false }
    if ($cfg.instant.Contains($Typed) -and $cfg.learnedKeys -notcontains $Typed) {
        return ($cfg.instant[$Typed] -ceq $Corrected)
    }
    $cfg.instant[$Typed] = $Corrected
    $cfg.learnedKeys = @(@($cfg.learnedKeys) + @($Typed) | Select-Object -Unique)
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

function Add-ClipwarpRightLangIgnoredSuggestion {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Word,
          [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    if ($Word.Length -lt 2 -or $Word.Length -gt 64 -or [string]::IsNullOrWhiteSpace($Word)) { return $false }
    $cfg = Get-ClipwarpRightLangConfig -ConfigPath $ConfigPath
    if ($cfg.ignoredSuggestions -contains $Word) { return $true }
    if (@($cfg.ignoredSuggestions).Count -ge 1000) { return $false }
    $cfg.ignoredSuggestions = @(@($cfg.ignoredSuggestions) + @($Word) | Select-Object -Unique)
    [void](Save-ClipwarpRightLangConfig -Settings $cfg -ConfigPath $ConfigPath)
    return $true
}

Export-ModuleMember -Function Get-ClipwarpRightLangDefaults,Get-ClipwarpRightLangConfig,Save-ClipwarpRightLangConfig,Set-ClipwarpRightLangMode,Add-ClipwarpRightLangLearnedWord,Remove-ClipwarpRightLangLearnedWord,Clear-ClipwarpRightLangLearnedWords,Add-ClipwarpRightLangIgnoredSuggestion
