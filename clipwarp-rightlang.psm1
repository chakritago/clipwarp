# Independent RightLang-inspired configuration; no changes to clipboard history or publishing.
Import-Module (Join-Path $PSScriptRoot 'clipwarp-support.psm1') -Force

function Get-ClipwarpRightLangDefaults {
    [pscustomobject]@{
        mode = 'manual'
        instant = [ordered]@{ 'l;ylfu' = 'สวัสดี'; '-v[86I' = 'ขอบคุณ'; '้ำสสน' = 'hello' }
        words = @('สวัสดี', 'ขอบคุณ', 'ครับ', 'ค่ะ', 'วันนี้', 'ไปมา', 'hello', 'twitter', 'correct')
        allowedApps = @('notepad', 'winword')
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
            if ([string]$name.Length -gt 64 -or $value.Length -gt 128) { throw 'Correction rule too long.' }
            $rules[[string]$name] = $value
            if ($rules.Count -gt 1000) { throw 'Too many correction rules.' }
        }
    }
    $normalized = [ordered]@{ mode = [string]$Settings.mode; instant = $rules }
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

Export-ModuleMember -Function Get-ClipwarpRightLangDefaults,Get-ClipwarpRightLangConfig,Save-ClipwarpRightLangConfig,Set-ClipwarpRightLangMode
