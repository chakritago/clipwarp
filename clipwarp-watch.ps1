<#
.SYNOPSIS
    clipwarp-watch - background clipboard watcher for clipwarp.

.DESCRIPTION
    Listens for clipboard changes (WM_CLIPBOARDUPDATE). Whenever meaningful text
    or an image lands on the clipboard, it offers a clickable Google Calendar
    prompt near the pointer. Images from any app (Snipping Tool, Lightshot, a
    browser's "copy image", or Ctrl+C on an image file) are also passed to
    clipwarp.ps1 -KeepImage, which rewrites the clipboard as DUAL format:

        text  = the saved image path   -> Ctrl+V in Claude Code attaches the image
        image = the original bitmap    -> Ctrl+V in Photoshop/Word still pastes the image

    So with the watcher running the flow is just: Ctrl+C anywhere -> Ctrl+V in
    Claude Code. No manual clipwarp step.

    Clipboards that carry meaningful text alongside an image (e.g. copying a
    paragraph in Word) are not image-converted; their text is offered as the
    calendar event title instead.

    A burst/storm circuit-breaker (ClipboardBurstGuard) suppresses repeated
    identical copies (5x in 60s -> 2-minute suppression) and pauses handling
    during clipboard event floods (30 events in 10s -> 30s pause), so a
    misbehaving app can never spin the watcher forever. Disable with
    "burstGuard": false in %USERPROFILE%\.claude\clipwarp.json.

.USAGE
    clipwarp watch      # start (detached, hidden, system tray)
    clipwarp restart    # restart (detached, hidden, system tray)
    clipwarp status     # is it running?
    clipwarp stop       # stop
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Status,
    [switch]$Restart,
    [switch]$Autostart,    # register a login shortcut so the watcher starts at sign-in
    [switch]$NoAutostart,  # remove that login shortcut
    [switch]$Daemon        # internal: run the listener loop in THIS process
)

$scriptsDir = Join-Path $env:USERPROFILE '.claude\scripts'
$pidFile    = Join-Path $scriptsDir 'clipwarp-watch.pid'
$logFile    = Join-Path $scriptsDir 'clipwarp-watch.log'
$clipwarpPath  = Join-Path $PSScriptRoot 'clipwarp.ps1'
$calendarPopupPath = Join-Path $PSScriptRoot 'clipwarp-calendar-popup.ps1'
$configPath = Join-Path $env:USERPROFILE '.claude\clipwarp.json'
$startupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'

# Tri-state identity for the pid in the pid file, so a reused/stale PID can never
# be mistaken for the watcher AND a verifiably-live-but-unreadable process is not
# mistaken for "gone":
#   none    - no pid file, or the process is not alive
#   watcher - a live process whose command line is exactly our daemon (script + -Daemon)
#   foreign - a live process that is verifiably NOT our daemon (name mismatch, or
#             command line read OK but doesn't match)
#   unknown - a live powershell/pwsh whose command line could not be read (CIM failed)
# Callers must REFUSE to stop/delete on 'unknown'.
function Get-WatchState {
    if (-not (Test-Path -LiteralPath $pidFile)) { return @{ State = 'none'; Pid = $null } }
    $watchPid = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$watchPid)) { return @{ State = 'none'; Pid = $null } }
    $proc = Get-Process -Id $watchPid -ErrorAction SilentlyContinue
    if (-not $proc) { return @{ State = 'none'; Pid = $watchPid } }
    if ($proc.ProcessName -notin @('powershell','pwsh')) { return @{ State = 'foreign'; Pid = $watchPid } }
    $cmd = $null; $cimOk = $true
    try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$watchPid" -ErrorAction Stop).CommandLine }
    catch { $cimOk = $false }
    if (-not $cimOk -or $null -eq $cmd) { return @{ State = 'unknown'; Pid = $watchPid } }
    # Match our script only as the -File argument (not merely anywhere in the line)
    # AND require the -Daemon flag, so `powershell -File other.ps1 <ourpath> -Daemon`
    # is not mistaken for the daemon.
    $targetPaths = @($PSCommandPath)
    $installedWatch = Join-Path $scriptsDir 'clipwarp-watch.ps1'
    if ($targetPaths -notcontains $installedWatch) { $targetPaths += $installedWatch }
    $escaped = ($targetPaths | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $fileRe = '-File\s+"?(' + $escaped + ')"?(\s|$)'
    if (($cmd -match $fileRe) -and ($cmd -match '(^|\s)-Daemon(\s|$)')) { return @{ State = 'watcher'; Pid = $watchPid } }
    return @{ State = 'foreign'; Pid = $watchPid }
}

