$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp-watch.ps1'),[ref]$tokens,[ref]$errors)
$src=$ast.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('namespace ClipwarpWatch')},$true).Value
function Assert($value,$name) { if (-not $value) { throw $name }; Write-Host "PASS: $name" }
Assert ($src.Contains('public sealed class ClipboardBurstGuard')) 'burst guard exists'
Add-Type -AssemblyName System.Windows.Forms
$compile=$src+[IO.File]::ReadAllText((Join-Path $root 'clipwarp-clipboard.cs'))
if ($PSVersionTable.PSEdition -eq 'Core') {
    $refs=@(Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
    $refs+=@([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
    $refs+=[AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
    Add-Type -TypeDefinition $compile -ReferencedAssemblies ($refs | Group-Object {[IO.Path]::GetFileName($_)} | ForEach-Object {$_.Group[0]})
} else { Add-Type -TypeDefinition $compile -ReferencedAssemblies System,System.Windows.Forms,System.Drawing }
$Allow=[ClipwarpWatch.ClipboardBurstGuard+Verdict]::Allow
$Suppress=[ClipwarpWatch.ClipboardBurstGuard+Verdict]::SuppressBurst
$Pause=[ClipwarpWatch.ClipboardBurstGuard+Verdict]::PauseStorm
Assert ([ClipwarpWatch.ClipboardBurstGuard]::BurstThreshold -eq 5) 'burst threshold is 5'
Assert ([ClipwarpWatch.ClipboardBurstGuard]::BurstWindowMs -eq 60000) 'burst window is 60s'
Assert ([ClipwarpWatch.ClipboardBurstGuard]::BurstCooldownMs -eq 120000) 'burst cooldown is 2 minutes'
Assert ([ClipwarpWatch.ClipboardBurstGuard]::StormThreshold -eq 30) 'storm threshold is 30 events'
Assert ([ClipwarpWatch.ClipboardBurstGuard]::StormWindowMs -eq 10000) 'storm window is 10s'
Assert ([ClipwarpWatch.ClipboardBurstGuard]::StormCooldownMs -eq 30000) 'storm cooldown is 30s'
$g=New-Object ClipwarpWatch.ClipboardBurstGuard
1..4 | ForEach-Object { Assert ($g.Observe('fp-a', ($_*1000)) -eq $Allow) "identical copy $_ of 4 allowed" }
Assert ($g.Observe('fp-a', 5000) -eq $Suppress) '5th identical copy trips the burst'
Assert ($g.Observe('fp-a', 60000) -eq $Suppress) 'still suppressed inside the cooldown'
Assert ($g.Observe('fp-b', 60000) -eq $Allow) 'a different fingerprint is unaffected'
Assert ($g.Observe('fp-a', 125001) -eq $Allow) 'allowed again after the 2-minute cooldown'
$g2=New-Object ClipwarpWatch.ClipboardBurstGuard
Assert ($g2.Observe('x', 0) -eq $Allow) 'first hit allowed'
Assert ($g2.Observe('x', 61000) -eq $Allow) 'hits outside the 60s window do not accumulate'
1..3 | ForEach-Object { Assert ($g2.Observe('x', (61000+($_*1000))) -eq $Allow) "windowed hit $_ allowed" }
Assert ($g2.Observe('x', 65000) -eq $Suppress) '5 hits inside the window trip the burst'
$g3=New-Object ClipwarpWatch.ClipboardBurstGuard
1..29 | ForEach-Object { Assert ($g3.Observe($null, ($_*100)) -eq $Allow) "storm event $_ of 29 allowed" }
Assert ($g3.Observe($null, 3000) -eq $Pause) '30th event in 10s trips the storm pause'
Assert ($g3.Observe('anything', 20000) -eq $Pause) 'paused during the 30s cooldown'
Assert ($g3.Observe($null, 34000) -eq $Allow) 'resumes after the storm cooldown'
$g4=New-Object ClipwarpWatch.ClipboardBurstGuard
1..10 | ForEach-Object { Assert ($g4.Observe($null, ($_*1000)) -eq $Allow) 'null fingerprints never trip a burst' }
$f1=[ClipwarpWatch.ClipboardBurstGuard]::FingerprintText('hello')
$f2=[ClipwarpWatch.ClipboardBurstGuard]::FingerprintText('hello')
Assert ($f1 -eq $f2 -and $f1.StartsWith('T:')) 'text fingerprint is deterministic'
Assert ([ClipwarpWatch.ClipboardBurstGuard]::FingerprintText('hello ') -ne $f1) 'text fingerprint distinguishes content'
Assert ($null -eq [ClipwarpWatch.ClipboardBurstGuard]::FingerprintText('')) 'empty text has no fingerprint'
Assert ($null -eq [ClipwarpWatch.ClipboardBurstGuard]::FingerprintText($null)) 'null text has no fingerprint'
$b1=[ClipwarpWatch.ClipboardBurstGuard]::FingerprintBytes([byte[]](1,2,3))
$b2=[ClipwarpWatch.ClipboardBurstGuard]::FingerprintBytes([byte[]](1,2,3))
Assert ($b1 -eq $b2 -and $b1.StartsWith('I:')) 'byte fingerprint is deterministic'
$pad=New-Object byte[] 70000
$pad2=New-Object byte[] 70001
Assert ([ClipwarpWatch.ClipboardBurstGuard]::FingerprintBytes($pad) -ne [ClipwarpWatch.ClipboardBurstGuard]::FingerprintBytes($pad2)) 'length is mixed into the byte fingerprint'
Assert ($null -eq [ClipwarpWatch.ClipboardBurstGuard]::FingerprintBytes($null)) 'null bytes have no fingerprint'
Assert ($null -eq [ClipwarpWatch.ClipboardBurstGuard]::FingerprintBytes([byte[]]@())) 'empty bytes have no fingerprint'
foreach($contract in @('burstGuard.Observe','FingerprintClipboard','BurstGuardEnabled','"burstGuard"','ClipboardBurstGuard.Verdict.SuppressBurst','ClipboardBurstGuard.Verdict.PauseStorm','convFails = 0; lastContentFingerprint = contentFp')) {
    Assert ($src.Contains($contract)) "source contract: $contract"
}
$readme=[IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert ($readme.Contains('burst') -and $readme.Contains('burstGuard')) 'README documents the burst guard'
$bytes=[IO.File]::ReadAllBytes((Join-Path $root 'clipwarp-watch.ps1'))
Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'watcher UTF-8 BOM preserved'
$testBytes=[IO.File]::ReadAllBytes($PSCommandPath)
Assert ($testBytes[0] -eq 239 -and $testBytes[1] -eq 187 -and $testBytes[2] -eq 191) 'burst tests UTF-8 BOM'
Write-Host 'PASS: fake-only burst tests; no watcher instantiated'
