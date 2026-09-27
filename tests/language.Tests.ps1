$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'clipwarp-watch.ps1'),[ref]$tokens,[ref]$errors)
$src=$ast.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('namespace ClipwarpWatch')},$true).Value
function Assert($value,$name) { if (-not $value) { throw $name }; Write-Host "PASS: $name" }
Assert ($src.Contains('public class LanguageState')) 'language state exists'
Add-Type -AssemblyName System.Windows.Forms
$compile=$src+[IO.File]::ReadAllText((Join-Path $root 'clipwarp-clipboard.cs'))
if ($PSVersionTable.PSEdition -eq 'Core') {
    $refs=@(Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
    $refs+=@([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
    $refs+=[AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
    Add-Type -TypeDefinition $compile -ReferencedAssemblies ($refs | Group-Object {[IO.Path]::GetFileName($_)} | ForEach-Object {$_.Group[0]})
} else { Add-Type -TypeDefinition $compile -ReferencedAssemblies System,System.Windows.Forms,System.Drawing }
Assert ([ClipwarpWatch.LanguageState]::Label(0x041e) -eq 'TH — ไทย') 'Thai LANGID label'
Assert ([ClipwarpWatch.LanguageState]::Label(0x0409) -eq 'EN — English') 'English LANGID label'
Assert ([ClipwarpWatch.LanguageState]::Label(0x12340409) -eq 'EN — English') 'HKL low word is LANGID'
Assert ([ClipwarpWatch.LanguageState]::Label(0xffff) -eq 'Language 0xFFFF') 'unknown deterministic label'
$s=New-Object ClipwarpWatch.LanguageState
Assert (-not $s.Observe(0,0)) 'unavailable sample ignored'
Assert (-not $s.Observe(0x0409,100)) 'baseline does not display'
Assert (-not $s.Visible(100)) 'initial overlay hidden'
Assert ($s.Observe(0x041e,200)) 'actual change displays'
Assert ($s.HideAt -eq 2200 -and $s.Visible(2199) -and -not $s.Visible(2200)) 'exact 2000ms deadline'
Assert (-not $s.Observe(0x041e,300)) 'same layout does not reset'
Assert ($s.HideAt -eq 2200) 'unchanged deadline preserved'
Assert ($s.Observe(0x0409,400) -and $s.HideAt -eq 2400) 'repeated change resets deadline'
Assert (-not $s.Observe(0,500) -and $s.HideAt -eq 2400) 'unavailable sample preserves state'
Assert ($s.Observe(0x12340409,600) -and $s.HideAt -eq 2600) 'different layout with same LANGID still changes'
Assert (-not $s.Observe(0x12340409,2601) -and -not $s.Visible(2601)) 'expired unchanged layout stays hidden'
Assert ([ClipwarpWatch.LanguageState]::Label(0) -eq 'Language 0x0000') 'zero LANGID deterministic fallback'
$work=New-Object Drawing.Rectangle -1000,0,1000,800
$p=[ClipwarpWatch.LanguageState]::Position($true,-900,100,$true,-800,200,-700,300,160,30,$work)
Assert ($p.X -eq -894 -and $p.Y -eq 106) 'translated caret wins over cursor'
$p=[ClipwarpWatch.LanguageState]::Position($false,0,0,$true,-800,200,-700,300,160,30,$work)
Assert ($p.X -eq -794 -and $p.Y -eq 206) 'cursor fallback'
$p=[ClipwarpWatch.LanguageState]::Position($false,0,0,$false,0,0,-700,300,160,30,$work)
Assert ($p.X -eq -694 -and $p.Y -eq 306) 'foreground fallback'
$p=[ClipwarpWatch.LanguageState]::Position($true,-1,799,$false,0,0,0,0,160,30,$work)
Assert ($p.X -eq -160 -and $p.Y -eq 770) 'working area clamps negative monitor coordinates'
foreach($contract in @('GetKeyboardLayout(thread)','GetGUIThreadInfo(thread','CaretToScreen(info.hwndCaret','info.rcCaret.Bottom','ShowWithoutActivation','0x08000000','0x00000080','WM_MOUSEACTIVATE','MA_NOACTIVATE','FormBorderStyle.None','TopMost = true','ShowInTaskbar = false','Stopwatch.StartNew()','Interval = 100','language.Dispose()','poll.Dispose()','hide.Dispose()','fg == overlay.Handle')) {
    Assert ($src.Contains($contract)) "source contract: $contract"
}
Assert ($src -notmatch 'RegisterHotKey|SetWindowsHookEx|SendInput|SendKeys|keybd_event') 'source contract: no hotkey interception or synthesis'
$bytes=[IO.File]::ReadAllBytes((Join-Path $root 'clipwarp-watch.ps1'))
Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'watcher UTF-8 BOM'
Write-Host 'PASS: fake-only language tests; no watcher or form instantiated'

Assert ($src.Contains('thread.SetApartmentState(System.Threading.ApartmentState.STA)') -and $src.Contains('Application.Run()')) 'source contract: independent STA pump for language timers'
Assert ($src.Contains('Application.ExitThread()') -and $src.Contains('thread.Join(1000)')) 'source contract: bounded language pump shutdown'

$indicator=$src.Substring($src.IndexOf('internal sealed class LanguageIndicator :'),$src.IndexOf('public class Watcher :')-$src.IndexOf('internal sealed class LanguageIndicator :'))
Assert ($indicator -notmatch 'Clipboard|CaptureForeground|OnForegroundWindowChanged|SetForegroundWindow|SetFocus|AttachThreadInput') 'source contract: no clipboard, target tracking or focus calls in indicator'
Assert ($indicator.Contains('hide.Tick -= HideExpired') -and $indicator.Contains('poll.Tick -= Poll') -and $indicator.Contains('overlay.Dispose()')) 'source contract: timer handlers and overlay disposal'
$runner=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run-all.ps1'))
Assert ($runner.Contains("-Filter '*.Tests.ps1'")) 'suite automatically discovers language tests'
$testBytes=[IO.File]::ReadAllBytes($PSCommandPath)
Assert ($testBytes[0] -eq 239 -and $testBytes[1] -eq 187 -and $testBytes[2] -eq 191) 'language tests UTF-8 BOM'

# Structural source contracts are not GUI E2E tests and do not prove OS input routing.
foreach ($contract in @('0x00080000 | 0x00000020', 'Opacity = 0.99',
    'WM_NCHITTEST = 0x0084, HTTRANSPARENT = -1',
    'if (m.Msg == WM_NCHITTEST) { m.Result = (IntPtr)HTTRANSPARENT; return; }',
    'Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException, true)',
    'SetThreadDpiAwarenessContext(new IntPtr(-3))', 'GetWindowDpiAwarenessContext(hwnd)',
    'ClientToScreen(hwnd, ref native)', 'LogicalToPhysicalPointForPerMonitorDPI(hwnd, ref native)',
    'finally { RestoreDpi(previous); }', 'if (!perMonitorDpi) return false;',
    'catch (EntryPointNotFoundException) { return false; }',
    'catch (DllNotFoundException) { return false; }',
    'catch { Dispose(); throw; }', 'catch (InvalidOperationException) { }')) {
    Assert ($src.Contains($contract)) "source contract: $contract"
}
$hostStart=$src.IndexOf('internal sealed class LanguageIndicatorHost')
$mode=$src.IndexOf('Application.SetUnhandledExceptionMode(', $hostStart)
$dpi=$src.IndexOf('previousDpi = LanguageIndicator.EnterPerMonitorDpi()', $hostStart)
$handle=$src.IndexOf('IntPtr handle = control.Handle', $hostStart)
Assert ($mode -lt $handle -and $dpi -lt $handle) 'source contract: thread exception and DPI modes precede first handle'
Assert ($src.Contains('try { report("language indicator stopped: " + ex.Message); } catch { }')) 'source contract: single guarded error report'

# Fake native transforms: target logical screen -> physical screen, with monitor-relative scaling.
$client=New-Object Drawing.Point 20,40
$toScreen=[Func[Drawing.Point,Nullable[Drawing.Point]]]{param($p) [Drawing.Point]::new(-1000+$p.X,100+$p.Y)}
foreach ($scale in @(1.0,1.5,2.0)) {
    $physical=[Func[Drawing.Point,Nullable[Drawing.Point]]]{param($p) [Drawing.Point]::new(-1920+[int](($p.X+1000)*$scale),[int](($p.Y-100)*$scale))}
    $p=[ClipwarpWatch.LanguageState]::NormalizeCaret($client,$toScreen,$physical)
    Assert ($p.X -eq (-1920+20*$scale) -and $p.Y -eq (40*$scale)) "fake DPI policy: $scale scale preserves negative monitor origin"
}
$failedMap=[Func[Drawing.Point,Nullable[Drawing.Point]]]{param($p) $null}
$mustNotRun=[Func[Drawing.Point,Nullable[Drawing.Point]]]{param($p) throw 'unexpected physical conversion'}
Assert ($null -eq [ClipwarpWatch.LanguageState]::NormalizeCaret($client,$failedMap,$mustNotRun)) 'fake DPI policy: failed client mapping skips conversion'
Assert ($null -eq [ClipwarpWatch.LanguageState]::NormalizeCaret($client,$toScreen,$failedMap)) 'fake DPI policy: failed physical conversion requests cursor fallback'
Write-Host 'PASS: fake policy and structural contracts only; no GUI E2E or native DPI/input execution'
