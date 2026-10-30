# Verify the public GitHub Pages Copy UI on Windows PowerShell 5.1 and 7.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$html = [IO.File]::ReadAllText((Join-Path $root 'index.html'))
function Assert-WebCopy([bool]$Condition,[string]$Description) {
    if (-not $Condition) { throw "Website Copy: $Description" }
    Write-Host "PASS: $Description"
}
Assert-WebCopy ($html.Contains('id="copyBtn"') -and $html.Contains('id="copyLabel"') -and
    $html.Contains('id="copyHelp"') -and $html.Contains('id="live"')) 'button, label, feedback and accessible live region exist'
Assert-WebCopy ($html.Contains('async function copyInstallerCommand') -and
    $html.Contains('await navigator.clipboard.writeText(text)')) 'Clipboard API is awaited and may fail safely'
Assert-WebCopy ($html.Contains('legacyCopyCommand(text)') -and
    $html.Contains("document.execCommand('copy')===true") -and
    $html.Contains('selectCommandForManualCopy()')) 'fallback and manual copy are wired'
Assert-WebCopy ($html.Contains('aria-describedby="copyHelp"') -and
    $html.Contains('Ctrl+C') -and $html.Contains('คัดลอก')) 'failure guidance is accessible in Thai and English'
Assert-WebCopy ($html.Contains('irm https://raw.githubusercontent.com/chakritago/clipwarp/main/install.ps1 | iex')) 'copy target is the active main installer command'

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host 'NOTE: Node.js not installed; browser simulation skipped. Static checks passed.' -ForegroundColor Yellow
    return
}
& $node.Source (Join-Path $PSScriptRoot 'website-copy.node.cjs')
if ($LASTEXITCODE -ne 0) { throw "Website Copy: simulated browser test failed (exit $LASTEXITCODE)." }