if ($Autostart) {
    try {
        $sh = New-Object -ComObject WScript.Shell
        $s  = $sh.CreateShortcut($startupLnk)
        $s.TargetPath  = 'powershell.exe'
        $s.Arguments   = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Daemon"
        $s.WindowStyle = 7                                   # minimized/hidden
        $s.Description  = 'clipwarp clipboard-image watcher for Claude Code'
        $s.Save()
        Write-Host "clipwarp watch: autostart enabled -> $startupLnk" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "clipwarp watch: failed to enable autostart - $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

if ($NoAutostart) {
    if (Test-Path -LiteralPath $startupLnk) {
        try { Remove-Item -LiteralPath $startupLnk -Force -ErrorAction Stop }
        catch { Write-Host "clipwarp watch: failed to remove autostart shortcut - $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    }
    Write-Host 'clipwarp watch: autostart disabled' -ForegroundColor Green
    exit 0
}

if ($Status) {
    $st = Get-WatchState
    $auto = if (Test-Path -LiteralPath $startupLnk) { 'on' } else { 'off' }
    switch ($st.State) {
        'watcher' {
            $verTxt = ''
            try {
                $verFile = Join-Path $scriptsDir 'version.json'
                if (Test-Path -LiteralPath $verFile) {
                    $ver = Get-Content -LiteralPath $verFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($ver.version) { $verTxt = " - v$($ver.version) ($($ver.date))" }
                }
            } catch {}
            Write-Host "clipwarp watch: running (pid $($st.Pid)) - autostart $auto$verTxt" -ForegroundColor Green; exit 0
        }
        'unknown' { Write-Host "clipwarp watch: unknown - a shell at pid $($st.Pid) could not be verified (autostart $auto)" -ForegroundColor Yellow; exit 2 }
        default   { Write-Host "clipwarp watch: not running - autostart $auto" -ForegroundColor Yellow; exit 1 }
    }
}

if ($Stop) {
    $st = Get-WatchState
    switch ($st.State) {
        'watcher' {
            try { Stop-Process -Id $st.Pid -Force -ErrorAction Stop }
            catch { Write-Host "clipwarp watch: failed to stop pid $($st.Pid) - $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            Write-Host "clipwarp watch: stopped (pid $($st.Pid))" -ForegroundColor Green
            exit 0
        }
        'unknown' {
            # A real watcher might be live; never kill blindly or clear its pid file.
            Write-Host "clipwarp watch: could not verify the process at pid $($st.Pid) - refusing to stop. Try again, or end it manually." -ForegroundColor Yellow
            exit 1
        }
        default {
            # none / foreign: our watcher is not running; clear a stale pid file.
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            Write-Host 'clipwarp watch: not running' -ForegroundColor Yellow
            exit 0
        }
    }
}

if ($Restart) {
    $st = Get-WatchState
    switch ($st.State) {
        'watcher' {
            try {
                $proc = Get-Process -Id $st.Pid -ErrorAction SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $st.Pid -Force -ErrorAction Stop
                    [void]$proc.WaitForExit(3000)
                }
            }
            catch {
                Write-Host "clipwarp watch: failed to stop pid $($st.Pid) - $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        }
        'unknown' {
            Write-Host "clipwarp watch: could not verify the process at pid $($st.Pid) - refusing to restart automatically. Run 'clipwarp stop' or end it manually first." -ForegroundColor Yellow
            exit 1
        }
        default {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        }
    }
    # Proceed to start mode below to spawn the new daemon
}

if (-not $Daemon) {
    # Start mode: spawn a hidden daemon and return.
    $st = Get-WatchState
    if ($st.State -eq 'watcher') { Write-Host "clipwarp watch: already running (pid $($st.Pid))" -ForegroundColor DarkGray; exit 0 }
    if ($st.State -eq 'unknown') {
        Write-Host "clipwarp watch: a shell at pid $($st.Pid) could not be verified; not starting a second watcher. Run 'clipwarp stop' or end it manually first." -ForegroundColor Yellow
        exit 1
    }
    $daemonCmd = "powershell.exe -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Daemon"
    $spawned = $false
    try {
        $wmi = [wmiclass]'Win32_Process'
        $res = $wmi.Create($daemonCmd)
        if ($res.ReturnValue -eq 0) { $spawned = $true }
    } catch {}
    if (-not $spawned) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-Daemon'
        ) | Out-Null
    }
    $started = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        $st = Get-WatchState
        if ($st.State -eq 'watcher') { $started = $true; break }
    }
    if ($started) {
        $verb = if ($Restart) { 'restarted' } else { 'started' }
        Write-Host "clipwarp watch: $verb (pid $($st.Pid))" -ForegroundColor Green
        Write-Host 'copy an image anywhere (Ctrl+C / snip), then Ctrl+V in Claude Code.' -ForegroundColor Cyan
        Write-Host "stop with: clipwarp stop" -ForegroundColor DarkGray
        exit 0
    }
    $verb = if ($Restart) { 'restart' } else { 'start' }
    Write-Host "clipwarp watch: failed to $verb (see $logFile)" -ForegroundColor Red
    exit 1
}

# ---------------- daemon mode ----------------

$mutex = New-Object System.Threading.Mutex($false, 'clipwarp-watch-singleton')
$ownsMutex = $false
try {
    $ownsMutex = $mutex.WaitOne(0, $false)
}
catch [System.Threading.AbandonedMutexException] {
    # If a prior daemon was killed abruptly, take ownership of the abandoned mutex.
    $ownsMutex = $true
}
if (-not $ownsMutex) { exit 1 }   # another daemon already owns the clipboard watch

New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
Set-Content -LiteralPath $pidFile -Value $PID

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Collections.Generic;

namespace ClipwarpWatch
{
    public static class IconHelper
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        public static Icon FromBitmap(Bitmap bmp)
        {
            IntPtr hIcon = bmp.GetHicon();
            try
            {
                using (Icon temp = Icon.FromHandle(hIcon))
                {
                    return (Icon)temp.Clone();
                }
            }
            finally
            {
                DestroyIcon(hIcon);
            }
        }
    }

    public class OverlayTargetTracker
    {
        public const int MaxRetentionSeconds = 12;

        public string RetainedProcess { get; private set; }
        public string RetainedTitle { get; private set; }
        public string RetainedClass { get; private set; }
        public DateTime RetainedAt { get; private set; }
        public bool HasRetainedTarget { get; private set; }
        private bool inOverlay;

        public OverlayTargetTracker()
        {
            Clear();
        }

        public void Clear()
        {
            RetainedProcess = "";
            RetainedTitle = "";
            RetainedClass = "";
            RetainedAt = DateTime.MinValue;
            HasRetainedTarget = false;
            inOverlay = false;
        }

        public void OnForegroundChanged(string proc, string title, string cls, DateTime now)
        {
            bool isOverlay = Watcher.IsOverlayProcess(proc);
            bool hasFg = !string.IsNullOrEmpty(proc) || !string.IsNullOrEmpty(title);

            if (isOverlay) {
                // Start the bound when capture begins, even after hours in one target.
                if (!inOverlay && HasRetainedTarget) RetainedAt = now;
                inOverlay = true;
                return;
            }
            if (!isOverlay)
            {
                Clear();
                if (!hasFg) return;
                RetainedProcess = proc ?? "";
                RetainedTitle = title ?? "";
                RetainedClass = cls ?? "";
                RetainedAt = now;
                HasRetainedTarget = true;
            }
        }

        public bool TryResolveTarget(string currentProc, string currentTitle, string currentCls, DateTime now,
            out string targetProc, out string targetTitle, out string targetCls)
        {
            targetProc = currentProc ?? "";
            targetTitle = currentTitle ?? "";
            targetCls = currentCls ?? "";

            if (Watcher.IsOverlayProcess(currentProc))
            {
                if (HasRetainedTarget && !string.IsNullOrEmpty(RetainedProcess))
                {
                    double elapsed = (now - RetainedAt).TotalSeconds;
                    if (elapsed >= 0 && elapsed <= MaxRetentionSeconds)
                    {
                        targetProc = RetainedProcess;
                        targetTitle = RetainedTitle;
                        targetCls = RetainedClass;
                        return true;
                    }
                    else
                    {
                        Clear();
                    }
                }
            }
            return false;
        }


    }

    // Pure policy: tests use fake layout handles, monotonic times and coordinates.
    public class LanguageState
    {
        public const int DisplayDurationMilliseconds = 1000;
        public const int CaretGapPixels = 6;
        private long previous;
        public long HideAt { get; private set; }
        public bool Observe(long layout, long now)
        {
            if (layout == 0) return false;
            if (previous == 0) { previous = layout; return false; }
            if (previous == layout) return false;
            previous = layout;
            HideAt = now + DisplayDurationMilliseconds;
            return true;
        }
        public bool Visible(long now) { return HideAt > now; }
        public static string Label(long layout)
        {
            int lang = (int)(layout & 0xffff);
            try {
                if (lang == 0 || lang == 0xffff) throw new ArgumentException();
                // Stable common labels across Windows NLS and .NET ICU versions.
                if (lang == 0x041e) return "TH — ไทย";
                if (lang == 0x0409) return "EN — English";
                var culture = System.Globalization.CultureInfo.GetCultureInfo(lang);
                return culture.TwoLetterISOLanguageName.ToUpperInvariant() + " — " + culture.NativeName;
            } catch (ArgumentException) { return "Language 0x" + lang.ToString("X4"); }
        }
        // Conversion stages are injectable so fake tests can model differing DPI scales.
        // Never scale an absolute desktop coordinate about (0,0): monitor origins differ.
        public static System.Drawing.Point? NormalizeCaret(System.Drawing.Point client,
            Func<System.Drawing.Point, System.Drawing.Point?> toScreen,
            Func<System.Drawing.Point, System.Drawing.Point?> toPhysical)
        {
            var screen = toScreen(client);
            return screen.HasValue ? toPhysical(screen.Value) : null;
        }
        public static System.Drawing.Point Position(bool caret, int cx, int cy,
            bool cursor, int mx, int my, int fx, int fy, int width, int height,
            System.Drawing.Rectangle work)
        {
            // Center above the normalized caret top with a gap; fallback keeps its offset.
            int x = caret ? cx - width / 2 : (cursor ? mx : fx) + 6;
            int y = caret ? cy - height - CaretGapPixels : (cursor ? my : fy) + 6;
            return new System.Drawing.Point(Math.Max(work.Left, Math.Min(x, work.Right - width)),
                Math.Max(work.Top, Math.Min(y, work.Bottom - height)));
        }
    }

    internal sealed class LanguageOverlay : Form
    {
        public LanguageOverlay()
        {
            FormBorderStyle = FormBorderStyle.None;
            TopMost = true;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = System.Drawing.Color.FromArgb(35, 35, 35);
            ForeColor = System.Drawing.Color.White;
            ClientSize = new System.Drawing.Size(220, 32);
            Opacity = 0.99; // WinForms initializes the layered surface, including recreated handles.
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get { CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00080000 | 0x00000020;
                // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT
                // Layered + transparent passes mouse input across thread/process boundaries.
                return cp;
            }
        }
        protected override void WndProc(ref Message m)
        {
            const int WM_NCHITTEST = 0x0084, HTTRANSPARENT = -1;
            if (m.Msg == WM_NCHITTEST) { m.Result = (IntPtr)HTTRANSPARENT; return; }
            const int WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;
            if (m.Msg == WM_MOUSEACTIVATE) { m.Result = (IntPtr)MA_NOACTIVATE; return; }
            base.WndProc(ref m);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }

    // Clipboard retries/process waits can block the watcher pump. Keep language
    // deadlines on a dedicated, idle STA pump; it never reads the clipboard.
    internal sealed class LanguageIndicatorHost : IDisposable
    {
        private readonly object gate = new object();
        private readonly System.Threading.Thread thread;
        private Control dispatcher;
        private bool stopping;
        public LanguageIndicatorHost(Action<string> report)
        {
            thread = new System.Threading.Thread(delegate() {
                IntPtr previousDpi = IntPtr.Zero;
                try {
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException, true);
                    previousDpi = LanguageIndicator.EnterPerMonitorDpi();
                    using (Control control = new Control()) {
                        IntPtr handle = control.Handle;
                        lock (gate) {
                            if (stopping) return;
                            dispatcher = control;
                        }
                        try {
                            using (LanguageIndicator indicator = new LanguageIndicator(previousDpi != IntPtr.Zero)) Application.Run();
                        } finally { lock (gate) { dispatcher = null; } }
                    }
                } catch (Exception ex) {
                    // One report, no retry loop; even a failing logger must not escape this thread.
                    try { report("language indicator stopped: " + ex.Message); } catch { }
                } finally { LanguageIndicator.RestoreDpi(previousDpi); }
            });
            thread.IsBackground = true;
            thread.Name = "clipwarp language indicator";
            thread.SetApartmentState(System.Threading.ApartmentState.STA);
            thread.Start();
        }
        public void Dispose()
        {
            lock (gate) {
                if (stopping) return;
                stopping = true;
                if (dispatcher != null) {
                    try { dispatcher.BeginInvoke((MethodInvoker)delegate { Application.ExitThread(); }); }
                    catch (InvalidOperationException) { } // pump may already be tearing down
                }
            }
            thread.Join(1000);
        }
    }

    // Only shortcut/modifier down bits are retained; no characters or text are captured.
    public sealed class LanguageShortcutState
    {
        private readonly bool[] down = new bool[256];
        private bool Shift { get { return down[0x10] || down[0xA0] || down[0xA1]; } }
        private bool Alt { get { return down[0x12] || down[0xA4] || down[0xA5]; } }
        private bool Ctrl { get { return down[0x11] || down[0xA2] || down[0xA3]; } }
        private bool Win { get { return down[0x5B] || down[0x5C]; } }
        public bool Observe(int message, int key)
        {
            bool press = message == 0x100 || message == 0x104;
            bool release = message == 0x101 || message == 0x105;
            if ((!press && !release) || key < 0 || key > 255) return false;
            bool shift = key == 0x10 || key == 0xA0 || key == 0xA1;
            bool alt = key == 0x12 || key == 0xA4 || key == 0xA5;
            if (!(shift || alt || key == 0x11 || key == 0xA2 || key == 0xA3 ||
                key == 0x5B || key == 0x5C || key == 0x20 || key == 0xC0)) return false;
            bool repeated = down[key];
            down[key] = press;
            if (!press || repeated) return false;
            return (key == 0xC0 && !Ctrl && !Alt && !Win) ||
                (key == 0x20 && Win) || (shift && Alt) || (alt && Shift);
        }
    }

    internal sealed class LanguageIndicator : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct GUITHREADINFO {
            public int cbSize; public uint flags;
            public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
            public RECT rcCaret;
        }
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint thread);
        [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
        [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
        [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] private static extern IntPtr GetWindowDpiAwarenessContext(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool LogicalToPhysicalPointForPerMonitorDPI(IntPtr hwnd, ref POINT point);
        internal static IntPtr EnterPerMonitorDpi()
        {
            try { return SetThreadDpiAwarenessContext(new IntPtr(-3)); } // PM v1: Windows 10 1607+
            catch (EntryPointNotFoundException) { return IntPtr.Zero; }
            catch (DllNotFoundException) { return IntPtr.Zero; }
        }
        internal static void RestoreDpi(IntPtr previous)
        {
            if (previous == IntPtr.Zero) return;
            try { SetThreadDpiAwarenessContext(previous); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
        }
        private readonly bool perMonitorDpi;
        private bool CaretToScreen(IntPtr hwnd, ref POINT point)
        {
            // rcCaret is in the target's logical client space, regardless of our DPI context.
            // Map in the target context, then convert its logical screen point to physical pixels.
            // Restore our PM context before any WinForms/Screen calls. Missing APIs skip the
            // caret and use GetCursorPos in the same context as Screen.WorkingArea instead.
            if (!perMonitorDpi) return false;
            IntPtr previous = IntPtr.Zero;
            try {
                IntPtr target = GetWindowDpiAwarenessContext(hwnd);
                if (target == IntPtr.Zero) return false;
                previous = SetThreadDpiAwarenessContext(target);
                if (previous == IntPtr.Zero) return false;
                var normalized = LanguageState.NormalizeCaret(new System.Drawing.Point(point.X, point.Y),
                    delegate(System.Drawing.Point p) {
                        POINT native = new POINT { X = p.X, Y = p.Y };
                        return ClientToScreen(hwnd, ref native) ? (System.Drawing.Point?)new System.Drawing.Point(native.X, native.Y) : null;
                    },
                    delegate(System.Drawing.Point p) {
                        POINT native = new POINT { X = p.X, Y = p.Y };
                        return LogicalToPhysicalPointForPerMonitorDPI(hwnd, ref native) ? (System.Drawing.Point?)new System.Drawing.Point(native.X, native.Y) : null;
                    });
                if (!normalized.HasValue) return false;
                point.X = normalized.Value.X; point.Y = normalized.Value.Y;
                return true;
            } catch (EntryPointNotFoundException) { return false; }
            catch (DllNotFoundException) { return false; }
            finally { RestoreDpi(previous); }
        }
        private delegate IntPtr KeyboardProc(int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int id, KeyboardProc callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_SHOWWINDOW = 0x0040;

        // Re-assert topmost z-order on every display: Show() on an already-visible
        // form does not bring it forward, so a newer topmost window (language
        // flyout, IME candidate, always-on-top app) would otherwise cover the label.
        // SWP_NOACTIVATE keeps it from stealing focus, like ShowWithoutActivation.
        private static void AssertTopmost(Form form)
        {
            try { SetWindowPos(form.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW); }
            catch { }
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)] private static extern IntPtr GetModuleHandle(string name);
        private readonly LanguageShortcutState shortcuts = new LanguageShortcutState();
        private readonly Control shortcutDispatcher = new Control();
        private readonly Timer probe = new Timer();
        private KeyboardProc keyboardProc;
        private IntPtr keyboardHook;
        private long probeUntil;
        private void InstallKeyboardSignal()
        {
            try {
                IntPtr handle = shortcutDispatcher.Handle; // created on the indicator UI thread
                keyboardProc = KeyboardSignal; // root delegate until unhooked
                keyboardHook = SetWindowsHookEx(13, keyboardProc, GetModuleHandle(null), 0); // WH_KEYBOARD_LL
            } catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            // A zero hook handle also leaves the independent 100 ms poll running.
        }
        private IntPtr KeyboardSignal(int code, IntPtr message, IntPtr data)
        {
            try {
                if (code >= 0 && !disposed && shortcuts.Observe(message.ToInt32(), Marshal.ReadInt32(data))) {
                    long deadline = clock.ElapsedMilliseconds + 150;
                    shortcutDispatcher.BeginInvoke((MethodInvoker)delegate {
                        if (disposed) return;
                        Poll(null, EventArgs.Empty);
                        probeUntil = deadline;
                        if (clock.ElapsedMilliseconds < probeUntil) probe.Start();
                    });
                }
            } catch { } // Never let observation/dispatch failure affect the user's input.
            return CallNextHookEx(keyboardHook, code, message, data);
        }
        private void Probe(object sender, EventArgs e)
        {
            if (disposed || clock.ElapsedMilliseconds >= probeUntil) { probe.Stop(); return; }
            Poll(null, EventArgs.Empty);
        }
        private readonly LanguageState state = new LanguageState();
        private readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        private readonly Timer poll = new Timer();
        private readonly Timer hide = new Timer();
        private LanguageOverlay overlay;
        private bool disposed;

        public LanguageIndicator(bool perMonitorDpi)
        {
            this.perMonitorDpi = perMonitorDpi;
            try {
                poll.Interval = 100;
                poll.Tick += Poll;
                hide.Tick += HideExpired;
                Poll(null, EventArgs.Empty); // baseline only; no form created until a change
                poll.Start();
                probe.Interval = 10;
                probe.Tick += Probe;
                InstallKeyboardSignal();
            } catch { Dispose(); throw; }
        }
        private void HideExpired(object sender, EventArgs e)
        {
            hide.Stop();
            long remaining = state.HideAt - clock.ElapsedMilliseconds;
            if (remaining > 0) { hide.Interval = (int)remaining; hide.Start(); }
            else if (overlay != null) overlay.Hide();
        }
        private void Poll(object sender, EventArgs e)
        {
            if (disposed) return;
            // Expiry is independent of availability of the foreground/caret/layout.
            if (overlay != null && !state.Visible(clock.ElapsedMilliseconds)) overlay.Hide();
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero || (overlay != null && fg == overlay.Handle)) return;
            uint pid;
            uint thread = GetWindowThreadProcessId(fg, out pid);
            if (thread == 0) return;
            long layout = GetKeyboardLayout(thread).ToInt64();
            if (fg != GetForegroundWindow()) return; // discard a racing foreground sample
            if (!state.Observe(layout, clock.ElapsedMilliseconds)) return;
            if (overlay == null) overlay = new LanguageOverlay();
            overlay.Text = LanguageState.Label(layout);
            overlay.ClientSize = new System.Drawing.Size(
                Math.Max(100, Math.Min(360, TextRenderer.MeasureText(overlay.Text, overlay.Font).Width + 24)), 32);
            GUITHREADINFO info = new GUITHREADINFO();
            info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
            POINT point = new POINT();
            bool caret = GetGUIThreadInfo(thread, ref info) && info.hwndCaret != IntPtr.Zero;
            if (caret) {
                point.X = info.rcCaret.Left; point.Y = info.rcCaret.Top;
                caret = CaretToScreen(info.hwndCaret, ref point);
            }
            POINT mouse = new POINT();
            bool cursor = !caret && GetCursorPos(out mouse);
            RECT rect;
            if (!GetWindowRect(fg, out rect)) rect = new RECT();
            System.Drawing.Point anchor = new System.Drawing.Point(caret ? point.X : cursor ? mouse.X : rect.Left,
                caret ? point.Y : cursor ? mouse.Y : rect.Top);
            overlay.Location = LanguageState.Position(caret, point.X, point.Y, cursor, mouse.X, mouse.Y,
                rect.Left, rect.Top, overlay.Width, overlay.Height, Screen.FromPoint(anchor).WorkingArea);
            overlay.Show();
            AssertTopmost(overlay);
            overlay.Invalidate();
            hide.Stop();
            HideExpired(null, EventArgs.Empty); // arm for the remaining deadline, never a fresh display duration
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (keyboardHook != IntPtr.Zero) {
                UnhookWindowsHookEx(keyboardHook);
                keyboardHook = IntPtr.Zero;
            }
            GC.KeepAlive(keyboardProc);
            probe.Stop(); probe.Tick -= Probe; probe.Dispose();
            shortcutDispatcher.Dispose();
            poll.Stop(); hide.Stop();
            poll.Tick -= Poll; hide.Tick -= HideExpired;
            poll.Dispose(); hide.Dispose();
            if (overlay != null) overlay.Dispose();
            clock.Stop();
        }
    }

    // Pure policy: circuit-breaker for repeated clipboard copies.
    // A clipboard listener fires on EVERY write, including rewrites of
    // identical content (clipboard managers, cloud sync, copy-back buttons),
    // and sequence numbers alone cannot tell a genuine new copy from a
    // repeated one. This guard fingerprints content and trips in two cases:
    //   burst - the same content hash appears BurstThreshold times inside
    //           BurstWindowMs: that fingerprint is suppressed for BurstCooldownMs.
    //   storm - StormThreshold clipboard events inside StormWindowMs, regardless
    //           of content: all handling pauses for StormCooldownMs.
    // Tests use fake fingerprints and a manual millisecond clock.
    public sealed class ClipboardBurstGuard
    {
        public const int BurstWindowMs = 60000;
        public const int BurstThreshold = 5;
        public const int BurstCooldownMs = 120000;
        public const int StormWindowMs = 10000;
        public const int StormThreshold = 30;
        public const int StormCooldownMs = 30000;
        private const int MaxTrackedFingerprints = 200;

        public enum Verdict { Allow, SuppressBurst, PauseStorm }

        private readonly Dictionary<string, Queue<long>> hits = new Dictionary<string, Queue<long>>();
        private readonly Dictionary<string, long> suppressedUntil = new Dictionary<string, long>();
        private readonly Queue<long> events = new Queue<long>();
        private long stormPausedUntil = 0;

        private static void Trim(Queue<long> q, long nowMs, long windowMs)
        {
            while (q.Count > 0 && nowMs - q.Peek() > windowMs) q.Dequeue();
        }

        // fingerprint may be null when the content could not be read (clipboard
        // busy): a null fingerprint only feeds the storm counter, never the
        // burst table.
        public Verdict Observe(string fingerprint, long nowMs)
        {
            Trim(events, nowMs, StormWindowMs);
            events.Enqueue(nowMs);
            if (nowMs < stormPausedUntil) return Verdict.PauseStorm;
            if (events.Count >= StormThreshold)
            {
                stormPausedUntil = nowMs + StormCooldownMs;
                return Verdict.PauseStorm;
            }
            if (string.IsNullOrEmpty(fingerprint)) return Verdict.Allow;
            long until;
            if (suppressedUntil.TryGetValue(fingerprint, out until))
            {
                if (nowMs < until) return Verdict.SuppressBurst;
                suppressedUntil.Remove(fingerprint);
            }
            Queue<long> q;
            if (!hits.TryGetValue(fingerprint, out q))
            {
                q = new Queue<long>();
                hits[fingerprint] = q;
            }
            Trim(q, nowMs, BurstWindowMs);
            q.Enqueue(nowMs);
            if (q.Count >= BurstThreshold)
            {
                suppressedUntil[fingerprint] = nowMs + BurstCooldownMs;
                hits.Remove(fingerprint);
                return Verdict.SuppressBurst;
            }
            if (hits.Count > MaxTrackedFingerprints)
            {
                List<string> stale = new List<string>();
                foreach (KeyValuePair<string, Queue<long>> kv in hits)
                {
                    Trim(kv.Value, nowMs, BurstWindowMs);
                    if (kv.Value.Count == 0) stale.Add(kv.Key);
                }
                foreach (string k in stale) hits.Remove(k);
            }
            return Verdict.Allow;
        }

        public void Reset()
        {
            hits.Clear();
            suppressedUntil.Clear();
            events.Clear();
            stormPausedUntil = 0;
        }

        // Stable, cheap content fingerprints. Text is hashed whole; images are
        // hashed from a bounded sample (head + tail + length) so giant
        // screenshots stay cheap while still distinguishing content.
        public static string FingerprintText(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            {
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(text);
                byte[] hash = sha.ComputeHash(bytes);
                return "T:" + BitConverter.ToString(hash).Replace("-", string.Empty);
            }
        }

        public static string FingerprintBytes(byte[] data)
        {
            if (data == null || data.Length == 0) return null;
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            {
                int head = Math.Min(data.Length, 65536);
                sha.TransformBlock(data, 0, head, null, 0);
                int tail = Math.Min(data.Length, 4096);
                if (tail > 0 && tail < data.Length) sha.TransformBlock(data, data.Length - tail, tail, null, 0);
                sha.TransformFinalBlock(BitConverter.GetBytes(data.Length), 0, 8);
                return "I:" + BitConverter.ToString(sha.Hash).Replace("-", string.Empty);
            }
        }
    }

    public class Watcher : NativeWindow
    {
        [DllImport("kernel32.dll")]
        private static extern void Sleep(uint dwMilliseconds);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")]
        private static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT point);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll")]
        private static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll")]
        private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventProc lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
        [DllImport("user32.dll")]
        private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

        private delegate void WinEventProc(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X; public int Y; }

        private const int WM_CLIPBOARDUPDATE = 0x031D;
        private static readonly Regex ImgExt = new Regex(@"\.(png|jpe?g|gif|webp|bmp)$", RegexOptions.IgnoreCase);
        private static readonly Regex HtmlFileUri = new Regex(@"file:///[^""'\s>]+\.(png|jpe?g|gif|webp|bmp)", RegexOptions.IgnoreCase);
        private static readonly Regex BrowserProcRegex = new Regex(@"^(chrome|msedge|firefox|brave|opera|vivaldi|arc|zen|waterfox|floorp|librewolf|thorium|chromium)$", RegexOptions.IgnoreCase);
        private static readonly Regex TerminalProcRegex = new Regex(@"^(windowsterminal|powershell|pwsh|cmd|conhost|mintty|bash|alacritty|wezterm|hyper|tabby)$", RegexOptions.IgnoreCase);
        private static readonly Regex IdeProcRegex = new Regex(@"^(code|cursor|windsurf|idea|idea64|pycharm|pycharm64|webstorm|webstorm64|phpstorm|phpstorm64|rider|rider64|clion|clion64|goland|goland64|rubymine|rubymine64|rustrover|rustrover64|datagrip|datagrip64|studio64|fleet)$", RegexOptions.IgnoreCase);
        private static readonly Regex IntegratedTermTitleRegex = new Regex(@"(^|[\s\-_–—|•·●:\[(])(terminal|claude|powershell|pwsh|cmd(\.exe)?|bash|zsh|wsl)([\s\-_–—|•·●:)\]]|$)", RegexOptions.IgnoreCase);
        private static readonly Regex FileDialogTitleRegex = new Regex(@"(^|[\s\-_–—|•·:\[(])(open|save|save\s*as|select(\s*a)?\s*file|choose(\s*a)?\s*file|upload(\s*a)?\s*file|file\s*upload|browse|select\s*folder|choose\s*folder|all\s*files|öffnen|speichern|speichern\s*unter|datei(en)?\s*auswählen|ouvrir|enregistrer|enregistrer\s*sous|sélectionner\s*un\s*fichier|choisir\s*un\s*fichier|abrir|guardar|guardar\s*como|seleccionar\s*archivo|elegir\s*archivo|apri|salva|salva\s*con\s*nome|seleziona\s*file|salvar|salvar\s*como|открыть|сохранить|сохранить\s*как|выбор\s*файла|выбрать\s*файл|開く|保存|名前を付けて保存|ファイルの選択|ファイルを開く|ファイルの保存|打开|另存为|选择文件|上传文件|瀏覽|開啟|儲存|另存新檔|選擇檔案|上傳檔案|열기|저장|다른\s*이름으로\s*저장|파일\s*선택|파일\s*열기|เปิด|บันทึก|บันทึกเป็น|เลือกไฟล์|เลือกโฟลเดอร์|อัปโหลด)([\s\-_–—|•·:)\]]|$)", RegexOptions.IgnoreCase);
        private static readonly Regex OverlayProcRegex = new Regex(@"^(SnippingTool|ScreenClippingHost|ShellExperienceHost|Lightshot|ShareX|clipwarp)$", RegexOptions.IgnoreCase);

        public static bool IsOverlayProcess(string proc)
        {
            if (string.IsNullOrEmpty(proc)) return false;
            return OverlayProcRegex.IsMatch(proc);
        }

        private readonly string scriptPath;
        private readonly string logPath;
        private readonly string popupPath;
        private readonly string configPath;
        private readonly LanguageIndicatorHost language;
        private readonly Timer debounce;
        private readonly WinEventProc winEventProc;
        private IntPtr winEventHook = IntPtr.Zero;
        private string lastManagedImagePath = null;
        private string currentPayloadMode = "dual";
        private System.Diagnostics.Process child;
        private System.Diagnostics.Process popupChild;
        private DateTime childStarted;
        private const int ChildTimeoutSec = 15;   // a conversion that runs longer is treated as hung
        private int busyRetries;                  // consecutive "clipboard busy" re-arms in this burst
        private int convFails;                    // consecutive failed conversions of the current clipboard
        private uint lastHandledSequence;
        private string lastTextFingerprint;
        private DateTime lastTextAt;
        private POINT eventPointer;
        private bool hasEventPointer;
        private IntPtr currentForegroundHwnd = IntPtr.Zero;
        private string foregroundProcess = "";
        private string foregroundTitle = "";
        private string foregroundClass = "";
        private readonly OverlayTargetTracker overlayTracker = new OverlayTargetTracker();
        private uint lastManagedSequence;
        private const int EventDelayMs = 75;
        private const int WatchdogDelayMs = 200;
        // Burst/storm circuit-breaker state (see ClipboardBurstGuard).
        private readonly ClipboardBurstGuard burstGuard = new ClipboardBurstGuard();
        private string lastContentFingerprint = null;
        private string burstLoggedFingerprint = null;
        private bool stormLogged = false;

        // Re-check soon instead of dropping the event (clipboard was busy, or a
        // conversion is still running). Bounded so a permanently-locked clipboard
        // can't spin forever - a genuinely new copy will re-fire the listener.
        private void Rearm()
        {
            if (++busyRetries > 20) { busyRetries = 0; debounce.Interval = EventDelayMs; return; }
            debounce.Interval = Math.Min(150 + busyRetries * 100, 2000);
            debounce.Start();
        }

        public Watcher(string script, string popup, string config, string log)
        {
            scriptPath = script;
            popupPath = popup;
            configPath = config;
            logPath = log;
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);              // HWND_MESSAGE: message-only window
            CreateHandle(cp);
            if (!AddClipboardFormatListener(this.Handle))
                throw new InvalidOperationException("AddClipboardFormatListener failed with Win32 error " + Marshal.GetLastWin32Error());
            winEventProc = new WinEventProc(OnWinEvent);
            winEventHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, winEventProc, 0, 0, WINEVENT_OUTOFCONTEXT);
            debounce = new Timer();
            debounce.Interval = EventDelayMs;      // coalesce format bursts without delaying the popup noticeably
            debounce.Tick += OnTick;
            CaptureForeground();
            language = new LanguageIndicatorHost(Log);
            Log("watch started, pid " + System.Diagnostics.Process.GetCurrentProcess().Id + ReadVersionSuffix());
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_CLIPBOARDUPDATE)
            {
                // Storm circuit-breaker: a flood of clipboard events pauses the
                // watcher briefly instead of arming work for every single one.
                // (A null fingerprint only feeds the storm counter, never the
                // burst table.)
                long nowMs = DateTime.UtcNow.Ticks / 10000;
                if (BurstGuardEnabled() &&
                    burstGuard.Observe(null, nowMs) == ClipboardBurstGuard.Verdict.PauseStorm)
                {
                    if (!stormLogged)
                    {
                        stormLogged = true;
                        Log("clipboard storm detected - pausing clipboard handling for 30s");
                    }
                }
                else
                {
                    stormLogged = false;
                    // A clipboard change: give it a full, fresh retry budget
                    // (don't inherit a previous burst's exhausted counter).
                    // convFails is reset only when the content actually changes
                    // (see Inspect) so an event flood can't wash the budget away.
                    busyRetries = 0;
                    POINT captured;
                    hasEventPointer = GetCursorPos(out captured);
                    if (hasEventPointer) eventPointer = captured;
                    CaptureForeground();
                    debounce.Interval = EventDelayMs;
                    debounce.Stop();
                    debounce.Start();
                }
            }
            base.WndProc(ref m);
        }

        private void OnTick(object sender, EventArgs e)
        {
            debounce.Stop();
            try { Inspect(); }
            catch (Exception ex) { Log("error: " + ex.Message); convFails++; if (convFails < 3) { debounce.Interval = 500; debounce.Start(); } }  // bounded retry, then wait for a new copy
        }

        private void OnWinEvent(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime)
        {
            if (eventType == EVENT_SYSTEM_FOREGROUND && hwnd != IntPtr.Zero)
            {
                CaptureForegroundFromHwnd(hwnd);
                OnForegroundWindowChanged();
            }
        }

        private void CaptureForeground()
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd != IntPtr.Zero) CaptureForegroundFromHwnd(hwnd);
        }

        private void CaptureForegroundFromHwnd(IntPtr hwnd)
        {
            try
            {
                currentForegroundHwnd = hwnd;
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                string pName = "";
                try { pName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
                StringBuilder sbCls = new StringBuilder(256);
                GetClassName(hwnd, sbCls, sbCls.Capacity);
                string cls = sbCls.ToString();
                StringBuilder sb = new StringBuilder(512);
                GetWindowText(hwnd, sb, sb.Capacity);
                string title = sb.ToString();

                foregroundProcess = pName ?? "";
                foregroundTitle = title ?? "";
                foregroundClass = cls ?? "";

                overlayTracker.OnForegroundChanged(foregroundProcess, foregroundTitle, foregroundClass, DateTime.UtcNow);
            }
            catch { }
        }

        private bool IsPaused()
        {
            try { return File.Exists(configPath) && Regex.IsMatch(File.ReadAllText(configPath), @"""paused""\s*:\s*true", RegexOptions.IgnoreCase); }
            catch { return true; }
        }

        private string ConfiguredTargetMode()
        {
            try
            {
                if (!File.Exists(configPath)) return "auto";
                string json = File.ReadAllText(configPath, Encoding.UTF8);
                Match m = Regex.Match(json, "\\\"targetMode\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase);
                if (m.Success) return m.Groups[1].Value.Trim().ToLowerInvariant();
            }
            catch { }
            return "auto";
        }

        private bool IsFilePickerForeground()
        {
            try
            {
                string proc = foregroundProcess ?? "";
                if (proc.Equals("PickerHost", StringComparison.OrdinalIgnoreCase)) return true;

                IntPtr hwnd = currentForegroundHwnd;
                string cls = foregroundClass ?? "";
                string title = foregroundTitle ?? "";

                bool isBrowser = proc.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase) || BrowserProcRegex.IsMatch(proc);
                bool isIde = IdeProcRegex.IsMatch(proc);

                if (cls.Equals("#32770", StringComparison.OrdinalIgnoreCase))
                {
                    if (string.IsNullOrEmpty(title) || FileDialogTitleRegex.IsMatch(title)) return true;

                    if (hwnd != IntPtr.Zero)
                    {
                        bool hasShellControls = false;
                        EnumChildWindows(hwnd, (child, lParam) =>
                        {
                            StringBuilder sb = new StringBuilder(128);
                            GetClassName(child, sb, sb.Capacity);
                            string c = sb.ToString();
                            if (c.Equals("SHELLDLL_DefView", StringComparison.OrdinalIgnoreCase) ||
                                c.Equals("Address Band Root", StringComparison.OrdinalIgnoreCase) ||
                                c.Equals("NamespaceTreeControl", StringComparison.OrdinalIgnoreCase))
                            {
                                hasShellControls = true;
                                return false;
                            }
                            return true;
                        }, IntPtr.Zero);

                        if (hasShellControls) return true;
                    }
                }

                if (!isBrowser && !isIde && !string.IsNullOrEmpty(title) && FileDialogTitleRegex.IsMatch(title))
                {
                    return true;
                }
            }
            catch { }
            return false;
        }

        private bool IsTerminalForeground()
        {
            string proc = foregroundProcess ?? "";
            string title = foregroundTitle ?? "";
            if (string.IsNullOrEmpty(proc) && string.IsNullOrEmpty(title)) return false;
            if (proc.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase) || BrowserProcRegex.IsMatch(proc)) return false;
            if (TerminalProcRegex.IsMatch(proc)) return true;
            if (IdeProcRegex.IsMatch(proc))
            {
                return !string.IsNullOrEmpty(title) && IntegratedTermTitleRegex.IsMatch(title);
            }
            if (!string.IsNullOrEmpty(title) && IntegratedTermTitleRegex.IsMatch(title)) return true;
            return false;
        }

        private bool IsManagedClipboardActive() { return VerifyClipboardSafety(lastManagedImagePath); }

        public static bool IsClipboardOwnershipValid(uint currentSeq, uint managedSeq, IDataObject dataObj, string expectedPath, out uint updatedSeq)
        {
            updatedSeq = managedSeq;
            if (string.IsNullOrEmpty(expectedPath) || currentSeq == 0) return false;

            if (managedSeq != 0 && currentSeq == managedSeq)
            {
                return true;
            }

            if (dataObj != null)
            {
                try
                {
                    if (dataObj.GetDataPresent("ClipwarpManaged"))
                    {
                        string marker = ClipwarpTransport.ClipboardWriter.Marker(dataObj);
                        if (!string.IsNullOrEmpty(marker) && string.Equals(marker, expectedPath, StringComparison.OrdinalIgnoreCase))
                        {
                            updatedSeq = currentSeq;
                            return true;
                        }
                    }
                }
                catch { }
            }

            return false;
        }

        private bool VerifyClipboardSafety(string expectedPath)
        {
            if (IsPaused()) return false;
            uint currentSeq = GetClipboardSequenceNumber();
            IDataObject d = null;
            if (lastManagedSequence == 0 || currentSeq != lastManagedSequence)
            {
                try { d = Clipboard.GetDataObject(); } catch { }
            }

            if (currentSeq != GetClipboardSequenceNumber()) return false;
            uint updatedSeq;
            if (IsClipboardOwnershipValid(currentSeq, lastManagedSequence, d, expectedPath, out updatedSeq))
            {
                lastManagedSequence = updatedSeq;
                return true;
            }

            Log("newer non-clipwarp clipboard detected (seq " + currentSeq + " != " + lastManagedSequence + ") - aborting target switch");
            lastManagedImagePath = null;
            lastManagedSequence = 0;
            return false;
        }

        private void OnForegroundWindowChanged()
        {
            if (IsPaused()) return;
            if (IsOverlayProcess(foregroundProcess)) return;

            if (string.IsNullOrEmpty(lastManagedImagePath) || !File.Exists(lastManagedImagePath)) return;

            string targetMode = ConfiguredTargetMode();
            if (targetMode.Equals("text", StringComparison.OrdinalIgnoreCase)) return;

            if (!IsManagedClipboardActive()) return;

            if (targetMode.Equals("chatgpt", StringComparison.OrdinalIgnoreCase) || targetMode.Equals("image-only", StringComparison.OrdinalIgnoreCase) || targetMode.Equals("web", StringComparison.OrdinalIgnoreCase))
            {
                if (currentPayloadMode != "image-only") SetClipboardImageOnly(lastManagedImagePath);
                return;
            }
            if (targetMode.Equals("claude", StringComparison.OrdinalIgnoreCase) || targetMode.Equals("dual", StringComparison.OrdinalIgnoreCase))
            {
                if (currentPayloadMode != "dual") SetClipboardDual(lastManagedImagePath);
                return;
            }

            // Auto mode per user rule:
            // Paste as file path if:
            // 1. File picker in Windows
            // 2. Terminal / Claude Code (WindowsTerminal, powershell, pwsh, cmd)
            // Paste as image:
            // - Everything else
            bool isFilePicker = IsFilePickerForeground();
            bool isTerm = IsTerminalForeground();

            if (isFilePicker || isTerm)
            {
                if (currentPayloadMode != "dual")
                {
                    SetClipboardDual(lastManagedImagePath);
                }
            }
            else
            {
                if (currentPayloadMode != "image-only")
                {
                    SetClipboardImageOnly(lastManagedImagePath);
                }
            }
        }

        private void SetClipboardImageOnly(string path)
        {
            for (int retry = 0; retry < 5; retry++)
            {
                if (!VerifyClipboardSafety(path)) return;

                try
                {
                    if (!File.Exists(path)) return;
                    byte[] bytes = File.ReadAllBytes(path);
                    DataObject doObj = new DataObject();
                    doObj.SetData("ClipwarpManaged", path);
                    doObj.SetData("PNG", false, new MemoryStream(bytes));
                    using (MemoryStream ms = new MemoryStream(bytes))
                    {
                        using (var bmp = new System.Drawing.Bitmap(ms))
                        {
                            doObj.SetImage(bmp);

                            if (!VerifyClipboardSafety(path)) return;

                            lastManagedSequence = ClipwarpTransport.ClipboardWriter.Publish(doObj, lastManagedSequence);
                        }
                    }
                    currentPayloadMode = "image-only";
                    lastHandledSequence = lastManagedSequence;
                    Log("switched clipboard to image-only (paste as image)");
                    return;
                }
                catch { Sleep(50); }
            }
        }

        private void SetClipboardDual(string path)
        {
            for (int retry = 0; retry < 5; retry++)
            {
                if (!VerifyClipboardSafety(path)) return;

                try
                {
                    if (!File.Exists(path)) return;
                    byte[] bytes = File.ReadAllBytes(path);
                    DataObject doObj = new DataObject();
                    doObj.SetData(DataFormats.UnicodeText, path);
                    doObj.SetData("ClipwarpManaged", path);
                    doObj.SetData("PNG", false, new MemoryStream(bytes));
                    using (MemoryStream ms = new MemoryStream(bytes))
                    {
                        using (var bmp = new System.Drawing.Bitmap(ms))
                        {
                            doObj.SetImage(bmp);
                            var sc = new System.Collections.Specialized.StringCollection();
                            sc.Add(path);
                            doObj.SetFileDropList(sc);

                            if (!VerifyClipboardSafety(path)) return;

                            lastManagedSequence = ClipwarpTransport.ClipboardWriter.Publish(doObj, lastManagedSequence);
                        }
                    }
                    currentPayloadMode = "dual";
                    lastHandledSequence = lastManagedSequence;
                    Log("switched clipboard to dual (file picker / terminal target)");
                    return;
                }
                catch { Sleep(50); }
            }
        }

        private void Inspect()
        {
            uint sequence = GetClipboardSequenceNumber();
            // The same clipboard notification is ignored only when no conversion
            // child needs watchdog/reaping work.
            if (child == null && sequence != 0 && sequence == lastHandledSequence) return;
            // Observe any conversion child: keep polling while it runs, reap it if
            // it hangs, and inspect its exit code when it finishes so a failed or
            // hung conversion is retried a bounded number of times (never forever).
            if (child != null)
            {
                if (!child.HasExited)
                {
                    if ((DateTime.Now - childStarted).TotalSeconds < ChildTimeoutSec)
                    {
                        debounce.Interval = WatchdogDelayMs; // watchdog poll until it finishes/hangs
                        debounce.Start();
                        return;
                    }
                    try { child.Kill(); child.WaitForExit(1000); } catch { }
                    Log("previous conversion hung -> killed");
                    convFails++;
                }
                else
                {
                    int code = -1;
                    try { code = child.ExitCode; } catch { }
                    if (code == 0) { convFails = 0; }
                    else { convFails++; Log("conversion exited with code " + code); }
                }
                try { child.Dispose(); } catch { }
                child = null;
            }

            if (IsPaused()) { lastHandledSequence = sequence; lastManagedImagePath = null; lastManagedSequence = 0; return; }

            // If the current clipboard keeps failing to convert, stop relaunching
            // until a new copy arrives (WM_CLIPBOARDUPDATE resets convFails).
            if (convFails >= 3)
            {
                if (convFails == 3) { convFails++; Log("conversion failing repeatedly - waiting for a new clipboard copy"); }
                return;
            }

            // Check for our own ClipwarpManaged payload:
            IDataObject dObj = null;
            try { dObj = Clipboard.GetDataObject(); } catch { Rearm(); return; }
            if (dObj != null && dObj.GetDataPresent("ClipwarpManaged"))
            {
                string mPath = ClipwarpTransport.ClipboardWriter.Marker(dObj);
                if (sequence != GetClipboardSequenceNumber()) { Rearm(); return; }
                if (!string.IsNullOrEmpty(mPath) && File.Exists(mPath))
                {
                    lastManagedImagePath = mPath;
                    lastHandledSequence = sequence;
                    lastManagedSequence = sequence;
                    busyRetries = 0;
                    debounce.Interval = EventDelayMs;
                    currentPayloadMode = (dObj.GetDataPresent(DataFormats.UnicodeText) || dObj.GetDataPresent(DataFormats.Text)) ? "dual" : "image-only";
                    OnForegroundWindowChanged(); // reconcile a target change during conversion
                    return;
                }
            }

            // Burst circuit-breaker: identical clipboard content re-appearing
            // many times in a short window (clipboard managers, cloud sync,
            // copy-back buttons) is suppressed instead of processed forever.
            // Our own ClipwarpManaged writes returned above and never reach
            // this table. convFails is a per-content budget: it resets only
            // when the content actually changes, so an event flood of the same
            // content can't wash the failure budget away.
            if (BurstGuardEnabled())
            {
                string contentFp = FingerprintClipboard(dObj);
                if (contentFp != lastContentFingerprint) { convFails = 0; lastContentFingerprint = contentFp; }
                long nowMs = DateTime.UtcNow.Ticks / 10000;
                ClipboardBurstGuard.Verdict burstVerdict = burstGuard.Observe(contentFp, nowMs);
                if (burstVerdict == ClipboardBurstGuard.Verdict.SuppressBurst)
                {
                    if (burstLoggedFingerprint != contentFp)
                    {
                        burstLoggedFingerprint = contentFp;
                        string shortFp = contentFp != null && contentFp.Length > 14 ? contentFp.Substring(0, 14) : contentFp;
                        Log("repeated identical clipboard detected (" + shortFp + ") - suppressing for 2 minutes");
                    }
                    lastHandledSequence = sequence;
                    lastManagedImagePath = null;
                    lastManagedSequence = 0;
                    busyRetries = 0;
                    debounce.Interval = EventDelayMs;
                    return;
                }
                if (burstVerdict == ClipboardBurstGuard.Verdict.Allow) burstLoggedFingerprint = null;
                else // PauseStorm: re-armed while a storm pause is active
                {
                    lastHandledSequence = sequence;
                    return;
                }
            }

            string txt = null;
            try { if (Clipboard.ContainsText()) txt = Clipboard.GetText(); }
            catch { Rearm(); return; }                         // clipboard busy -> retry soon, don't drop it
            if (!string.IsNullOrEmpty(txt))
            {
                string p = txt.Trim().Trim('"');
                if (ImgExt.IsMatch(p) && File.Exists(p)) {
                    busyRetries = 0;
                    debounce.Interval = EventDelayMs;
                    lastManagedImagePath = null;
                    lastHandledSequence = sequence;
                    lastManagedSequence = 0;
                    currentPayloadMode = "dual";
                    return;
                }  // our own write / usable path
                string meaningful = txt.Trim();
                if (meaningful.Length > 0)
                {
                    if (meaningful == lastTextFingerprint && (DateTime.Now - lastTextAt).TotalSeconds < 2)
                    { lastHandledSequence = sequence; return; }
                    LaunchTextPopup(txt);
                    lastTextFingerprint = meaningful;
                    lastTextAt = DateTime.Now;
                    lastHandledSequence = sequence;
                    lastManagedImagePath = null;
                    lastManagedSequence = 0;
                    busyRetries = 0;
                    debounce.Interval = EventDelayMs;
                    Log("text on clipboard -> calendar popup");
                    return;
                }
            }

            int payload = HasImagePayload();
            if (payload < 0) { Rearm(); return; }              // clipboard busy -> retry soon
            if (payload == 0) { busyRetries = 0; debounce.Interval = EventDelayMs; return; }
            lastHandledSequence = sequence;
            lastManagedImagePath = null;
            lastManagedSequence = 0;

            debounce.Interval = EventDelayMs;
            var psi = new System.Diagnostics.ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + scriptPath + "\" -Quiet -KeepImage" + TargetArguments() + PointerArguments();
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            child = System.Diagnostics.Process.Start(psi);
            childStarted = DateTime.Now;
            // Arm the watchdog: re-enter Inspect on the timer so a hung child is
            // reaped after ChildTimeoutSec even if no further clipboard event ever
            // fires (a child that hangs before writing produces no WM_CLIPBOARDUPDATE).
            debounce.Interval = WatchdogDelayMs;
            debounce.Start();
            Log("image on clipboard -> converting");
        }

        private string PointerArguments()
        {
            return hasEventPointer ? " -PointerX " + eventPointer.X + " -PointerY " + eventPointer.Y : "";
        }

        private string TargetArguments()
        {
            string proc = foregroundProcess;
            string title = foregroundTitle;
            string cls = foregroundClass;

            string resProc, resTitle, resCls;
            if (overlayTracker.TryResolveTarget(proc, title, cls, DateTime.UtcNow, out resProc, out resTitle, out resCls))
            {
                proc = resProc;
                title = resTitle;
                cls = resCls;
            }

            if (string.IsNullOrEmpty(proc) && string.IsNullOrEmpty(title)) return "";
            string safeProc = (proc ?? "").Replace("\"", "").Replace("'", "").Replace(";", "").Replace("$", "");
            string safeTitle = (title ?? "").Replace("\"", "").Replace("'", "").Replace(";", "").Replace("$", "").Replace("`", "");
            string safeCls = (cls ?? "").Replace("\"", "").Replace("'", "").Replace(";", "").Replace("$", "");
            if (safeTitle.Length > 100) safeTitle = safeTitle.Substring(0, 100);
            return " -ForegroundProcess \"" + safeProc + "\" -ForegroundTitle \"" + safeTitle + "\" -ForegroundClass \"" + safeCls + "\"";
        }

        private void LaunchTextPopup(string title)
        {
            if (!CalendarEnabled()) return;
            CloseOwnedPopup();
            CleanupTitleFiles();
            var psi = new System.Diagnostics.ProcessStartInfo();
            psi.FileName = "powershell.exe";
            byte[] titleBytes = Encoding.UTF8.GetBytes(title);
            string titleFile = null;
            if (titleBytes.Length > 6000)
            {
                titleFile = Path.Combine(Path.GetDirectoryName(configPath), "clipwarp-title-" + Guid.NewGuid().ToString("N") + ".txt");
                Directory.CreateDirectory(Path.GetDirectoryName(configPath));
                File.WriteAllText(titleFile, title);
                psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + popupPath + "\" -Kind Text -TitleFile \"" + titleFile + "\"" + PointerArguments();
            }
            else
            {
                string encoded = Convert.ToBase64String(titleBytes);
                psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + popupPath + "\" -Kind Text -TitleBase64 " + encoded + PointerArguments();
            }
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            try { popupChild = System.Diagnostics.Process.Start(psi); }
            catch { if (titleFile != null) { try { File.Delete(titleFile); } catch { } } throw; }
        }

        private void CloseOwnedPopup()
        {
            try { if (popupChild != null && !popupChild.HasExited) { popupChild.Kill(); popupChild.WaitForExit(1000); Log("replaced previous calendar popup"); } } catch { }
            try { if (popupChild != null) popupChild.Dispose(); } catch { }
            popupChild = null;
        }

        private void CleanupTitleFiles()
        {
            try {
                string dir = Path.GetDirectoryName(configPath); if (!Directory.Exists(dir)) return;
                int examined = 0, removed = 0;
                foreach (string path in Directory.GetFiles(dir, "clipwarp-title-*.txt")) {
                    if (++examined > 100) break;
                    string name = Path.GetFileName(path);
                    if (Regex.IsMatch(name, "^clipwarp-title-[0-9a-f]{32}\\.txt$") && File.GetLastWriteTimeUtc(path) < DateTime.UtcNow.AddDays(-1)) { try { File.Delete(path); removed++; } catch { } }
                }
                if (removed > 0) Log("removed " + removed + " orphaned calendar title file(s)");
            } catch { }
        }

        private bool CalendarEnabled()
        {
            try
            {
                if (!File.Exists(configPath)) return true;
                string json = File.ReadAllText(configPath, Encoding.UTF8);
                Match m = Regex.Match(json, "\\\"calendar\\\"\\s*:\\s*\\{[^}]*\\\"enabled\\\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
                return !m.Success || !string.Equals(m.Groups[1].Value, "false", StringComparison.OrdinalIgnoreCase);
            }
            catch { return true; }
        }

        // Kill-switch for the burst/storm guard, read from the same config
        // file as the other watcher settings. Defaults to enabled; set
        // "burstGuard": false in %USERPROFILE%\.claude\clipwarp.json to disable.
        private bool BurstGuardEnabled()
        {
            try
            {
                if (!File.Exists(configPath)) return true;
                string json = File.ReadAllText(configPath, Encoding.UTF8);
                Match m = Regex.Match(json, "\\\"burstGuard\\\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
                return !m.Success || !string.Equals(m.Groups[1].Value, "false", StringComparison.OrdinalIgnoreCase);
            }
            catch { return true; }
        }

        // Cheap content fingerprint for the burst guard: text is hashed whole,
        // images from their PNG bytes (falling back to a BMP encode of the
        // bitmap). Returns null when the content could not be read.
        private string FingerprintClipboard(IDataObject d)
        {
            if (d == null) return null;
            try
            {
                if (d.GetDataPresent(DataFormats.UnicodeText))
                {
                    string t = null;
                    try { t = d.GetData(DataFormats.UnicodeText) as string; } catch { }
                    string tfp = ClipboardBurstGuard.FingerprintText(t);
                    if (tfp != null) return tfp;
                }
                byte[] pngBytes = null;
                try
                {
                    if (d.GetDataPresent("PNG"))
                    {
                        object o = d.GetData("PNG");
                        MemoryStream ms = o as MemoryStream;
                        if (ms != null) pngBytes = ms.ToArray();
                        else if (o is byte[]) pngBytes = (byte[])o;
                    }
                }
                catch { }
                if (pngBytes == null)
                {
                    try
                    {
                        if (d.GetDataPresent(DataFormats.Bitmap))
                        {
                            Image img = d.GetData(DataFormats.Bitmap) as Image;
                            if (img != null)
                            {
                                using (MemoryStream ms = new MemoryStream())
                                {
                                    img.Save(ms, System.Drawing.Imaging.ImageFormat.Bmp);
                                    pngBytes = ms.ToArray();
                                }
                                img.Dispose();
                            }
                        }
                    }
                    catch { }
                }
                string ifp = ClipboardBurstGuard.FingerprintBytes(pngBytes);
                if (ifp != null) return ifp;
            }
            catch { }
            return null;
        }

        // Tri-state: 1 = an image payload is present, 0 = none, -1 = clipboard
        // was busy (couldn't tell) so the caller should retry rather than drop.
        private int HasImagePayload()
        {
            IDataObject d = null;
            try { d = Clipboard.GetDataObject(); }
            catch { return -1; }
            if (d == null) return -1;
            try
            {
                if (d.GetDataPresent(DataFormats.Bitmap, true)) return 1;
                if (d.GetDataPresent("PNG") || d.GetDataPresent("image/png") || d.GetDataPresent("Format17")) return 1;
                if (d.GetDataPresent(DataFormats.FileDrop))
                {
                    string[] files = d.GetData(DataFormats.FileDrop) as string[];
                    if (files != null)
                        foreach (string f in files)
                            if (ImgExt.IsMatch(f)) return 1;
                }
                if (d.GetDataPresent(DataFormats.Html))
                {
                    string html = d.GetData(DataFormats.Html) as string;
                    if (html != null && (html.IndexOf("data:image/", StringComparison.OrdinalIgnoreCase) >= 0 || HtmlFileUri.IsMatch(html))) return 1;
                }
            }
            catch { return -1; }   // read raced with another writer; retry
            return 0;
        }

        public void Shutdown()
        {
            language.Dispose();
            try { RemoveClipboardFormatListener(this.Handle); } catch { }
            if (winEventHook != IntPtr.Zero)
            {
                try { UnhookWinEvent(winEventHook); } catch { }
                winEventHook = IntPtr.Zero;
            }
            CloseOwnedPopup();
            Log("watch stopped");
        }

        // Installed version stamp (version.json next to the scripts, written by
        // install.ps1). Empty when unavailable; keeps the startup log line
        // honest about which code the watcher is actually running.
        private string ReadVersionSuffix()
        {
            try
            {
                string dir = Path.GetDirectoryName(scriptPath);
                if (string.IsNullOrEmpty(dir)) return "";
                string v = Path.Combine(dir, "version.json");
                if (!File.Exists(v)) return "";
                string json = File.ReadAllText(v, Encoding.UTF8);
                Match m = Regex.Match(json, "\\\"version\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase);
                if (!m.Success) return "";
                Match d = Regex.Match(json, "\\\"date\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase);
                return ", version " + m.Groups[1].Value + (d.Success ? " (" + d.Groups[1].Value + ")" : "");
            }
            catch { return ""; }
        }

        private void Log(string msg)
        {
            try
            {
                if (File.Exists(logPath) && new FileInfo(logPath).Length > 200000) File.WriteAllText(logPath, "");
                File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
            }
            catch { }
        }
    }
}
'@
if ($PSVersionTable.PSEdition -eq 'Core') {
    # Prefer compilation contracts over runtime facades (notably System.Collections).
    $references = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
    $references += @([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
    $references += [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
    Add-Type -TypeDefinition ($src + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-clipboard.cs'))) -ReferencedAssemblies ($references | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
}
else {
    Add-Type -TypeDefinition ($src + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-clipboard.cs'))) -ReferencedAssemblies @('System', 'System.Windows.Forms', 'System.Drawing')
}

$watcher = New-Object ClipwarpWatch.Watcher($clipwarpPath, $calendarPopupPath, $configPath, $logFile)

function Get-ClipwarpTrayIcon {
    param([string]$ScriptDir, [string]$ScriptsDir)
    $candidatePaths = @(
        (Join-Path $ScriptDir 'assets\favicon.png'),
        (Join-Path $ScriptDir 'favicon.png'),
        (Join-Path $ScriptsDir 'favicon.png')
    )
    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) {
            try {
                $bmp = [System.Drawing.Bitmap]::FromFile($path)
                $icon = [ClipwarpWatch.IconHelper]::FromBitmap($bmp)
                $bmp.Dispose()
                return $icon
            } catch { }
        }
    }
    return [System.Drawing.SystemIcons]::Application
}

$trayIcon = $null
try {
    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon.Icon = Get-ClipwarpTrayIcon -ScriptDir $PSScriptRoot -ScriptsDir $scriptsDir
    $trayIcon.Text = "ClipWarp - Clipboard Bridge"

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $headerItem = New-Object System.Windows.Forms.ToolStripMenuItem("ClipWarp (pid $PID)")
    $headerItem.Enabled = $false
    [void]$contextMenu.Items.Add($headerItem)

    [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $watchScriptPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $scriptsDir 'clipwarp-watch.ps1' }

    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem("Restart ClipWarp")
    $boldFont = New-Object System.Drawing.Font($restartItem.Font, [System.Drawing.FontStyle]::Bold)
    $restartItem.Font = $boldFont
    $restartItem.add_Click({
        try {
            if ($trayIcon) { $trayIcon.Visible = $false }
            $currPid = $PID
            $restartScript = @"
`$p = Get-Process -Id $currPid -ErrorAction SilentlyContinue
if (`$p) { [void]`$p.WaitForExit(3000) }
Start-Sleep -Milliseconds 250
& '$watchScriptPath' -Restart
"@
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                '-Command', $restartScript
            ) | Out-Null
        } catch { }
        finally {
            [System.Windows.Forms.Application]::Exit()
        }
    })
    [void]$contextMenu.Items.Add($restartItem)

    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem("Status")
    $statusItem.add_Click({
        try {
            $autoState = if (Test-Path -LiteralPath $startupLnk) { 'Enabled' } else { 'Disabled' }
            $msg = "ClipWarp is running (PID: $PID)`nAutostart: $autoState"
            $trayIcon.ShowBalloonTip(3000, "ClipWarp Status", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    })
    [void]$contextMenu.Items.Add($statusItem)

    # Every user-facing command gets a tray UI entry too (repo convention):
    # pause toggle and version, mirroring the `clipwarp` CLI.
    $pauseItem = New-Object System.Windows.Forms.ToolStripMenuItem("Pause ClipWarp")
    $updatePauseText = {
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            if (Get-ClipwarpPaused) { $pauseItem.Text = "Resume ClipWarp" } else { $pauseItem.Text = "Pause ClipWarp" }
        } catch { }
    }
    & $updatePauseText
    $pauseItem.add_Click({
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            if (Get-ClipwarpPaused) {
                Set-ClipwarpPaused -Paused $false
                $pauseItem.Text = "Pause ClipWarp"
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Resumed", [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                Set-ClipwarpPaused -Paused $true
                $pauseItem.Text = "Resume ClipWarp"
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Paused - click Resume to continue", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } catch { }
    })
    [void]$contextMenu.Items.Add($pauseItem)

    $versionItem = New-Object System.Windows.Forms.ToolStripMenuItem("Version")
    $versionItem.add_Click({
        try {
            $verTxt = 'unknown (re-run install.ps1)'
            $verFile = Join-Path $scriptsDir 'version.json'
            if (Test-Path -LiteralPath $verFile) {
                $v = Get-Content -LiteralPath $verFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($v.version) { $verTxt = "v$($v.version) ($($v.date))" }
            }
            $trayIcon.ShowBalloonTip(3000, "ClipWarp Version", $verTxt, [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    })
    [void]$contextMenu.Items.Add($versionItem)

    # Target mode submenu - mirrors `clipwarp target <mode>|status`.
    $targetMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Target mode")
    $targetItems = @{}
    foreach ($tm in @(('auto','Auto'),('web','Web (image only)'),('chatgpt','ChatGPT'),('image-only','Image only'),('claude','Claude (dual)'),('dual','Dual'),('text','Text only'))) {
        $tItem = New-Object System.Windows.Forms.ToolStripMenuItem($tm[1])
        $tItem.Tag = $tm[0]
        $tItem.add_Click({
            try {
                Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
                $m = [string]$this.Tag
                [void](Set-ClipwarpTargetMode -Mode $m)
                foreach ($k in $targetItems.Keys) { $targetItems[$k].Checked = ($k -eq $m) }
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Target mode: $m", [System.Windows.Forms.ToolTipIcon]::Info)
            } catch { }
        })
        $targetItems[$tm[0]] = $tItem
        [void]$targetMenu.DropDownItems.Add($tItem)
    }
    $targetMenu.add_DropDownOpened({
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            $cur = Get-ClipwarpTargetMode
            foreach ($k in $targetItems.Keys) { $targetItems[$k].Checked = ($k -eq $cur) }
        } catch { }
    })
    [void]$contextMenu.Items.Add($targetMenu)

    # Calendar prompts toggle - mirrors `clipwarp calendar enable|disable`.
    $calItem = New-Object System.Windows.Forms.ToolStripMenuItem("Calendar prompts")
    $updateCalText = {
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            $calItem.Text = if (Get-ClipwarpCalendarEnabled) { "Calendar prompts: On" } else { "Calendar prompts: Off" }
        } catch { }
    }
    & $updateCalText
    $calItem.add_Click({
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            if (Get-ClipwarpCalendarEnabled) {
                [void](Set-ClipwarpCalendarEnabled -Enabled $false)
                $calItem.Text = "Calendar prompts: Off"
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Calendar prompts off (image conversion still active)", [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                [void](Set-ClipwarpCalendarEnabled -Enabled $true)
                $calItem.Text = "Calendar prompts: On"
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Calendar prompts on", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } catch { }
    })
    [void]$contextMenu.Items.Add($calItem)

    # Privacy submenu (retention) - mirrors `clipwarp privacy retention <days>`.
    $privacyMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Privacy")
    $retentionItems = @{}
    foreach ($rd in @((7,'7 days'),(30,'30 days'),(90,'90 days'),(0,'Keep forever'))) {
        $rItem = New-Object System.Windows.Forms.ToolStripMenuItem(('Retention: ' + $rd[1]))
        $rItem.Tag = $rd[0]
        $rItem.add_Click({
            try {
                Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
                $d = [int]$this.Tag
                [void](Set-ClipwarpRetentionDays -Days $d)
                foreach ($k in $retentionItems.Keys) { $retentionItems[$k].Checked = ([int]$k -eq $d) }
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Image retention: $d day(s) (0 = keep forever)", [System.Windows.Forms.ToolTipIcon]::Info)
            } catch { }
        })
        $retentionItems[[string]$rd[0]] = $rItem
        [void]$privacyMenu.DropDownItems.Add($rItem)
    }
    $privacyMenu.add_DropDownOpened({
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            $curDays = Get-ClipwarpRetentionDays
            foreach ($k in $retentionItems.Keys) { $retentionItems[$k].Checked = ([int]$k -eq $curDays) }
        } catch { }
    })
    [void]$contextMenu.Items.Add($privacyMenu)

    # Autostart toggle - mirrors `clipwarp autostart|unautostart`. The shortcut
    # is managed inline (never by re-invoking this script: its `exit` would
    # kill the daemon host).
    $autoItem = New-Object System.Windows.Forms.ToolStripMenuItem("Autostart")
    $updateAutoText = {
        if (Test-Path -LiteralPath $startupLnk) { $autoItem.Text = "Autostart: On" } else { $autoItem.Text = "Autostart: Off" }
    }
    & $updateAutoText
    $autoItem.add_Click({
        try {
            if (Test-Path -LiteralPath $startupLnk) {
                Remove-Item -LiteralPath $startupLnk -Force -ErrorAction Stop
                $autoItem.Text = "Autostart: Off"
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Autostart off", [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $sh = New-Object -ComObject WScript.Shell
                $s = $sh.CreateShortcut($startupLnk)
                $s.TargetPath = 'powershell.exe'
                $daemonPath = Join-Path $scriptsDir 'clipwarp-watch.ps1'
                $s.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$daemonPath`" -Daemon"
                $s.WindowStyle = 7
                $s.Description = 'clipwarp clipboard-image watcher for Claude Code'
                $s.Save()
                $autoItem.Text = "Autostart: On"
                $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Autostart on - watcher starts with Windows", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } catch { }
    })
    [void]$contextMenu.Items.Add($autoItem)

    # Clean old images - mirrors `clipwarp clean` (default 7 days).
    $cleanItem = New-Object System.Windows.Forms.ToolStripMenuItem("Clean old images")
    $cleanItem.add_Click({
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            $outDir = Join-Path $env:USERPROFILE '.claude\pasted-images'
            $removed = @(Clear-ClipwarpHistory -OutDir $outDir -Before (Get-Date).AddDays(-7) -Confirm:$false)
            $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Removed $($removed.Count) image(s) older than 7 days", [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    })
    [void]$contextMenu.Items.Add($cleanItem)

    # Diagnostics - mirrors `clipwarp doctor`, summarized in a balloon tip.
    $doctorItem = New-Object System.Windows.Forms.ToolStripMenuItem("Run diagnostics")
    $doctorItem.add_Click({
        try {
            Import-Module (Join-Path $scriptsDir 'clipwarp-support.psm1') -Force -ErrorAction Stop
            $outDir = Join-Path $env:USERPROFILE '.claude\pasted-images'
            $results = @(Test-ClipwarpEnvironment -ScriptRoot $scriptsDir -OutDir $outDir)
            $bad = @($results | Where-Object { $_.Status -ne 'OK' })
            if ($bad.Count -eq 0) {
                $trayIcon.ShowBalloonTip(3000, "ClipWarp diagnostics", "All checks passed", [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $names = ($bad | ForEach-Object { $_.Name }) -join ', '
                $trayIcon.ShowBalloonTip(5000, "ClipWarp diagnostics", "$($bad.Count) check(s) need attention: $names", [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        } catch { }
    })
    [void]$contextMenu.Items.Add($doctorItem)

    $imagesDir = Join-Path $env:USERPROFILE '.claude\pasted-images'
    $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open Images Folder")
    $folderItem.add_Click({
        try {
            if (-not (Test-Path -LiteralPath $imagesDir)) {
                New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null
            }
            Start-Process explorer.exe -ArgumentList "`"$imagesDir`""
        } catch { }
    })
    [void]$contextMenu.Items.Add($folderItem)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem("View Log")
    $logItem.add_Click({
        try {
            if (Test-Path -LiteralPath $logFile) {
                Start-Process notepad.exe -ArgumentList "`"$logFile`""
            }
        } catch { }
    })
    [void]$contextMenu.Items.Add($logItem)

    [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit ClipWarp")
    $exitItem.add_Click({
        [System.Windows.Forms.Application]::Exit()
    })
    [void]$contextMenu.Items.Add($exitItem)

    $trayIcon.ContextMenuStrip = $contextMenu

    $trayIcon.add_DoubleClick({
        try {
            $autoState = if (Test-Path -LiteralPath $startupLnk) { 'Enabled' } else { 'Disabled' }
            $trayIcon.ShowBalloonTip(3000, "ClipWarp", "Running (PID: $PID) - Autostart: $autoState", [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    })

    $trayIcon.Visible = $true
} catch { }

$cleanupScript = {
    try {
        if ($trayIcon) {
            $trayIcon.Visible = $false
            $trayIcon.Dispose()
        }
        if ($watcher) { $watcher.Shutdown() }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        if ($ownsMutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
    } catch { }
}

[System.AppDomain]::CurrentDomain.add_ProcessExit({ & $cleanupScript })

try {
    [System.Windows.Forms.Application]::Run()   # message pump; blocks until the process is killed
}
finally {
    & $cleanupScript
}
