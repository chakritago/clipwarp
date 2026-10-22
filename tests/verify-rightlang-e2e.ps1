# Verify MANUALLY collected Windows editor evidence. Never runs in CI.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ReportPath,
      [Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference = 'Stop'
if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true') {
    throw 'Physical Windows editor evidence cannot be validated on a CI runner.'
}
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Run on the Windows desktop used for physical E2E.' }
if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { throw 'Manual checklist JSON not found.' }
if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) { throw 'Evidence folder not found.' }
$report=Get-Content -LiteralPath $ReportPath -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $report.RealDesktopGateSatisfied -or -not $report.EditorBridgeEnabled -or
    -not $report.AllConfirmed -or -not $report.AllRequiredApplicationsRunning) {
    throw 'Manual report has NOT passed physical desktop prerequisites.'
}
$scenarios=@($report.Scenarios)
if ($scenarios.Count -lt 18 -or @($scenarios | Where-Object { -not $_.Confirmed }).Count -ne 0) {
    throw 'Some required manual scenarios are missing or not attested.'
}
$apps=@($report.Applications)
foreach ($name in @('notepad','winword','code')) {
    if (@($apps | Where-Object { $_.Application -eq $name -and $_.Running -and
          $_.ProductVersion -and $_.ProductVersion -ne 'not running' }).Count -ne 1) {
        throw "Missing version / running process evidence for $name."
    }
}
# Screenshots should show benign test text only. Their contents are NOT
# transmitted by this script; only hashes and original paths are recorded.
$required=@('notepad.png','word.png','vscode.png','clipboard.png','undo.png')
$artifacts=@()
foreach ($name in $required) {
    $file=Join-Path $EvidenceDirectory $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing manual screenshot $name" }
    $item=Get-Item -LiteralPath $file
    if ($item.Length -lt 100 -or $item.Length -gt 10485760) {
        throw "Evidence image size not credible or too large: $name"
    }
    $bytes=[IO.File]::ReadAllBytes($file)
    if ($bytes.Length -lt 8 -or $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or
        $bytes[2] -ne 78 -or $bytes[3] -ne 71) {
        throw "Expected a real PNG file: $name"
    }
    $artifacts += [pscustomobject]@{
        FileName=$name
        SHA256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        SizeBytes=$item.Length
    }
}
$audit=[pscustomobject]@{
    Schema=1
    Validation='Manual desktop attestation with screenshot hashes; NOT automated keyboard E2E'
    VerifiedAt=(Get-Date).ToUniversalTime().ToString('o')
    PhysicalScenarios=$scenarios.Count
    Applications=$apps
    Screenshots=$artifacts
    InstallerVerified=$false
    StableReleaseApproved=$false
}
$dest=Join-Path $EvidenceDirectory ('clipwarp-e2e-audit-'+[guid]::NewGuid().ToString('N')+'.json')
[IO.File]::WriteAllText($dest,($audit|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($false)))
Write-Host "MANUAL E2E EVIDENCE COLLECTED: $($scenarios.Count) scenarios and $($artifacts.Count) PNG hashes"
Write-Host "Audit: $dest"
Write-Host 'Stable release remains blocked until a reviewer checks the benign screenshots, Undo and Word formatting manually.'
