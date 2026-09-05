$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$powershellFiles = @(Get-ChildItem -LiteralPath $root -File | Where-Object Extension -in @('.ps1','.psm1')) + @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')
foreach ($file in $powershellFiles) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed for $($file.Name): $($errors[0].Message)" }
}
Write-Host "PASS: parsed $($powershellFiles.Count) PowerShell files"

Add-Type -AssemblyName System.Windows.Forms
function Get-HereStringValue([string]$Path, [string]$Contains) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains($Contains) }, $true)
    if (-not $node) { throw "Embedded C# containing '$Contains' not found in $Path" }
    $node.Value
}

$watchSource = Get-HereStringValue (Join-Path $root 'clipwarp-watch.ps1') 'namespace ClipwarpWatch'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $references = @([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
    $references += [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
    Add-Type -TypeDefinition $watchSource -ReferencedAssemblies ($references | Select-Object -Unique)
} else { Add-Type -TypeDefinition $watchSource -ReferencedAssemblies @('System','System.Windows.Forms','System.Drawing') }
Write-Host 'PASS: compiled watcher C#'

$popupSource = Get-HereStringValue (Join-Path $root 'clipwarp-calendar-popup.ps1') 'public static class ClipwarpPopupNative'
Add-Type -TypeDefinition $popupSource
Write-Host 'PASS: compiled popup C#'

$clipSource = Get-HereStringValue (Join-Path $root 'clipwarp.ps1') 'public static extern uint GetClipboardSequenceNumber'
Add-Type -Namespace ('ClipwarpCompat' + [guid]::NewGuid().ToString('N')) -Name Clip -MemberDefinition $clipSource
$dibSource = Get-HereStringValue (Join-Path $root 'clipwarp.ps1') 'public static byte[] DecodeMasked'
Add-Type -Namespace ('ClipwarpCompat' + [guid]::NewGuid().ToString('N')) -Name Dib -MemberDefinition $dibSource
Write-Host 'PASS: compiled conversion helper C#'
