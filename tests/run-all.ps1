[CmdletBinding()]
param(
    [ValidateSet('All','WindowsPowerShell','Pwsh','Current')][string]$Engine = 'All',
    [string]$PwshPath = 'pwsh.exe',
    [string]$WindowsPowerShellPath = 'powershell.exe',
    [ValidateRange(1,3600)][int]$SuiteTimeoutSeconds = 120,
    [string]$ResultsPath,
    [string]$SuiteDirectory = $PSScriptRoot,
    [string[]]$Suite = @('*.Tests.ps1')
)
$ErrorActionPreference = 'Stop'
# Unit suites only. Native desktop fixtures have a separate, explicit consent gate.
if ($env:OS -ne 'Windows_NT') { throw 'This runner requires Windows job objects.' }
if ([string]::IsNullOrWhiteSpace($SuiteDirectory)) { $SuiteDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path }
$SuiteDirectory = (Resolve-Path -LiteralPath $SuiteDirectory).Path
if ($SuiteDirectory -eq (Join-Path $PSScriptRoot 'integration')) { throw 'Use the integration runner explicitly; native fixtures are not unit suites.' }
$tests = @(Get-ChildItem -LiteralPath $SuiteDirectory -File -Filter '*.Tests.ps1' | Where-Object {
    $name = $_.Name
    @($Suite | Where-Object { $name -like $_ }).Count -gt 0
} | Sort-Object Name)
if (-not $tests.Count) { throw 'No matching unit suites; refusing to report an empty pass.' }

