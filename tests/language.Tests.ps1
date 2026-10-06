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
$duration=[ClipwarpWatch.LanguageState]::DisplayDurationMilliseconds
Assert ($duration -eq 1000) 'required display duration is exactly 1,000 ms'
$readme=[IO.File]::ReadAllText((Join-Path $root 'README.md'))
$timing=($duration / 1000.0).ToString('F2',[Globalization.CultureInfo]::InvariantCulture) + ' seconds/' + $duration.ToString('N0',[Globalization.CultureInfo]::InvariantCulture) + ' ms'
Assert ($readme.Contains($timing) -and $readme.Contains('caret-anchored above the text')) 'README timing agrees with named duration and documents caret anchoring'
$s=New-Object ClipwarpWatch.LanguageState
Assert (-not $s.Observe(0,0)) 'unavailable sample ignored'
Assert (-not $s.Observe(0x0409,100)) 'baseline does not display'
Assert (-not $s.Visible(100)) 'initial overlay hidden'
Assert ($s.Observe(0x041e,200)) 'actual change displays'
Assert ($s.HideAt -eq (200+$duration) -and $s.Visible((200+$duration-1)) -and -not $s.Visible((200+$duration))) 'exact 1,000 ms boundary: visible before, hidden at deadline'
Assert (-not $s.Observe(0x041e,300)) 'same layout does not reset'
Assert ($s.HideAt -eq (200+$duration)) 'unchanged deadline preserved'
Assert ($s.Observe(0x0409,400) -and $s.HideAt -eq (400+$duration)) 'repeated change resets deadline'
Assert (-not $s.Observe(0,500) -and $s.HideAt -eq (400+$duration)) 'unavailable sample preserves state'
Assert ($s.Observe(0x12340409,600) -and $s.HideAt -eq (600+$duration)) 'different layout with same LANGID still changes'
Assert (-not $s.Observe(0x12340409,(600+$duration+1)) -and -not $s.Visible((600+$duration+1))) 'expired unchanged layout stays hidden'
Assert ([ClipwarpWatch.LanguageState]::Label(0) -eq 'Language 0x0000') 'zero LANGID deterministic fallback'
$gap=[ClipwarpWatch.LanguageState]::CaretGapPixels
Assert ($gap -gt 0 -and $gap -le 10) 'small positive caret gap'
$work=New-Object Drawing.Rectangle -1000,0,1000,800
$p=[ClipwarpWatch.LanguageState]::Position($true,-900,100,$true,-800,200,-700,300,160,30,$work)
Assert ($p.X -eq -980 -and ($p.X + 160/2) -eq -900) 'caret wins over deliberately different cursor and centers on caret X'
Assert ($p.Y -eq (100-30-$gap) -and $p.Y -lt 100 -and ($p.Y+30) -lt 100) 'label top and bottom are strictly above caret top with gap'
$p=[ClipwarpWatch.LanguageState]::Position($false,0,0,$true,-800,200,-700,300,160,30,$work)
Assert ($p.X -eq -794 -and $p.Y -eq 206) 'cursor fallback'
$p=[ClipwarpWatch.LanguageState]::Position($false,0,0,$false,0,0,-700,300,160,30,$work)
Assert ($p.X -eq -694 -and $p.Y -eq 306) 'foreground fallback'
$p=[ClipwarpWatch.LanguageState]::Position($true,-1,900,$false,0,0,0,0,160,30,$work)
Assert ($p.X -eq -160 -and $p.Y -eq 770) 'working area clamps negative monitor coordinates'
$p=[ClipwarpWatch.LanguageState]::Position($true,-999,-20,$true,5000,5000,0,0,160,30,$work)
Assert ($p.X -eq -1000 -and $p.Y -eq 0) 'caret-centered placement clamps left and top'
$p=[ClipwarpWatch.LanguageState]::Position($true,-500,100,$true,5000,5000,0,0,161,30,$work)
Assert ($p.X -eq -580 -and $p.Y -eq (100-30-$gap)) 'odd label width centers within one pixel'
foreach ($changeAt in @(2000,2100,2200)) {
    $layout=if ($changeAt -eq 2100) { 0x0409 } else { 0x041e }
    Assert ($s.Observe($layout,$changeAt) -and $s.HideAt -eq ($changeAt+$duration)) "repeated reset at $changeAt"
    Assert ($s.Visible($changeAt+$duration-1) -and -not $s.Visible($changeAt+$duration)) "exact reset boundary at $changeAt"
}
foreach($contract in @('GetKeyboardLayout(thread)','GetGUIThreadInfo(thread','CaretToScreen(info.hwndCaret','info.rcCaret.Top','ShowWithoutActivation','0x08000000','0x00000080','WM_MOUSEACTIVATE','MA_NOACTIVATE','FormBorderStyle.None','TopMost = true','ShowInTaskbar = false','Stopwatch.StartNew()','Interval = 100','language.Dispose()','poll.Dispose()','hide.Dispose()','fg == overlay.Handle')) {
    Assert ($src.Contains($contract)) "source contract: $contract"
}
Assert ($src -notmatch 'RegisterHotKey|SendInput|SendKeys|keybd_event') 'source contract: no hotkey registration or synthesis'
$bytes=[IO.File]::ReadAllBytes((Join-Path $root 'clipwarp-watch.ps1'))
Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'watcher UTF-8 BOM'
Write-Host 'PASS: fake-only language tests; no watcher or form instantiated'

