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
        'watcher' { Write-Host "clipwarp watch: running (pid $($st.Pid)) - autostart $auto" -ForegroundColor Green; exit 0 }
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
        Write-Host "clipwarp watch: started (pid $($st.Pid))" -ForegroundColor Green
        Write-Host 'copy an image anywhere (Ctrl+C / snip), then Ctrl+V in Claude Code.' -ForegroundColor Cyan
        Write-Host "stop with: clipwarp stop" -ForegroundColor DarkGray
        exit 0
    }
    Write-Host "clipwarp watch: failed to start (see $logFile)" -ForegroundColor Red
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

$src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ClipwarpWatch
{
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
            Log("watch started, pid " + System.Diagnostics.Process.GetCurrentProcess().Id);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_CLIPBOARDUPDATE)
            {
                // A genuinely new clipboard change: give it a full, fresh retry
                // budget (don't inherit a previous burst's exhausted counter).
                busyRetries = 0;
                convFails = 0;
                POINT captured;
                hasEventPointer = GetCursorPos(out captured);
                if (hasEventPointer) eventPointer = captured;
                CaptureForeground();
                debounce.Interval = EventDelayMs;
                debounce.Stop();
                debounce.Start();
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
            try { RemoveClipboardFormatListener(this.Handle); } catch { }
            if (winEventHook != IntPtr.Zero)
            {
                try { UnhookWinEvent(winEventHook); } catch { }
                winEventHook = IntPtr.Zero;
            }
            CloseOwnedPopup();
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
    Add-Type -TypeDefinition ($src + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-clipboard.cs'))) -ReferencedAssemblies ($references | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
}
else {
    Add-Type -TypeDefinition ($src + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'clipwarp-clipboard.cs'))) -ReferencedAssemblies @('System', 'System.Windows.Forms', 'System.Drawing')
}

$watcher = New-Object ClipwarpWatch.Watcher($clipwarpPath, $calendarPopupPath, $configPath, $logFile)

$cleanupScript = {
    try {
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
