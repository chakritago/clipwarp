$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$watch = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-watch.ps1'))
$src = [regex]::Match($watch, "(?s)\`$src = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $src) { throw 'Missing watcher source' }
$src += [IO.File]::ReadAllText((Join-Path $root 'clipwarp-clipboard.cs'))
$src += [IO.File]::ReadAllText((Join-Path $root 'clipwarp-image.cs'))
$src += [IO.File]::ReadAllText((Join-Path $root 'clipwarp-policy.cs'))
# All threaded callbacks are C#; no PowerShell runspace or live clipboard is used.
$src += @'
public static class WorkerFixture {
    public static void Run() {
        var worker=new ClipwarpWatch.CoalescingStaWorker();
        var entered=new System.Threading.ManualResetEvent(false);
        var release=new System.Threading.ManualResetEvent(false);
        var done=new System.Threading.ManualResetEvent(false);
        int seen=0, calls=0;
        bool sta=false, cleaned=false;
        worker.Cleanup=delegate { cleaned=true; };
        worker.EnqueueForeground(delegate { entered.Set(); release.WaitOne(3000); });
        if(!entered.WaitOne(3000)) throw new System.Exception("Worker failed to start");
        for(int i=1;i<=100;i++) {
            int value=i;
            worker.EnqueueForeground(delegate { seen=value; calls++; sta=System.Threading.Thread.CurrentThread.GetApartmentState()==System.Threading.ApartmentState.STA; done.Set(); });
        }
        release.Set();
        if(!done.WaitOne(3000)) throw new System.Exception("Coalesced work missing");
        if(!worker.Shutdown(3000) || seen!=100 || calls!=1 || !sta || !cleaned) throw new System.Exception("Worker coalescing/STA/drain contract failed");
        worker.EnqueueForeground(delegate { throw new System.Exception("Accepted after shutdown"); });
        worker.Dispose(); entered.Dispose(); release.Dispose(); done.Dispose();
        string name="Local\\Clipwarp-test-"+System.Guid.NewGuid().ToString("N");
        using(var signal=new System.Threading.EventWaitHandle(false,System.Threading.EventResetMode.ManualReset,name))
        using(var sender=System.Threading.EventWaitHandle.OpenExisting(name)) {
            sender.Set(); if(!signal.WaitOne(1000)) throw new System.Exception("Named shutdown event failed");
        }
    }
}
'@
if ($PSVersionTable.PSEdition -eq 'Core') {
    $refs = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
    $refs += @([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
    $refs += [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
    Add-Type -TypeDefinition $src -ReferencedAssemblies ($refs | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
} else { Add-Type -TypeDefinition $src -ReferencedAssemblies System,System.Windows.Forms,System.Drawing }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Reject([scriptblock]$action, $message) { $failed=$false; try { & $action } catch { $failed=$true }; Assert $failed $message }
$limits = New-Object ClipwarpImages.ImageLimits
$bitmap = New-Object Drawing.Bitmap 2,2
$bitmap.SetPixel(0,0,[Drawing.Color]::FromArgb(128,255,0,0))
try {
    $payload = [ClipwarpImages.ImageHelper]::FromImage($bitmap,$limits)
    try {
        $png=$payload.GetPngBytes()
        Assert ([ClipwarpImages.ImageHelper]::HasPngSignature($png)) 'Genuine PNG signature'
        $copy=$payload.CreateBitmap()
        try { Assert ($copy.GetPixel(0,0).A -eq 128) 'Transparency survives PNG'; Assert ($copy.Width -eq 2) 'PNG dimensions' } finally { $copy.Dispose() }
        $clone=$payload.GetPngBytes(); $clone[0]=0
        Assert ([ClipwarpImages.ImageHelper]::HasPngSignature($payload.GetPngBytes())) 'Immutable encoded cache'
        $data=New-Object Windows.Forms.DataObject
        $data.SetImage($bitmap); $stream=New-Object IO.MemoryStream (,$png)
        try {
            $data.SetData('PNG',$false,$stream); $data.SetData('ClipwarpManaged','C:\fixture.png')
            $data.SetData([Windows.Forms.DataFormats]::UnicodeText,'C:\fixture.png')
            $data.SetData([Windows.Forms.DataFormats]::FileDrop,[string[]]@('C:\fixture.png'))
            $formats=[ClipwarpTransport.ClipboardWriter]::Prepare($data,[Func[string,uint32]]{ param($name); if($name -eq 'PNG'){return 50001};return 50002 })
            Assert ($formats.ContainsKey(8) -and $formats.ContainsKey(13) -and $formats.ContainsKey(15) -and $formats.ContainsKey(50001)) 'Dual payload contains DIB, PNG, text, file'
        } finally { $stream.Dispose() }
        $jpeg=New-Object IO.MemoryStream
        try { $bitmap.Save($jpeg,[Drawing.Imaging.ImageFormat]::Jpeg); $encoded=[ClipwarpImages.ImageHelper]::FromBytes($jpeg.ToArray(),$limits); try { Assert ([ClipwarpImages.ImageHelper]::HasPngSignature($encoded.GetPngBytes())) 'JPEG transcoded, not relabelled' } finally { $encoded.Dispose() } } finally { $jpeg.Dispose() }
    } finally { $payload.Dispose() }
    Reject { $payload.GetPngBytes() } 'Disposed payload rejected'
} finally { $bitmap.Dispose() }
Reject { [ClipwarpImages.ImageHelper]::FromBytes([byte[]](137,80,78,71,0,0,0,0),$limits) } 'Partial PNG signature rejected'
$oversize=[byte[]]$png.Clone(); [Array]::Copy([byte[]](127,255,255,255),0,$oversize,16,4)
Reject { [ClipwarpImages.ImageHelper]::FromBytes($oversize,$limits) } 'Extreme PNG header rejected before decode'
$limits.MaxPixels=1
Reject { [ClipwarpImages.ImageHelper]::FromBytes($png,$limits) } 'Configurable pixel budget enforced'
$limits=New-Object ClipwarpImages.ImageLimits
# Top-down 32-bit BITFIELDS DIB with explicit alpha.
$dib=New-Object byte[] 60
[Array]::Copy([BitConverter]::GetBytes([uint32]56),0,$dib,0,4)
[Array]::Copy([BitConverter]::GetBytes([int]1),0,$dib,4,4)
[Array]::Copy([BitConverter]::GetBytes([int]-1),0,$dib,8,4)
$dib[12]=1; $dib[14]=32; $dib[16]=3
[Array]::Copy([BitConverter]::GetBytes([uint32]16711680),0,$dib,40,4)
[Array]::Copy([BitConverter]::GetBytes([uint32]65280),0,$dib,44,4)
[Array]::Copy([BitConverter]::GetBytes([uint32]255),0,$dib,48,4)
[Array]::Copy([BitConverter]::GetBytes([uint32]4278190080),0,$dib,52,4)
$dib[58]=255; $dib[59]=128
$p=[ClipwarpImages.ImageHelper]::FromDib($dib,$limits)
try { $b=$p.CreateBitmap(); try { Assert ($b.GetPixel(0,0).A -eq 128 -and $b.GetPixel(0,0).R -eq 255) 'DIB alpha/top-down pixel' } finally { $b.Dispose() } } finally { $p.Dispose() }
Reject { [ClipwarpImages.ImageHelper]::FromDib([byte[]]$dib[0..58],$limits) } 'Truncated DIB rejected without padding'
$bad=[byte[]]$dib.Clone(); [Array]::Copy([BitConverter]::GetBytes([int]::MinValue),0,$bad,8,4)
Reject { [ClipwarpImages.ImageHelper]::FromDib($bad,$limits) } 'Extreme signed height rejected'
$bad=[byte[]]$dib.Clone(); [Array]::Copy($bad,40,$bad,44,4)
Reject { [ClipwarpImages.ImageHelper]::FromDib($bad,$limits) } 'Overlapping masks rejected'
[WorkerFixture]::Run()
Assert ($watch -match 'StartTime.ToUniversalTime\(\).Ticks -ne \$startTicks') 'Force stop revalidates start identity'
Assert ($watch -match 'WaitForExit\(8000\)') 'Graceful stop precedes forced termination'
Assert ($src -match 'targetIsCurrent != null && !targetIsCurrent\(\)') 'Target generation validated under clipboard lock'
Write-Host 'PASS: image decoding/resource limits/dual preparation and STA coalescing/lifecycle fixtures (no live clipboard)'
