<# Generate at release packaging time, after all release files are finalized. A checksum is not a signature. #>
[CmdletBinding()]
param([string]$SourceRoot=$PSScriptRoot,[string]$Commit,[string]$OutputPath)
$ErrorActionPreference='Stop'
$sourceArgument=$SourceRoot; $commitArgument=$Commit; $outputArgument=$OutputPath
. (Join-Path $PSScriptRoot 'install.ps1') -LibraryOnly
$SourceRoot=$sourceArgument; $Commit=$commitArgument; $OutputPath=$outputArgument
if (-not $Commit) { try { $Commit=(& git -C $SourceRoot rev-parse HEAD 2>$null | Select-Object -First 1) } catch { $Commit=$null } }
if ($Commit -and $Commit -notmatch '^[a-fA-F0-9]{40}$') { throw 'Commit must be a full commit SHA.' }
if (-not $OutputPath) { $OutputPath=Join-Path $SourceRoot 'release-manifest.json' }
$manifest=New-ClipwarpReleaseManifest $SourceRoot $Commit
Write-ClipwarpAtomicText $OutputPath ($manifest | ConvertTo-Json -Depth 8)
Write-Output $OutputPath
