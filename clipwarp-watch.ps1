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

.USAGE
    clipwarp watch      # start (detached, hidden)
    clipwarp status     # is it running?
    clipwarp stop       # stop
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Status,
    [switch]$Autostart,    # register a login shortcut so the watcher starts at sign-in
    [switch]$NoAutostart,  # remove that login shortcut
    [switch]$Daemon        # internal: run the listener loop in THIS process
)

$scriptsDir = Join-Path $env:USERPROFILE '.claude\scripts'
if ((Split-Path $PSScriptRoot -Leaf) -match '^v-[a-f0-9]{32}$' -and (Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf) -eq 'versions') { $scriptsDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$watchLaunchPath = $PSCommandPath
if ([IO.File]::Exists((Join-Path $scriptsDir 'active-version.json'))) { $watchLaunchPath = Join-Path $scriptsDir 'clipwarp-watch.ps1' }
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
    $versionsRoot = Join-Path $scriptsDir 'versions'
    if (Test-Path -LiteralPath $versionsRoot -PathType Container) {
        foreach ($versionDir in Get-ChildItem -LiteralPath $versionsRoot -Directory -ErrorAction SilentlyContinue) {
            if ($versionDir.Name -match '^v-[a-f0-9]{32}$' -and -not ($versionDir.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [IO.File]::Exists((Join-Path $versionDir.FullName 'installed-manifest.json'))) {
                $targetPaths += Join-Path $versionDir.FullName 'clipwarp-watch.ps1'
            }
        }
    }
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
        $s.Arguments   = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchLaunchPath`" -Daemon"
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
        'watcher' { Write-Host "clipwarp watch: running (pid $($st.Pid)) - autostart $auto" -ForegroundColor Green; exit 0 }
        'unknown' { Write-Host "clipwarp watch: unknown - a shell at pid $($st.Pid) could not be verified (autostart $auto)" -ForegroundColor Yellow; exit 2 }
        default   { Write-Host "clipwarp watch: not running - autostart $auto" -ForegroundColor Yellow; exit 1 }
    }
}

if ($Stop) {
    $st = Get-WatchState
    switch ($st.State) {
        'watcher' {
            $owned = Get-Process -Id $st.Pid -ErrorAction Stop
            $startTicks = $owned.StartTime.ToUniversalTime().Ticks
            $stopEvent = $null
            try {
                $eventName = 'Local\Clipwarp-watch-stop-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $stopEvent = [Threading.EventWaitHandle]::OpenExisting($eventName)
                $null = $stopEvent.Set()
            } catch { } finally { if ($stopEvent) { $stopEvent.Dispose() } }
            if (-not $owned.WaitForExit(8000)) {
                # Fallback only after timeout and a fresh command-line AND start-time identity check.
                $again = Get-WatchState
                $live = Get-Process -Id $st.Pid -ErrorAction SilentlyContinue
                if ($again.State -ne 'watcher' -or $again.Pid -ne $st.Pid -or -not $live -or $live.StartTime.ToUniversalTime().Ticks -ne $startTicks) {
                    Write-Host 'clipwarp watch: identity changed while stopping; refusing force stop' -ForegroundColor Yellow
                    exit 1
                }
                try { $owned.Kill(); $null = $owned.WaitForExit(2000) }
                catch { Write-Host "clipwarp watch: failed to stop pid $($st.Pid) - $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
            }
            $owned.Dispose()
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

if (-not $Daemon) {
    # Start mode: spawn a hidden daemon and return.
    $st = Get-WatchState
    if ($st.State -eq 'watcher') { Write-Host "clipwarp watch: already running (pid $($st.Pid))" -ForegroundColor DarkGray; exit 0 }
    if ($st.State -eq 'unknown') {
        Write-Host "clipwarp watch: a shell at pid $($st.Pid) could not be verified; not starting a second watcher. Run 'clipwarp stop' or end it manually first." -ForegroundColor Yellow
        exit 1
    }
    $daemonCmd = "powershell.exe -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchLaunchPath`" -Daemon"
    $spawned = $false
    try {
        $wmi = [wmiclass]'Win32_Process'
        $res = $wmi.Create($daemonCmd)
        if ($res.ReturnValue -eq 0) { $spawned = $true }
    } catch {}
    if (-not $spawned) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$watchLaunchPath`"", '-Daemon'
        ) | Out-Null
    }
    $started = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        $st = Get-WatchState
        if ($st.State -eq 'watcher') { $started = $true; break }
    }
    if ($started) {
        Write-Host "clipwarp watch: started (pid $($st.Pid))" -ForegroundColor Green
        Write-Host 'copy an image anywhere (Ctrl+C / snip), then Ctrl+V in Claude Code.' -ForegroundColor Cyan
        Write-Host "stop with: clipwarp stop" -ForegroundColor DarkGray
        exit 0
    }
    Write-Host "clipwarp watch: failed to start (see $logFile)" -ForegroundColor Red
    exit 1
}

# ---------------- daemon mode ----------------

$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = New-Object System.Threading.Mutex($false, ('Local\clipwarp-watch-singleton-' + $userSid))
if (-not $mutex.WaitOne(0)) { exit 1 }   # another daemon already owns the clipboard watch

New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
Set-Content -LiteralPath $pidFile -Value $PID

Add-Type -AssemblyName System.Windows.Forms

$src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ClipwarpWatch
{
    // At most one pending foreground and clipboard snapshot. No unbounded work queue.
    public sealed class CoalescingStaWorker : IDisposable
    {
        private readonly object gate = new object();
        private readonly System.Threading.AutoResetEvent wake = new System.Threading.AutoResetEvent(false);
        private readonly System.Threading.Thread thread;
        private Action foreground, clipboard;
        private DateTime due = DateTime.MaxValue;
        private bool stopping;
        public int Interval { get; set; }
        public event EventHandler Tick;
        public Action Cleanup;
        public CoalescingStaWorker() {
            thread = new System.Threading.Thread(Run);
            thread.IsBackground = true;
            thread.Name = "ClipWarp image STA";
            thread.SetApartmentState(System.Threading.ApartmentState.STA);
            thread.Start();
        }
        public bool IsStopping { get { lock(gate) return stopping; } }
        public void EnqueueForeground(Action action) { lock(gate) { if(stopping) return; foreground=action; wake.Set(); } }
        public void EnqueueClipboard(Action action) { lock(gate) { if(stopping) return; clipboard=action; wake.Set(); } }
        public void Start() { lock(gate) { if(stopping) return; due=DateTime.UtcNow.AddMilliseconds(Interval); wake.Set(); } }
        public void Stop() { lock(gate) due=DateTime.MaxValue; }
        private void Run() {
            try {
                while(true) {
                    Action fg=null, clip=null; bool tick=false; int wait=System.Threading.Timeout.Infinite;
                    lock(gate) {
                        if(stopping) break;
                        fg=foreground; foreground=null; clip=clipboard; clipboard=null;
                        if(due != DateTime.MaxValue) {
                            double remaining=(due-DateTime.UtcNow).TotalMilliseconds;
                            if(remaining<=0) { tick=true; due=DateTime.MaxValue; }
                            else wait=(int)Math.Min(int.MaxValue,Math.Max(1,remaining));
                        }
                    }
                    if(fg!=null) fg();
                    if(IsStopping) break;
                    if(clip!=null) clip();
                    if(IsStopping) break;
                    if(tick && Tick!=null) Tick(this,EventArgs.Empty);
                    if(fg==null && clip==null && !tick) wake.WaitOne(wait);
                }
            } finally { if(Cleanup!=null) Cleanup(); }
        }
        public bool Shutdown(int timeout) {
            lock(gate) { stopping=true; foreground=null; clipboard=null; due=DateTime.MaxValue; wake.Set(); }
            return thread.Join(timeout);
        }
        public void Dispose() { if(Shutdown(3000)) wake.Dispose(); }
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
        private readonly CoalescingStaWorker debounce;
        private long targetGeneration;
        private long activeTargetGeneration;
        private volatile bool stopping;
        private readonly System.Threading.EventWaitHandle shutdownEvent;
        private readonly System.Threading.RegisteredWaitHandle shutdownWait;
        private ClipwarpImages.ImagePayload cachedImage;
        private string cachedImagePath;
        private System.Collections.Generic.Dictionary<uint, byte[]> cachedDual, cachedImageOnly;
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
        private const int WM_STOP = 0x8001;
        public static string UserEventName {
            get { return "Local\\Clipwarp-watch-stop-" + System.Security.Principal.WindowsIdentity.GetCurrent().User.Value; }
        }
        private readonly WinEventProc winEventProc;
        private IntPtr winEventHook = IntPtr.Zero;
        private string lastManagedImagePath = null;
        private string currentPayloadMode = "dual";
        private System.Diagnostics.Process child;
        private System.Diagnostics.Process popupChild;
        private System.Diagnostics.Process warmPopupHost;
        private Stream warmPopupPipe;
        private long popupRequestId = 0;
        private DateTime warmPopupStarted;
        private int warmPopupRestarts = 0;
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
            debounce = new CoalescingStaWorker();
            debounce.Cleanup = CleanupWorker;
            shutdownEvent = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, UserEventName);
            shutdownEvent.Reset();
            shutdownWait = System.Threading.ThreadPool.RegisterWaitForSingleObject(shutdownEvent,
                delegate(object state, bool timedOut) { PostMessage(this.Handle, WM_STOP, IntPtr.Zero, IntPtr.Zero); }, null, -1, true);
            debounce.Interval = EventDelayMs;      // coalesce format bursts without delaying the popup noticeably
            debounce.Tick += OnTick;
            CaptureForeground();
            StartWarmPopupHostAsync();
            Log("watch started, pid " + System.Diagnostics.Process.GetCurrentProcess().Id);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_STOP) { Shutdown(); Application.ExitThread(); return; }
            if (!stopping && m.Msg == WM_CLIPBOARDUPDATE)
            {
                POINT captured;
                bool hasPointer = GetCursorPos(out captured);
                CaptureForeground();
                debounce.EnqueueClipboard(delegate {
                    busyRetries = 0; convFails = 0;
                    hasEventPointer = hasPointer;
                    if (hasPointer) eventPointer = captured;
                    debounce.Interval = EventDelayMs;
                    debounce.Stop(); debounce.Start();
                });
            }
            base.WndProc(ref m);
        }

        private void OnTick(object sender, EventArgs e)
        {
            debounce.Stop();
            try { Inspect(); }
            catch (Exception ex) { Log("error: " + ex.GetType().Name); convFails++; if (convFails < 3) { debounce.Interval = 500; debounce.Start(); } }  // bounded retry, then wait for a new copy
        }

        private void OnWinEvent(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime)
        {
            if (eventType == EVENT_SYSTEM_FOREGROUND && hwnd != IntPtr.Zero)
            {
                QueueForeground(hwnd);
            }
        }

        private void CaptureForeground()
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd != IntPtr.Zero) QueueForeground(hwnd);
        }

        private void QueueForeground(IntPtr hwnd)
        {
            if (stopping) return;
            var clock = System.Diagnostics.Stopwatch.StartNew();
            long generation = System.Threading.Interlocked.Increment(ref targetGeneration);
            debounce.EnqueueForeground(delegate {
                if (generation != System.Threading.Interlocked.Read(ref targetGeneration)) return;
                activeTargetGeneration = generation;
                CaptureForegroundFromHwnd(hwnd);
                try { OnForegroundWindowChanged(); }
                catch (Exception ex) { Log("foreground error: " + ex.GetType().Name); }
                Log("foreground queue+work ms=" + clock.ElapsedMilliseconds);
            });
        }

        private void CaptureForegroundFromHwnd(IntPtr hwnd)
        {
            try
            {
                currentForegroundHwnd = hwnd;
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                string pName = "";
                try { using (var process = System.Diagnostics.Process.GetProcessById((int)pid)) pName = process.ProcessName; } catch { }
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

        public sealed class ValidatedSettings {
            public bool Paused;
            public bool CalendarEnabled = true;
            public string TargetMode = "auto";
            public ClipwarpImages.ImageLimits ImageLimits = new ClipwarpImages.ImageLimits();
        }
        // Pure C# provider: worker threads must not invoke PowerShell scriptblock delegates.
        public static Func<string, ValidatedSettings> SettingsProvider = LoadSharedSettings;
        private static ValidatedSettings LoadSharedSettings(string path) {
            var config = ClipwarpPolicy.ConfigStore.Read(path);
            var limits = new ClipwarpImages.ImageLimits();
            limits.MaxSourceBytes = Convert.ToInt64(ClipwarpPolicy.ConfigStore.Get(config.Data,"imageLimits.maxSourceBytes",limits.MaxSourceBytes));
            limits.MaxDimension = Convert.ToInt32(ClipwarpPolicy.ConfigStore.Get(config.Data,"imageLimits.maxDimension",limits.MaxDimension));
            limits.MaxWidth = Convert.ToInt32(ClipwarpPolicy.ConfigStore.Get(config.Data,"imageLimits.maxWidth",limits.MaxWidth));
            limits.MaxHeight = Convert.ToInt32(ClipwarpPolicy.ConfigStore.Get(config.Data,"imageLimits.maxHeight",limits.MaxHeight));
            limits.MaxPixels = Convert.ToInt64(ClipwarpPolicy.ConfigStore.Get(config.Data,"imageLimits.maxPixels",limits.MaxPixels));
            limits.MaxDecodedBytes = Convert.ToInt64(ClipwarpPolicy.ConfigStore.Get(config.Data,"imageLimits.maxDecodedBytes",limits.MaxDecodedBytes));
            limits.Validate();
            return new ValidatedSettings { Paused=config.Paused, CalendarEnabled=config.ActionsEnabled, TargetMode=config.TargetMode, ImageLimits=limits };
        }
        private ValidatedSettings ReadSettings() {
            try {
                if (SettingsProvider != null) {
                    var settings = SettingsProvider(configPath);
                    if (settings == null) throw new InvalidDataException("Unavailable settings");
                    settings.ImageLimits.Validate();
                    switch(settings.TargetMode) {
                        case "auto": case "text": case "claude": case "dual": case "chatgpt": case "image-only": case "web": return settings;
                        default: throw new InvalidDataException("Invalid target mode");
                    }
                }
                if (!File.Exists(configPath)) return new ValidatedSettings();
            } catch { }
            Log("configuration unavailable or invalid: automatic work paused");
            return new ValidatedSettings { Paused = true, CalendarEnabled = false };
        }
        private bool IsPaused() { return ReadSettings().Paused; }

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

            var snapshot = ClipwarpPolicy.ConfigStore.Read(configPath);
            var captured = ClipwarpPolicy.TargetPolicy.CaptureForeground();
            string targetMode = ClipwarpPolicy.TargetPolicy.Explain(snapshot,"auto",false,false,
                foregroundProcess,foregroundTitle,foregroundClass,
                captured.ProcessName == foregroundProcess && captured.HasFilePickerControls).Mode;
            if (targetMode.Equals("text", StringComparison.OrdinalIgnoreCase)) {
                if (currentPayloadMode != "text") PublishCached(lastManagedImagePath,"text");
                return;
            }

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

            // Shared TargetPolicy already normalized auto/global/process rules above.
        }

        private void ClearPayloadCache()
        {
            if (cachedImage != null) cachedImage.Dispose();
            cachedImage = null; cachedImagePath = null; cachedDual = null; cachedImageOnly = null;
        }

        private void PreparePayloadCache(string path)
        {
            if (cachedImagePath == path && cachedImage != null) return;
            ClearPayloadCache();
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var payload = ClipwarpImages.ImageHelper.FromFile(path, CurrentImageLimits());
            try {
                using (var bitmap = payload.CreateBitmap())
                using (var png = new MemoryStream(payload.GetPngBytes(), false)) {
                    var data = new DataObject();
                    data.SetData("ClipwarpManaged", path);
                    data.SetData("PNG", false, png);
                    data.SetImage(bitmap);
                    cachedImageOnly = ClipwarpTransport.ClipboardWriter.PrepareNative(data);
                    data.SetData(DataFormats.UnicodeText, path);
                    data.SetData(DataFormats.FileDrop, new string[] { path });
                    // Image formats are immutable and shared between the two cache views.
                    cachedDual = new System.Collections.Generic.Dictionary<uint, byte[]>(cachedImageOnly);
                    var fileData = new DataObject();
                    fileData.SetData(DataFormats.UnicodeText, path);
                    fileData.SetData(DataFormats.FileDrop, new string[] { path });
                    foreach (var item in ClipwarpTransport.ClipboardWriter.PrepareNative(fileData)) cachedDual[item.Key] = item.Value;
                }
                cachedImage = payload; cachedImagePath = path;
                Log("image preparation ms=" + clock.ElapsedMilliseconds + " bytes=" + payload.ByteLength);
            } catch { payload.Dispose(); ClearPayloadCache(); throw; }
        }

        // Integration point for the shared validated JSON config helper. The provider
        // runs on the STA worker and must be a C# delegate (not a PowerShell scriptblock).
        public static Func<string, ClipwarpImages.ImageLimits> ImageLimitsProvider;
        private ClipwarpImages.ImageLimits CurrentImageLimits() {
            var limits = ImageLimitsProvider == null ? ReadSettings().ImageLimits : ImageLimitsProvider(configPath);
            if (limits == null) throw new InvalidDataException("Image configuration is unavailable");
            limits.Validate();
            return limits;
        }
        private void SetClipboardImageOnly(string path) { PublishCached(path, "image-only"); }
        private void SetClipboardDual(string path) { PublishCached(path, "dual"); }
        private void PublishCached(string path, string mode)
        {
            long generation = activeTargetGeneration;
            if (stopping || !VerifyClipboardSafety(path)) return;
            PreparePayloadCache(path);
            var formats = mode == "dual" ? cachedDual : cachedImageOnly;
            if (mode == "text") {
                var textData = new DataObject();
                textData.SetData(DataFormats.UnicodeText,path);
                textData.SetData("ClipwarpManaged",path);
                formats = ClipwarpTransport.ClipboardWriter.PrepareNative(textData);
            }
            for (int retry = 0; retry < 5 && !stopping && !debounce.IsStopping; retry++) {
                if (generation != System.Threading.Interlocked.Read(ref targetGeneration) || !VerifyClipboardSafety(path)) return;
                try {
                    lastManagedSequence = ClipwarpTransport.ClipboardWriter.PublishPrepared(
                        formats, lastManagedSequence,
                        delegate { return !stopping && generation == System.Threading.Interlocked.Read(ref targetGeneration); });
                    currentPayloadMode = mode;
                    lastHandledSequence = lastManagedSequence;
                    Log("switched clipboard mode=" + mode);
                    return;
                } catch (InvalidOperationException ex) {
                    if (ex.Message == "clipboard-changed" || ex.Message == "target-changed") return;
                    System.Threading.Thread.Sleep(50);
                }
            }
        }

        private void Inspect()
        {
            if (stopping || debounce.IsStopping) return;
            uint sequence = GetClipboardSequenceNumber();
            if (lastManagedSequence != 0 && sequence != lastManagedSequence) ClearPayloadCache();
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

            string txt = null;
            try { if (Clipboard.ContainsText()) txt = Clipboard.GetText(); }
            catch { Rearm(); return; }                         // clipboard busy -> retry soon, don't drop it
            if (sequence != GetClipboardSequenceNumber()) { Rearm(); return; }
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
                    LaunchTextPopup(txt,sequence);
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
            var captured = ClipwarpPolicy.TargetPolicy.CaptureForeground();
            var decision = ClipwarpPolicy.TargetPolicy.Explain(ClipwarpPolicy.ConfigStore.Read(configPath),"auto",false,true,
                proc,title,cls,captured.ProcessName == proc && captured.HasFilePickerControls);
            // Only the resolved enum crosses the process boundary, never a sensitive caption.
            return " -TargetMode " + decision.Mode;
        }

        private void StartWarmPopupHostAsync()
        {
            System.Threading.ThreadPool.QueueUserWorkItem(delegate {
                try { EnsureWarmPopupHost(); } catch { }
            });
        }

        private bool EnsureWarmPopupHost()
        {
            if (stopping) return false;
            if (warmPopupHost != null && !warmPopupHost.HasExited && warmPopupPipe != null) return true;
            try
            {
                if (warmPopupRestarts > 5 && (DateTime.Now - warmPopupStarted).TotalSeconds < 30)
                {
                    Log("warm popup host restarted too frequently; falling back to direct launch");
                    return false;
                }
                CloseWarmPopupHost();
                var psi = new System.Diagnostics.ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + popupPath + "\" -HostMode";
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                psi.RedirectStandardInput = true;
                warmPopupHost = System.Diagnostics.Process.Start(psi);
                warmPopupPipe = warmPopupHost.StandardInput.BaseStream;
                warmPopupStarted = DateTime.Now;
                warmPopupRestarts++;
                Log("warm popup host started, pid " + warmPopupHost.Id);
                return true;
            }
            catch (Exception ex)
            {
                Log("failed to start warm popup host: " + ex.GetType().Name);
                return false;
            }
        }

        private void CloseWarmPopupHost()
        {
            try { if (warmPopupPipe != null) { warmPopupPipe.Dispose(); warmPopupPipe = null; } } catch { }
            try
            {
                if (warmPopupHost != null && !warmPopupHost.HasExited)
                {
                    warmPopupHost.Kill();
                    warmPopupHost.WaitForExit(500);
                }
            }
            catch { }
            try { if (warmPopupHost != null) warmPopupHost.Dispose(); } catch { }
            warmPopupHost = null;
        }

        private void LaunchTextPopup(string title,uint expectedSequence)
        {
            if (!CalendarEnabled()) return;
            if (EnsureWarmPopupHost())
            {
                try
                {
                    var req = new ClipwarpPopupHost.PopupRequest();
                    req.RequestId = System.Threading.Interlocked.Increment(ref popupRequestId);
                    req.Text = title;
                    req.ExpectedSequence = expectedSequence;
                    req.HasPointer = hasEventPointer;
                    if (hasEventPointer)
                    {
                        req.PointerX = eventPointer.X;
                        req.PointerY = eventPointer.Y;
                    }
                    byte[] payload = req.Serialize();
                    warmPopupPipe.Write(payload, 0, payload.Length);
                    warmPopupPipe.Flush();
                    return;
                }
                catch (Exception ex)
                {
                    Log("warm popup send failed (" + ex.GetType().Name + "), falling back to cold start");
                    CloseWarmPopupHost();
                }
            }

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
                var ancestor = new DirectoryInfo(Path.GetDirectoryName(configPath));
                while (ancestor != null) {
                    if ((ancestor.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Refusing redirected transport directory");
                    ancestor = ancestor.Parent;
                }
                var security = new System.Security.AccessControl.FileSecurity();
                security.SetAccessRuleProtection(true,false);
                security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
                    System.Security.Principal.WindowsIdentity.GetCurrent().User,
                    System.Security.AccessControl.FileSystemRights.FullControl,
                    System.Security.AccessControl.AccessControlType.Allow));
                using (var transport = new FileStream(titleFile,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                    var method = typeof(FileStream).GetMethod("SetAccessControl",new Type[]{typeof(System.Security.AccessControl.FileSecurity)});
                    if (method != null) method.Invoke(transport,new object[]{security});
                    else {
                        var extensions = Type.GetType("System.IO.FileSystemAclExtensions, System.IO.FileSystem.AccessControl",true);
                        extensions.GetMethod("SetAccessControl",new Type[]{typeof(FileStream),typeof(System.Security.AccessControl.FileSecurity)}).Invoke(null,new object[]{transport,security});
                    }
                    transport.Write(titleBytes,0,titleBytes.Length);
                }
                psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + popupPath + "\" -Kind Text -TitleFile \"" + titleFile + "\" -ExpectedSequence " + expectedSequence + PointerArguments();
            }
            else
            {
                string encoded = Convert.ToBase64String(titleBytes);
                psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + popupPath + "\" -Kind Text -TitleBase64 " + encoded + " -ExpectedSequence " + expectedSequence + PointerArguments();
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
                var ancestor = new DirectoryInfo(dir);
                while (ancestor != null) {
                    if ((ancestor.Attributes & FileAttributes.ReparsePoint) != 0) return;
                    ancestor = ancestor.Parent;
                }
                foreach (string path in Directory.EnumerateFiles(dir, "clipwarp-title-*.txt")) {
                    if (++examined > 100) break;
                    string name = Path.GetFileName(path);
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0 && Regex.IsMatch(name, "^clipwarp-title-[0-9a-f]{32}\\.txt$") && File.GetLastWriteTimeUtc(path) < DateTime.UtcNow.AddDays(-1)) { try { File.Delete(path); removed++; } catch { } }
                }
                if (removed > 0) Log("removed " + removed + " orphaned calendar title file(s)");
            } catch { }
        }

        private bool CalendarEnabled() { return ReadSettings().CalendarEnabled; }

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

        private void CleanupWorker()
        {
            // Only the unconfirmed conversion process is cancelled. Popup descendants executing
            // an explicitly confirmed command are not killed (no process-tree termination).
            try { if (child != null && !child.HasExited) { child.Kill(); child.WaitForExit(1000); } } catch { }
            try { if (child != null) child.Dispose(); } catch { }
            child = null;
            CloseWarmPopupHost();
            CloseOwnedPopup();
            ClearPayloadCache();
        }

        public void Shutdown()
        {
            if (stopping) return;
            stopping = true;
            System.Threading.Interlocked.Increment(ref targetGeneration);
            try { RemoveClipboardFormatListener(this.Handle); } catch { }
            if (winEventHook != IntPtr.Zero) {
                try { UnhookWinEvent(winEventHook); } catch { }
                winEventHook = IntPtr.Zero;
            }
            shutdownWait.Unregister(null);
            debounce.Dispose();
            shutdownEvent.Dispose();
            DestroyHandle();
            Log("watch stopped");
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
    Add-Type -TypeDefinition ($src + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-clipboard.cs')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-image.cs')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-policy.cs')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-popup-host.cs'))) -ReferencedAssemblies ($references | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
}
else {
    Add-Type -TypeDefinition ($src + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-clipboard.cs')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-image.cs')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-policy.cs')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-popup-host.cs'))) -ReferencedAssemblies @('System', 'System.Windows.Forms', 'System.Drawing')
}

$watcher = New-Object ClipwarpWatch.Watcher($clipwarpPath, $calendarPopupPath, $configPath, $logFile)
try {
    [System.Windows.Forms.Application]::Run()   # message pump; blocks until the process is killed
}
finally {
    $watcher.Shutdown()
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
}
