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
    $fileRe = '-File\s+"?' + [regex]::Escape($PSCommandPath) + '"?(\s|$)'
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
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-Daemon'
    ) | Out-Null
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
    public class Watcher : NativeWindow
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")]
        private static extern uint GetClipboardSequenceNumber();

        private const int WM_CLIPBOARDUPDATE = 0x031D;
        private static readonly Regex ImgExt = new Regex(@"\.(png|jpe?g|gif|webp|bmp)$", RegexOptions.IgnoreCase);
        private static readonly Regex HtmlFileUri = new Regex(@"file:///[^""'\s>]+\.(png|jpe?g|gif|webp|bmp)", RegexOptions.IgnoreCase);

        private readonly string scriptPath;
        private readonly string logPath;
        private readonly string popupPath;
        private readonly Timer debounce;
        private System.Diagnostics.Process child;
        private DateTime childStarted;
        private const int ChildTimeoutSec = 15;   // a conversion that runs longer is treated as hung
        private int busyRetries;                  // consecutive "clipboard busy" re-arms in this burst
        private int convFails;                    // consecutive failed conversions of the current clipboard
        private uint lastHandledSequence;
        private string lastTextFingerprint;
        private DateTime lastTextAt;

        // Re-check soon instead of dropping the event (clipboard was busy, or a
        // conversion is still running). Bounded so a permanently-locked clipboard
        // can't spin forever - a genuinely new copy will re-fire the listener.
        private void Rearm()
        {
            if (++busyRetries > 20) { busyRetries = 0; debounce.Interval = 300; return; }
            debounce.Interval = Math.Min(300 + busyRetries * 150, 2000);
            debounce.Start();
        }

        public Watcher(string script, string popup, string log)
        {
            scriptPath = script;
            popupPath = popup;
            logPath = log;
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);              // HWND_MESSAGE: message-only window
            CreateHandle(cp);
            if (!AddClipboardFormatListener(this.Handle))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "AddClipboardFormatListener failed");
            debounce = new Timer();
            debounce.Interval = 300;               // coalesce the bursts some apps fire per copy
            debounce.Tick += OnTick;
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
                debounce.Interval = 300;
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
                        debounce.Interval = 300;   // watchdog poll until it finishes/hangs
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

            // If the current clipboard keeps failing to convert, stop relaunching
            // until a new copy arrives (WM_CLIPBOARDUPDATE resets convFails).
            if (convFails >= 3)
            {
                if (convFails == 3) { convFails++; Log("conversion failing repeatedly - waiting for a new clipboard copy"); }
                return;
            }

            string txt = null;
            try { if (Clipboard.ContainsText()) txt = Clipboard.GetText(); }
            catch { Rearm(); return; }                         // clipboard busy -> retry soon, don't drop it
            if (!string.IsNullOrEmpty(txt))
            {
                string p = txt.Trim().Trim('"');
                if (ImgExt.IsMatch(p) && File.Exists(p)) { busyRetries = 0; debounce.Interval = 300; return; }  // our own write / usable path
                string meaningful = txt.Trim();
                if (meaningful.Length > 0)
                {
                    if (meaningful == lastTextFingerprint && (DateTime.Now - lastTextAt).TotalSeconds < 2)
                    { lastHandledSequence = sequence; return; }
                    LaunchTextPopup(meaningful);
                    lastTextFingerprint = meaningful;
                    lastTextAt = DateTime.Now;
                    lastHandledSequence = sequence;
                    busyRetries = 0;
                    debounce.Interval = 300;
                    Log("text on clipboard -> calendar popup");
                    return;
                }
            }

            int payload = HasImagePayload();
            if (payload < 0) { Rearm(); return; }              // clipboard busy -> retry soon
            if (payload == 0) { busyRetries = 0; debounce.Interval = 300; return; }
            lastHandledSequence = sequence;

            debounce.Interval = 300;
            var psi = new System.Diagnostics.ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + scriptPath + "\" -Quiet -KeepImage";
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            child = System.Diagnostics.Process.Start(psi);
            childStarted = DateTime.Now;
            // Arm the watchdog: re-enter Inspect on the timer so a hung child is
            // reaped after ChildTimeoutSec even if no further clipboard event ever
            // fires (a child that hangs before writing produces no WM_CLIPBOARDUPDATE).
            debounce.Interval = 300;
            debounce.Start();
            Log("image on clipboard -> converting");
        }

        private void LaunchTextPopup(string title)
        {
            string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(title));
            var psi = new System.Diagnostics.ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + popupPath + "\" -Kind Text -TitleBase64 " + encoded;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            System.Diagnostics.Process.Start(psi);
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
Add-Type -TypeDefinition $src -ReferencedAssemblies @('System', 'System.Windows.Forms')

$watcher = New-Object ClipwarpWatch.Watcher($clipwarpPath, $calendarPopupPath, $logFile)
try {
    [System.Windows.Forms.Application]::Run()   # message pump; blocks until the process is killed
}
finally {
    $watcher.Shutdown()
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
}
