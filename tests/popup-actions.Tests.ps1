$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-calendar.psm1') -Force
function Check($ok,$name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }
# Compile the actual passive form definition without creating/displaying a window.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp-calendar-popup.ps1'),[ref]$tokens,[ref]$errors)
$definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^public class ClipwarpPassiveForm' },$true))[0].Value
Add-Type -AssemblyName System.Windows.Forms
$refs=@([Windows.Forms.Form].Assembly.Location)
if ($PSVersionTable.PSEdition -eq 'Core') { $refs+=@('System.Runtime','System.ComponentModel.Primitives') }
Add-Type -TypeDefinition $definition -ReferencedAssemblies $refs
Check ($null -ne ('ClipwarpPassiveForm' -as [type])) 'actual nonactivating form compiles without showing UI'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-action-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    Import-Module (Join-Path $root 'clipwarp-support.psm1') -Force
    $owned = Join-Path $temp ('clipwarp-title-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($owned,'owned title')
    Check ((Read-ClipwarpOwnedTitleFile -Path $owned -Directory $temp) -eq 'owned title' -and -not [IO.File]::Exists($owned)) 'owned title consumed and deleted'
    $other = Join-Path $temp 'personal.txt'
    [IO.File]::WriteAllText($other,'private')
    $rejected=$false; try { Read-ClipwarpOwnedTitleFile -Path $other -Directory $temp } catch { $rejected=$true }
    Check ($rejected -and [IO.File]::ReadAllText($other) -eq 'private') 'arbitrary title filename rejected without deletion'
    [IO.File]::WriteAllText($owned,'x' * 1048577)
    $rejected=$false; try { Read-ClipwarpOwnedTitleFile -Path $owned -Directory $temp } catch { $rejected=$true }
    Check ($rejected -and [IO.File]::Exists($owned)) 'oversized title rejected without deletion'
    $nested=Join-Path $temp 'nested'; [void][IO.Directory]::CreateDirectory($nested)
    $outside=Join-Path $nested ([IO.Path]::GetFileName($owned)); [IO.File]::WriteAllText($outside,'private')
    $rejected=$false; try { Read-ClipwarpOwnedTitleFile -Path $outside -Directory $temp } catch { $rejected=$true }
    Check ($rejected -and [IO.File]::Exists($outside)) 'owned-looking name outside exact root rejected'
    & (Get-Module clipwarp-calendar) {
        param($temp, $assertion)
        function Check($ok,$name) { & $assertion $ok $name }
        $first=New-ClipwarpPrivateTransportFile -Text 'first' -Directory $temp
        $second=New-ClipwarpPrivateTransportFile -Text 'second' -Directory $temp
        Check ($first -ne $second) 'exclusive transport filenames never collide'
        $acl=Get-Acl -LiteralPath $first
        Check $acl.AreAccessRulesProtected 'transport DACL does not inherit other principals'
        $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Check ($rules.Count -eq 1 -and $rules[0].IdentityReference -eq [Security.Principal.WindowsIdentity]::GetCurrent().User) 'transport grants access only to current user'
        [IO.File]::SetLastWriteTimeUtc($first,[datetime]::UtcNow.AddDays(-2))
        $third=New-ClipwarpPrivateTransportFile -Text 'third' -Directory $temp
        Check (-not (Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath $second)) 'orphan expiry removes only stale managed transport'
    } $temp ${function:Check}
    $snapshot = "# reviewed comment`r`nWrite-Output 'exact'  "
    $info = New-ClipwarpCommandProcessStartInfo -CommandText $snapshot -ReviewedSnapshot -Launcher powershell
    Check ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($info.EncodedCommand)) -ceq $snapshot) 'reviewed snapshot is never cleaned a second time'
    $wrapped = Get-ClipwarpCommandProcessStartInfo -CommandText $snapshot -ReviewedSnapshot -Launcher powershell
    Check ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($wrapped.EncodedCommand)) -ceq $snapshot) 'compatibility wrapper forwards exact reviewed snapshot'
    $state = @{ Text=$null }
    Start-ClipwarpCommand -CommandText $snapshot -ReviewedSnapshot -CommandLookup {$null} -ProcessStarter { param($psi) $state.Text=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($psi.EncodedCommand)); $true }
    Check ($state.Text -ceq $snapshot) 'full launch path preserves exact reviewed snapshot'
    # Inject private temp transport location; never launch a process.
    & (Get-Module clipwarp-calendar) {
        param($temp, $assertion)
        function Check($ok,$name) { & $assertion $ok $name }
        $long="Write-Output '" + ('x'*20000) + "'"
        $oldTemp=$env:TEMP; $oldTmp=$env:TMP
        try {
            $env:TEMP=$temp; $env:TMP=$temp
            $info=New-ClipwarpCommandProcessStartInfo -CommandText $long -Launcher powershell
            Check ($info.Arguments.Length -lt 32767 -and $info.TransportPath) 'long command uses small fixed launcher below Windows limit'
            Check ([IO.File]::ReadAllText($info.TransportPath) -ceq $long) 'transport preserves complete reviewed snapshot'
            $loader=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($info.EncodedCommand))
            Check ($loader.Contains('finally') -and $loader.Contains('expired')) 'launcher deletes transport and refuses expired execution'
            Remove-Item -LiteralPath $info.TransportPath -Force
            $state=@{Path=$null}
            try { Start-ClipwarpCommand -CommandText $long -CommandLookup {$null} -ProcessStarter { param($psi) $state.Path=$psi.TransportPath; throw 'injected failure' } } catch {}
            Check ($state.Path -and -not (Test-Path -LiteralPath $state.Path)) 'launch failure removes only its owned transport'
        } finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp }
    } $temp ${function:Check}
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