# A new job owns exactly this suite process and all descendants, including processes
# left behind by a successful suite. Never enumerate/kill by name or stale PID.
if (-not ('ClipwarpTestJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class ClipwarpTestJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
        public Basic BasicLimitInformation; public IO IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref Extended v, uint s);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    IntPtr handle;
    public ClipwarpTestJob() {
        handle=CreateJobObject(IntPtr.Zero,null);
        if(handle==IntPtr.Zero) throw new Win32Exception();
        var v=new Extended(); v.BasicLimitInformation.LimitFlags=0x2000;
        if(!SetInformationJobObject(handle,9,ref v,(uint)Marshal.SizeOf(v))) {
            int e=Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(e);
        }
    }
    public void Assign(IntPtr process) { if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(); }
    public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
}
'@
}
function Remove-OwnedTree([string]$Path) {
    # Do not traverse junctions/symlinks created by a test into a user's directory.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName) }
        else { [IO.File]::Delete($item.FullName) }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) { Remove-OwnedTree $child.FullName }
        [IO.Directory]::Delete($Path)
    } else { [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal); [IO.File]::Delete($Path) }
}
function Quote-Literal([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
$engines = switch ($Engine) {
    'All' { @($WindowsPowerShellPath, $PwshPath) }
    'WindowsPowerShell' { @($WindowsPowerShellPath) }
    'Pwsh' { @($PwshPath) }
    'Current' { @([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
}
$runId = [guid]::NewGuid().ToString('N')
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('cw-' + $runId.Substring(0,12))
[void][IO.Directory]::CreateDirectory($runRoot)
$records = New-Object 'System.Collections.Generic.List[object]'
$runStarted = [DateTime]::UtcNow
$cleanupError = $null
try {
    foreach ($enginePath in $engines) {
        foreach ($test in $tests) {
            $suiteRoot = Join-Path $runRoot ($records.Count.ToString('D3'))
            foreach ($folder in @('temp','home','appdata','localappdata','programdata','documents')) {
                [void][IO.Directory]::CreateDirectory((Join-Path $suiteRoot $folder))
            }
            $gate = Join-Path $suiteRoot 'start.gate'
            $process = $null; $job = $null; $stdoutTask = $null; $stderrTask = $null
            $status = 'Failed'; $exitCode = $null; $errorText = $null; $stdout = ''; $stderr = ''
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Write-Host "TEST: $enginePath / $($test.Name)"
            try {
                $resolvedEngine = (Get-Command $enginePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                # Child waits for job assignment before executing any suite code. Gate also
                # expires if the runner crashes before assignment, so no orphan waiter.
                $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not [IO.File]::Exists($(Quote-Literal $gate))) {
    if ([DateTime]::UtcNow -gt `$deadline) { exit 125 }
    Start-Sleep -Milliseconds 20
}
`$global:PROFILE = $(Quote-Literal (Join-Path $suiteRoot 'documents/profile.ps1'))
`$global:PROFILE | Add-Member -NotePropertyName CurrentUserCurrentHost -NotePropertyValue $(Quote-Literal (Join-Path $suiteRoot 'documents/profile.ps1'))
`$global:PROFILE | Add-Member -NotePropertyName CurrentUserAllHosts -NotePropertyValue $(Quote-Literal (Join-Path $suiteRoot 'documents/all-hosts.ps1'))
`$global:PROFILE | Add-Member -NotePropertyName AllUsersCurrentHost -NotePropertyValue $(Quote-Literal (Join-Path $suiteRoot 'programdata/profile.ps1'))
`$global:PROFILE | Add-Member -NotePropertyName AllUsersAllHosts -NotePropertyValue $(Quote-Literal (Join-Path $suiteRoot 'programdata/all-hosts.ps1'))
`$global:LASTEXITCODE = 0
try { & $(Quote-Literal $test.FullName); if (-not `$?) { exit 1 }; exit `$LASTEXITCODE }
catch { [Console]::Error.WriteLine(`$_.ToString()); [Console]::Error.WriteLine(`$_.ScriptStackTrace); exit 1 }
"@
                $info = New-Object Diagnostics.ProcessStartInfo
                $info.FileName = $resolvedEngine
                $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
                $info.UseShellExecute = $false; $info.CreateNoWindow = $true
                $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
                $info.WorkingDirectory = $suiteRoot
                foreach ($pair in @{
                    TEMP='temp'; TMP='temp'; USERPROFILE='home'; HOME='home'; APPDATA='appdata'; LOCALAPPDATA='localappdata'; PROGRAMDATA='programdata'
                }.GetEnumerator()) { $info.EnvironmentVariables[$pair.Key] = Join-Path $suiteRoot $pair.Value }
                $info.EnvironmentVariables['CLIPWARP_TEST_ROOT'] = $suiteRoot
                $info.EnvironmentVariables['CLIPWARP_TEST_NONINTERACTIVE'] = '1'
                $info.EnvironmentVariables['CLIPWARP_NATIVE_INTEGRATION'] = '0'
                $job = New-Object ClipwarpTestJob
                $process = New-Object Diagnostics.Process
                $process.StartInfo = $info
                [void]$process.Start()
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $job.Assign($process.Handle)
                [IO.File]::WriteAllText($gate, 'assigned')
                if (-not $process.WaitForExit($SuiteTimeoutSeconds * 1000)) { $status = 'TimedOut' }
                else { $exitCode = $process.ExitCode; if ($exitCode -eq 0) { $status = 'Passed' } }
            } catch { $errorText = $_.Exception.Message }
            finally {
                if ($job) { $job.Dispose() }
                if ($process) {
                    # Assignment may have failed. This handle belongs to the process just
                    # created above; it cannot select another process through PID reuse.
                    try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch { }
                    foreach ($stream in @('stdout','stderr')) {
                        $task = if ($stream -eq 'stdout') { $stdoutTask } else { $stderrTask }
                        if ($task) {
                            try {
                                if (-not $task.Wait(5000)) { throw 'Output pipe did not close after owned job shutdown.' }
                                if ($stream -eq 'stdout') { $stdout = $task.Result } else { $stderr = $task.Result }
                            } catch { $status = 'Failed'; $errorText = $_.Exception.Message }
                        }
                    }
                    $process.Dispose()
                }
                $watch.Stop()
            }
            $records.Add([pscustomobject]@{
                Engine=$enginePath; Suite=$test.Name; Status=$status; ExitCode=$exitCode
                DurationMilliseconds=$watch.ElapsedMilliseconds; TimeoutSeconds=$SuiteTimeoutSeconds
                Stdout=$stdout; Stderr=$stderr; Error=$errorText
            })
            if ($stdout) { Write-Host $stdout.TrimEnd() }
            if ($stderr) { Write-Host $stderr.TrimEnd() }
            Write-Host "RESULT: $status $enginePath / $($test.Name) $errorText"
        }
    }
} finally {
    # Root is always generated here, never a caller-supplied directory.
    try { Remove-OwnedTree $runRoot } catch { $cleanupError = $_.Exception.Message; Write-Warning "Test root cleanup failed: $cleanupError" }
}
$failed = @($records | Where-Object Status -ne 'Passed').Count
$report = [pscustomobject]@{
    SchemaVersion=1; RunId=$runId; StartedUtc=$runStarted.ToString('o'); FinishedUtc=[DateTime]::UtcNow.ToString('o')
    Total=$records.Count; Passed=($records.Count-$failed); Failed=$failed
    TimedOut=@($records | Where-Object Status -eq 'TimedOut').Count
    CleanupError=$cleanupError; Suites=@($records.ToArray())
}
$json = $report | ConvertTo-Json -Depth 6
if ($ResultsPath) {
    $destination = [IO.Path]::GetFullPath($ResultsPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::WriteAllText($destination, $json, (New-Object Text.UTF8Encoding($false)))
}
# JSON is also returned on the success stream for automation without an output file.
Write-Output $json
Write-Host "TOTAL: $($report.Total); PASSED: $($report.Passed); FAILED: $failed; TIMED OUT: $($report.TimedOut)"
if ($failed -or $cleanupError) { exit 1 }
exit 0
