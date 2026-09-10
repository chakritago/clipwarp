param([string]$ImageHelperPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-image.cs'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-support.psm1') -Force
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$work = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$work' }, $true)
if (-not $work) { throw 'Missing conversion work block' }
# Extract ONLY pure preparation/storage functions. Never invoke/dot-source the converter.
$names = @('New-ConversionLimits','Read-StreamBytes','New-PngStreamPayload','Save-OwnedPng','Remove-AbortedFiles','New-ConversionPublication','Get-FilePayload')
foreach ($name in $names) {
    $fn = $work.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Missing helper $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:checks = 0
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Action, $Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
Add-Type -AssemblyName System.Drawing,System.Windows.Forms
$source = [IO.File]::ReadAllText($ImageHelperPath)
if (-not ('ClipwarpImages.ImageHelper' -as [type])) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $refs = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
        $refs += @([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
        $refs += [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
        Add-Type -TypeDefinition $source -ReferencedAssemblies ($refs | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
    } else { Add-Type -TypeDefinition $source -ReferencedAssemblies System,System.Drawing,System.Windows.Forms }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('clipwarp-converter-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$bitmap = New-Object Drawing.Bitmap 2,2
$payload = $null
try {
    $limits = New-ConversionLimits @{}
    Assert ($limits.MaxSourceBytes -gt 0) 'Default byte budget'
    $small = New-ConversionLimits @{ imageLimits = @{ MaxDimension = 1 } }
    Reject { $small.CheckDimensions(2,1) } 'Dimension override must apply'
    Reject { New-ConversionLimits @{ imageLimits = @{ MaxPixels = 0 } } } 'Reject invalid budget'
    Reject { New-ConversionLimits @{ imageLimits = @{ MaxSourceBytes = 'garbage' } } } 'Reject nonnumeric budget'
    Reject { New-ConversionLimits @{ imageLimits = @{ MaxPixels = 1.5 } } } 'Reject fractional budget'
    $bytes = [byte[]](1,2,3,4)
    $read = Read-StreamBytes $bytes 4
    Assert ($read -is [byte[]] -and $read.Length -eq 4) 'Byte array stays byte array'
    Reject { Read-StreamBytes $bytes 3 } 'Array budget enforced'
    $stream = New-Object IO.MemoryStream (,$bytes)
    try {
        $stream.Position = 2
        $read = Read-StreamBytes $stream 4
        Assert ($read.Length -eq 4 -and $stream.Position -eq 2 -and $stream.CanRead) 'Input stream position/lifetime preserved'
        Reject { Read-StreamBytes $stream 3 } 'Stream budget enforced'
        Assert ($stream.Position -eq 2) 'Rejected stream position preserved'
    } finally { $stream.Dispose() }
    Reject { New-PngStreamPayload ([byte[]](137,80,78,71,0,0,0,0)) $limits } 'Full signature required'
    Reject { New-PngStreamPayload ([byte[]](137,80,78,71,13,10,26,10)) $limits } 'IHDR required'
    $bitmap.SetPixel(0,0,[Drawing.Color]::FromArgb(128,255,0,0))
    $payload = [ClipwarpImages.ImageHelper]::FromImage($bitmap,$limits)
    $png = $payload.GetPngBytes()
    $pixelImage = $payload.CreateBitmap()
    try { Assert ($pixelImage.GetPixel(0,0).A -eq 128) 'PNG transparency retained' } finally { $pixelImage.Dispose() }
    $hugePng = [byte[]]$png.Clone()
    $hugePng[16] = 127; $hugePng[17] = 255; $hugePng[18] = 255; $hugePng[19] = 255
    Reject { New-PngStreamPayload $hugePng $limits } 'PNG dimensions rejected before decoding'
    $decoded = New-PngStreamPayload $png $limits
    try { Assert ($decoded.Width -eq 2 -and $decoded.Height -eq 2) 'Genuine PNG round-trip' } finally { $decoded.Dispose() }
    foreach ($mode in @('text','dual','image-only')) {
        $publication = New-ConversionPublication $mode 'C:\fixture.png' $payload
        try {
            Assert ($publication.Data.GetDataPresent('ClipwarpManaged', $false)) 'Managed marker required'
            Assert ($publication.Data.GetDataPresent('PNG', $false) -eq ($mode -ne 'text')) 'PNG mode contract'
            Assert ($publication.Data.GetDataPresent([Windows.Forms.DataFormats]::Bitmap, $false) -eq ($mode -ne 'text')) 'Bitmap mode contract'
            Assert ($publication.Data.GetDataPresent([Windows.Forms.DataFormats]::UnicodeText, $false) -eq ($mode -ne 'image-only')) 'Text mode contract'
            Assert ($publication.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop, $false) -eq ($mode -eq 'dual')) 'File-drop mode contract'
        } finally {
            if ($publication.Image) { $publication.Image.Dispose() }
            if ($publication.Stream) { $publication.Stream.Dispose() }
        }
    }
    Reject { New-ConversionPublication dual 'C:\fixture.png' $null } 'Dual cannot silently omit image'
    Reject { New-ConversionPublication image-only 'C:\fixture.png' $null } 'Image-only cannot emit empty image'
    $owned = New-Object 'Collections.Generic.List[string]'
    $first = Save-OwnedPng $payload $temp $owned
    $second = Save-OwnedPng $payload $temp $owned
    Assert ($first -ne $second -and $owned.Count -eq 2) 'Unique operation-owned paths'
    Assert ([IO.Path]::GetFileName($first) -match '^clip-\d{8}-\d{6}-\d{3}-[a-f0-9]{32}\.png$') 'GUID filename contract'
    $unrelated = Join-Path $temp 'unrelated.png'
    [IO.File]::WriteAllText($unrelated,'keep')
    Remove-AbortedFiles $owned $true
    Assert ([IO.File]::Exists($first)) 'Retain potentially published file'
    Remove-AbortedFiles $owned $false
    Assert (-not [IO.File]::Exists($first) -and -not [IO.File]::Exists($second)) 'Aborted owned files deleted'
    Assert ([IO.File]::ReadAllText($unrelated) -eq 'keep') 'Unrelated file preserved'
    $jpeg = Join-Path $temp 'source.jpg'
    $bitmap.Save($jpeg,[Drawing.Imaging.ImageFormat]::Jpeg)
    $jpgPayload = Get-FilePayload $jpeg $limits
    try {
        Assert ([ClipwarpImages.ImageHelper]::HasPngSignature($jpgPayload.GetPngBytes())) 'JPEG is genuinely transcoded to PNG'
    } finally { $jpgPayload.Dispose() }
    $bad = Join-Path $temp 'bad.webp'
    [IO.File]::WriteAllBytes($bad, [byte[]](1,2,3,4))
    Reject { Get-FilePayload $bad $limits } 'Unsupported encoding fails rather than mislabels bytes'
    # DIB validation is delegated to the shared helper, not reimplemented/padded.
    $dib = New-Object byte[] 44
    [BitConverter]::GetBytes([uint32]40).CopyTo($dib,0)
    [BitConverter]::GetBytes([int]1).CopyTo($dib,4)
    [BitConverter]::GetBytes([int]-1).CopyTo($dib,8)
    [BitConverter]::GetBytes([uint16]1).CopyTo($dib,12)
    [BitConverter]::GetBytes([uint16]32).CopyTo($dib,14)
    $dib[42] = 255
    $dibPayload = [ClipwarpImages.ImageHelper]::FromDib($dib,$limits)
    try { Assert ($dibPayload.Width -eq 1 -and $dibPayload.Height -eq 1) 'Top-down DIB accepted' } finally { $dibPayload.Dispose() }
    Reject { [ClipwarpImages.ImageHelper]::FromDib([byte[]]$dib[0..42],$limits) } 'Truncated DIB is never padded'
    [BitConverter]::GetBytes([int]::MinValue).CopyTo($dib,8)
    Reject { [ClipwarpImages.ImageHelper]::FromDib($dib,$limits) } 'DIB height overflow rejected'
    Assert ($work.Extent.Text.Contains('[ClipwarpTransport.ClipboardWriter]::PublishPrepared($formats, $seq0, $guard)')) 'Native locked-sequence and foreground-guard publication retained'
    Assert ($work.Extent.Text.Contains('$currentTarget = Get-ClipwarpForegroundTargetInfo')) 'Publication recaptures foreground after decoding'
    Assert (-not ($work.Extent.Text -match 'SetDataObject|WriteAllBytes|\$padded|::GetImage\(')) 'Unsafe legacy paths removed'
    Assert ($work.Extent.Text.Contains('[IO.FileMode]::CreateNew')) 'Exclusive file creation required'
    Write-Host "converter.Tests.ps1: $script:checks assertions passed ($($PSVersionTable.PSEdition)). No clipboard access or conversion invocation."
} finally {
    if ($payload) { $payload.Dispose() }
    $bitmap.Dispose()
    if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp,$true) }
}
