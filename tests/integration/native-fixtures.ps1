[CmdletBinding()]
param(
    [switch]$EnableNativeIntegration,
    [ValidateSet('ClipboardRoundTrip','ClipboardRace','FilePicker','ControlledBrowser')][string[]]$Scenario = @('ClipboardRoundTrip','ClipboardRace'),
    [string]$ResultsPath
)
$ErrorActionPreference = 'Stop'
# Never called by run-all/CI. The switch AND a human confirmation are required.
# This is destructive to current clipboard state; restoring an arbitrary old
# IDataObject could overwrite a newer copy and is deliberately not attempted.
if (-not $EnableNativeIntegration) { throw 'Native fixtures are disabled. Use -EnableNativeIntegration only in a disposable interactive Windows session.' }
if ($env:CLIPWARP_TEST_NONINTERACTIVE -eq '1' -or $env:CI -or -not [Environment]::UserInteractive) { throw 'Native fixtures cannot run in CI or the unit runner.' }
if ($env:OS -ne 'Windows_NT' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with powershell.exe/pwsh.exe -STA in an interactive Windows desktop.' }
if ((Read-Host 'This may replace your clipboard, show a file picker and open a local browser page. Use a disposable session with ClipWarp stopped. Type RUN NATIVE FIXTURES') -cne 'RUN NATIVE FIXTURES') { throw 'Cancelled; no native actions performed.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$references = @('System.Windows.Forms','System.Drawing')
if ($PSVersionTable.PSEdition -eq 'Core') {
    $references = @('System.Windows.Forms','System.Drawing.Common','System.Drawing.Primitives','System.Runtime','System.Runtime.InteropServices','System.Collections','System.ComponentModel.Primitives')
}
Add-Type -Path (Join-Path $repo 'clipwarp-clipboard.cs') -ReferencedAssemblies $references
$root = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-native-fixture-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$records = New-Object 'System.Collections.Generic.List[object]'
function Assert-Native($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    foreach ($name in $Scenario) {
        $status = 'Passed'; $diagnostic = $null
        try {
            switch ($name) {
                'ClipboardRoundTrip' {
                    $bitmap = New-Object Drawing.Bitmap(2,2)
                    $stream = New-Object IO.MemoryStream
                    try {
                        $bitmap.SetPixel(0,0,[Drawing.Color]::Red)
                        $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
                        $path = Join-Path $root 'fixture.png'; [IO.File]::WriteAllBytes($path,$stream.ToArray())
                        [Windows.Forms.Clipboard]::SetText('clipwarp-fixture-seed')
                        $expected = [ClipwarpTransport.ClipboardWriter]::GetClipboardSequenceNumber()
                        $data = New-Object Windows.Forms.DataObject
                        $data.SetData('PNG',$false,$stream)
                        $data.SetData([Windows.Forms.DataFormats]::Bitmap,$bitmap)
                        $data.SetData([Windows.Forms.DataFormats]::FileDrop,[string[]]@($path))
                        $data.SetData([Windows.Forms.DataFormats]::UnicodeText,$path)
                        [void][ClipwarpTransport.ClipboardWriter]::Publish($data,$expected)
                        $actual = [Windows.Forms.Clipboard]::GetDataObject()
                        foreach ($format in @('PNG','Bitmap','FileDrop','UnicodeText')) { Assert-Native ($actual.GetDataPresent($format)) "Missing format: $format" }
                        $png = $actual.GetData('PNG')
                        try {
                            $decoded = [Drawing.Image]::FromStream($png)
                            try { Assert-Native ($decoded.Width -eq 2 -and $decoded.Height -eq 2 -and $decoded.GetPixel(0,0).ToArgb() -eq [Drawing.Color]::Red.ToArgb()) 'PNG pixels did not round-trip' }
                            finally { $decoded.Dispose() }
                        } finally { if ($png -is [IDisposable]) { $png.Dispose() } }
                        Assert-Native (@($actual.GetData('FileDrop'))[0] -eq $path) 'FileDrop path did not round-trip'
                    } finally { $stream.Dispose(); $bitmap.Dispose() }
                }
                'ClipboardRace' {
                    [Windows.Forms.Clipboard]::SetText('clipwarp-fixture-A')
                    $sequenceA = [ClipwarpTransport.ClipboardWriter]::GetClipboardSequenceNumber()
                    [Windows.Forms.Clipboard]::SetText('clipwarp-fixture-B')
                    $data = New-Object Windows.Forms.DataObject
                    $data.SetText('clipwarp-fixture-stale')
                    $rejected = $false
                    try { [void][ClipwarpTransport.ClipboardWriter]::Publish($data,$sequenceA) }
                    catch { if ($_.Exception.ToString() -match 'clipboard-changed') { $rejected = $true } else { throw } }
                    Assert-Native $rejected 'Stale A publication was not rejected'
                    Assert-Native ([Windows.Forms.Clipboard]::GetText() -eq 'clipwarp-fixture-B') 'Newer B was overwritten'
                }
                'FilePicker' {
                    $path = Join-Path $root 'pick-this-fixture.txt'; [IO.File]::WriteAllText($path,'synthetic fixture')
                    $dialog = New-Object Windows.Forms.OpenFileDialog
                    try {
                        $dialog.InitialDirectory = $root; $dialog.Title = 'ClipWarp fixture: choose pick-this-fixture.txt or Cancel'
                        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { $status = 'Cancelled' }
                        else { Assert-Native ($dialog.FileName -eq $path) 'Choose only the generated fixture file' }
                    } finally { $dialog.Dispose() }
                }
                'ControlledBrowser' {
                    # Static local page, no remote requests, account, submit action, or keys.
                    $page = Join-Path $root 'browser-fixture.html'
                    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'browser-fixture.html') -Destination $page
                    Start-Process -FilePath $page
                    if ((Read-Host 'Confirm the LOCAL fixture is visible and no text was pasted/sent automatically. Type VERIFIED, then close that tab') -cne 'VERIFIED') { $status = 'NotVerified' }
                    # Never kill the default browser: its process may belong to the user.
                }
            }
        } catch { $status = 'Failed'; $diagnostic = $_.Exception.Message }
        $records.Add([pscustomobject]@{ Scenario=$name; Status=$status; Error=$diagnostic })
    }
} finally {
    # Delete only exact files this fixture creates, never recursive user content.
    foreach ($file in @('fixture.png','pick-this-fixture.txt','browser-fixture.html')) {
        $path = Join-Path $root $file
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    [IO.Directory]::Delete($root)
}
$report = [pscustomobject]@{
    SchemaVersion=1; Kind='InteractiveNative'; Suites=@($records.ToArray())
    NotCovered=@('target churn with watcher','worker stop/restart','installer rollback','popup focus/hover/DPI','controlled browser origin/composer automation')
}
$json = $report | ConvertTo-Json -Depth 5
if ($ResultsPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultsPath),$json,(New-Object Text.UTF8Encoding($false))) }
Write-Output $json
if (@($records | Where-Object Status -ne 'Passed').Count) { exit 1 }