Assert ($src.Contains('thread.SetApartmentState(System.Threading.ApartmentState.STA)') -and $src.Contains('Application.Run()')) 'source contract: independent STA pump for language timers'
Assert ($src.Contains('Application.ExitThread()') -and $src.Contains('thread.Join(1000)')) 'source contract: bounded language pump shutdown'

$indicator=$src.Substring($src.IndexOf('internal sealed class LanguageIndicator :'),$src.IndexOf('public class Watcher :')-$src.IndexOf('internal sealed class LanguageIndicator :'))
Assert ($indicator -notmatch 'Clipboard|CaptureForeground|OnForegroundWindowChanged|SetForegroundWindow|SetFocus|AttachThreadInput') 'source contract: no clipboard, target tracking or focus calls in indicator'
Assert ($indicator.Contains('hide.Tick -= HideExpired') -and $indicator.Contains('poll.Tick -= Poll') -and $indicator.Contains('overlay.Dispose()')) 'source contract: timer handlers and overlay disposal'
Assert ($indicator -notmatch 'GetCursorPos') 'source contract: label never anchors to the mouse cursor'
Assert ($indicator.Contains('caret = CaretToScreen(info.hwndCaret, ref point);') -and $indicator.Contains('ClientToScreen(info.hwndCaret, ref plain)') -and $indicator.Contains('Screen.FromPoint(anchor).WorkingArea')) 'source contract: DPI-aware caret mapping with plain ClientToScreen second chance'
Assert ($indicator.Contains('if (!caret) return;')) 'source contract: no system caret means no label'
Assert ($indicator.Contains('LanguageState.Position(true, point.X, point.Y, false, 0, 0,')) 'source contract: placement is always caret-anchored'
Assert ($src.Contains('HideAt = now + DisplayDurationMilliseconds;') -and $indicator.Contains('state.HideAt - clock.ElapsedMilliseconds')) 'source contract: state and hide timer share the named deadline'
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

