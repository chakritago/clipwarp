$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert($value,$name) { if (-not $value) { throw $name }; Write-Host "PASS: $name" }
$verPath = Join-Path $root 'version.json'
Assert (Test-Path -LiteralPath $verPath) 'version.json exists in repo root'
$ver = Get-Content -LiteralPath $verPath -Raw | ConvertFrom-Json
Assert ($ver.version -match '^\d+\.\d+\.\d+$') 'version is semver'
Assert ($ver.date -match '^\d{4}-\d{2}-\d{2}$') 'date is yyyy-MM-dd'
$install = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
Assert ($install.Contains("'version.json'")) 'install.ps1 ships version.json'
$cli = [IO.File]::ReadAllText((Join-Path $root 'clipwarp.ps1'))
Assert ($cli.Contains("'version'")) 'clipwarp.ps1 ValidateSet includes version'
Assert ($cli.Contains("'version','help'") -or $cli.Contains("'doctor','version'")) 'clipwarp.ps1 dispatches the version command'
Assert ($cli.Contains('Show-ClipwarpVersion')) 'clipwarp.ps1 calls Show-ClipwarpVersion'
$mod = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-support.psm1'))
Assert ($mod.Contains('function Get-ClipwarpVersionInfo')) 'support module has Get-ClipwarpVersionInfo'
Assert ($mod.Contains('function Show-ClipwarpVersion')) 'support module has Show-ClipwarpVersion'
Assert ($mod.Contains('Get-ClipwarpVersionInfo,Show-ClipwarpVersion')) 'version functions are exported'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp-watch.ps1'),[ref]$tokens,[ref]$errors)
$src=$ast.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('namespace ClipwarpWatch')},$true).Value
Assert ($src.Contains('ReadVersionSuffix')) 'watcher logs the installed version at startup'
Assert ($src.Contains('version.json')) 'watcher reads version.json'
$watchPs=[IO.File]::ReadAllText((Join-Path $root 'clipwarp-watch.ps1'))
Assert ($watchPs.Contains('version.json')) 'clipwarp status shows the installed version'
$readme=[IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert ($readme.Contains('clipwarp version')) 'README documents clipwarp version'
Assert ($cli.Contains("'update'")) 'clipwarp.ps1 ValidateSet includes update'
Assert ($cli.Contains("'update','pause'")) 'clipwarp.ps1 dispatches the update command'
Assert ($cli.Contains('Update-Clipwarp -ScriptRoot')) 'clipwarp.ps1 calls Update-Clipwarp'
Assert ($mod.Contains('function Update-Clipwarp')) 'support module has Update-Clipwarp'
Assert ($mod.Contains('Show-ClipwarpVersion,Update-Clipwarp')) 'Update-Clipwarp is exported'
Assert ($mod.Contains('install.ps1') -and $mod.Contains('-CheckOnly')) 'Update-Clipwarp re-runs the installer with check-only mode'
Assert ($watchPs.Contains('Check for updates')) 'tray menu has Check for updates'
Assert ($readme.Contains('clipwarp update')) 'README documents clipwarp update'
$testBytes=[IO.File]::ReadAllBytes($PSCommandPath)
Assert ($testBytes[0] -eq 239 -and $testBytes[1] -eq 187 -and $testBytes[2] -eq 191) 'version tests UTF-8 BOM'
Write-Host 'PASS: version wiring tests; no watcher instantiated'