# Pure shortcut state: synthetic message numbers only, no native hook or keyboard input.
foreach ($downMessage in @(0x100,0x104)) {
    $keys=New-Object ClipwarpWatch.LanguageShortcutState
    Assert ($keys.Observe($downMessage,0xC0)) 'grave keydown triggers'
    Assert (-not $keys.Observe($downMessage,0xC0)) 'held grave repeat suppressed'
    Assert (-not $keys.Observe(0x101,0xC0)) 'keyup never triggers'
    Assert ($keys.Observe($downMessage,0xC0)) 'new physical press triggers again'
}
foreach ($modifier in @(0x11,0xA2,0xA3,0x12,0xA4,0xA5,0x5B,0x5C)) {
    $keys=New-Object ClipwarpWatch.LanguageShortcutState
    $null=$keys.Observe(0x100,$modifier)
    Assert (-not $keys.Observe(0x100,0xC0)) "modified grave excluded: $modifier"
}
foreach ($win in @(0x5B,0x5C)) {
    $keys=New-Object ClipwarpWatch.LanguageShortcutState
    Assert (-not $keys.Observe(0x100,$win)) 'Win alone does not trigger'
    Assert ($keys.Observe(0x100,0x20)) 'Win+Space triggers'
    Assert (-not $keys.Observe(0x100,0x20)) 'held Win+Space suppressed'
    Assert (-not $keys.Observe(0x105,0x20)) 'system keyup does not trigger'
    Assert ($keys.Observe(0x104,0x20)) 'new Space while Win held triggers'
}
foreach ($alt in @(0x12,0xA4,0xA5)) {
    foreach ($shift in @(0x10,0xA0,0xA1)) {
        foreach ($reverse in @($false,$true)) {
            $keys=New-Object ClipwarpWatch.LanguageShortcutState
            $first=$alt; $second=$shift
            if ($reverse) { $first=$shift; $second=$alt }
            Assert (-not $keys.Observe(0x104,$first)) 'first Alt/Shift alone ignored'
            Assert ($keys.Observe(0x104,$second)) "Alt+Shift transition $first/$second"
            Assert (-not $keys.Observe(0x104,$second)) 'Alt+Shift repeat suppressed'
            Assert (-not $keys.Observe(0x105,$second)) 'Alt+Shift release ignored'
        }
    }
}
$keys=New-Object ClipwarpWatch.LanguageShortcutState
foreach ($key in @(0x20,0x41,0x0D,0x09)) { Assert (-not $keys.Observe(0x100,$key)) 'ordinary key ignored' }
Assert (-not $keys.Observe(0x999,0xC0)) 'non-key message ignored'
$null=$keys.Observe(0x100,0xA0)
Assert ($keys.Observe(0x100,0xC0)) 'Shift does not exclude configured grave shortcut'
$keys=New-Object ClipwarpWatch.LanguageShortcutState
$null=$keys.Observe(0x100,0xA2); $null=$keys.Observe(0x101,0xA2)
Assert ($keys.Observe(0x100,0xC0)) 'released modifier no longer excludes grave'
foreach ($contract in @('SetWindowsHookEx(13, keyboardProc, GetModuleHandle(null), 0)',
    'keyboardProc = KeyboardSignal', 'UnhookWindowsHookEx(keyboardHook)', 'GC.KeepAlive(keyboardProc)',
    'code >= 0 && !disposed', 'shortcuts.Observe(message.ToInt32(), Marshal.ReadInt32(data))',
    'return CallNextHookEx(keyboardHook, code, message, data);',
    'shortcutDispatcher.BeginInvoke((MethodInvoker)delegate', 'clock.ElapsedMilliseconds + 150',
    'probe.Interval = 10', 'clock.ElapsedMilliseconds >= probeUntil', 'probe.Tick -= Probe; probe.Dispose()',
    'shortcutDispatcher.Dispose()', 'poll.Interval = 100', 'InstallKeyboardSignal();')) {
    Assert ($indicator.Contains($contract)) "keyboard/probe source contract: $contract"
}
$callback=$indicator.Substring($indicator.IndexOf('private IntPtr KeyboardSignal'),$indicator.IndexOf('private void Probe')-$indicator.IndexOf('private IntPtr KeyboardSignal'))
Assert ($callback -match '(?s)catch \{ \}.*return CallNextHookEx' -and ([regex]::Matches($callback,'return CallNextHookEx').Count -eq 1)) 'all hook paths including errors and negative codes reach CallNextHookEx'
Assert ($callback -notmatch 'Sleep|WaitOne|ToUnicode|GetKeyboardState|Log\(') 'hook does not block, translate text or log keys'
Assert ($callback -match '(?s)BeginInvoke.*Poll\(null, EventArgs.Empty\);.*probeUntil = deadline;.*probe.Start\(\)') 'queued UI callback polls immediately before bounded retries'
$install=$indicator.Substring($indicator.IndexOf('private void InstallKeyboardSignal'),$indicator.IndexOf('private IntPtr KeyboardSignal')-$indicator.IndexOf('private void InstallKeyboardSignal'))
Assert ($install.Contains('catch (EntryPointNotFoundException)') -and $install.Contains('catch (DllNotFoundException)') -and $install -notmatch 'throw|poll.Stop') 'missing hook APIs preserve polling fallback'
Assert ($indicator.IndexOf('poll.Start();') -lt $indicator.IndexOf('InstallKeyboardSignal();')) 'fallback polling starts before hook installation'
Assert ($readme.Contains('keydown') -and $readme.Contains('No key is consumed')) 'README documents immediate non-consuming signal'
Assert ($indicator.Contains('SetWindowPos') -and $indicator.Contains('HWND_TOPMOST') -and $indicator.Contains('SWP_NOACTIVATE')) 'label re-asserts topmost z-order without activating'
Assert ($indicator.Contains('AssertTopmost(overlay)')) 'every label display re-asserts z-order'
Write-Host 'PASS: shortcut fake state and hook/probe source contracts; no real hooks, keys, watcher or overlay'
