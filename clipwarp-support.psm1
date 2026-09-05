function Get-ClipwarpDefaultConfigPath {
    Join-Path $env:USERPROFILE '.claude\clipwarp.json'
}

function Get-ClipwarpCalendarEnabled {
    [CmdletBinding()]
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $true }
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $config.calendar -and $null -ne $config.calendar.enabled -and $config.calendar.enabled -is [bool]) {
            return [bool]$config.calendar.enabled
        }
    } catch {}
    return $true
}

function Get-ClipwarpConfig {
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try { return Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
    [pscustomobject]@{ version=1; calendar=[pscustomobject]@{} }
}

function Save-ClipwarpConfig($Config, [string]$ConfigPath) {
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $tmp = Join-Path $dir ('.clipwarp-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($tmp, ($Config | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false))); Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force -ErrorAction Stop }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Set-ClipwarpCalendarProperty([string]$Name, $Value, [string]$ConfigPath) {
    $config = Get-ClipwarpConfig -ConfigPath $ConfigPath
    if ($null -eq $config.calendar) { $config | Add-Member NoteProperty calendar ([pscustomobject]@{}) -Force }
    $config.calendar | Add-Member NoteProperty $Name $Value -Force
    Save-ClipwarpConfig $config $ConfigPath
}

function Set-ClipwarpCalendarEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled, [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    Set-ClipwarpCalendarProperty -Name enabled -Value $Enabled -ConfigPath $ConfigPath
    $Enabled
}

function Get-ClipwarpCalendarImageDetails { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); $v=(Get-ClipwarpConfig $ConfigPath).calendar.imageDetails; if($v -in @('Filename','FullPath')){$v}else{'Disabled'} }
function Set-ClipwarpCalendarImageDetails { param([Parameter(Mandatory=$true)][ValidateSet('Disabled','Filename','FullPath')][string]$Mode,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpCalendarProperty imageDetails $Mode $ConfigPath; $Mode }
function Get-ClipwarpCalendarDefaultDuration { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); $v=(Get-ClipwarpConfig $ConfigPath).calendar.defaultDurationMinutes; if($v -is [int] -or $v -is [long]){if($v -ge 1 -and $v -le 1440){return [int]$v}}; 60 }
function Set-ClipwarpCalendarDefaultDuration { param([Parameter(Mandatory=$true)][ValidateRange(1,1440)][int]$Minutes,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpCalendarProperty defaultDurationMinutes $Minutes $ConfigPath; $Minutes }

function Get-ClipwarpTargetMode {
    [CmdletBinding()]
    param([string]$ConfigPath = (Get-ClipwarpDefaultConfigPath))
    $val = (Get-ClipwarpConfig $ConfigPath).targetMode
    if ($val -in @('auto', 'chatgpt', 'claude', 'image-only', 'dual', 'text', 'web')) { return [string]$val }
    'auto'
}

function Set-ClipwarpTargetMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('auto', 'chatgpt', 'claude', 'image-only', 'dual', 'text', 'web')]
        [string]$Mode,
        [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath)
    )
    $config = Get-ClipwarpConfig -ConfigPath $ConfigPath
    $config | Add-Member NoteProperty targetMode $Mode -Force
    Save-ClipwarpConfig $config $ConfigPath
    $Mode
}

function Test-ClipwarpChatGptTarget {
    [CmdletBinding()]
    param(
        [string]$ProcessName,
        [string]$WindowTitle
    )
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    if ($ProcessName -match '^(?i)chatgpt$') { return $true }
    if ([string]::IsNullOrWhiteSpace($WindowTitle)) { return $false }
    $isBrowser = $ProcessName -match '^(chrome|msedge|firefox|brave|opera|vivaldi|arc|zen|waterfox|floorp|librewolf|thorium|chromium)$'
    if (-not $isBrowser) { return $false }
    $isChatGpt = $WindowTitle -match '(?i)(chatgpt|openai|(^|[\s\-_–—|•·])new\s*chat([\s\-_–—|•·]|$)|การสนทนาใหม่|แชทใหม่)'
    [bool]$isChatGpt
}

function Test-ClipwarpWebTarget {
    [CmdletBinding()]
    param(
        [string]$ProcessName,
        [string]$WindowTitle
    )
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    if ($ProcessName -match '^(chrome|msedge|firefox|brave|opera|vivaldi|arc|zen|waterfox|floorp|librewolf|thorium|chromium|chatgpt)$') { return $true }
    if ($WindowTitle -match '(?i)(chatgpt|openai)') { return $true }
    return $false
}

function Test-ClipwarpTerminalTarget {
    [CmdletBinding()]
    param(
        [string]$ProcessName,
        [string]$WindowTitle
    )
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    if ($ProcessName -match '^(windowsterminal|powershell|pwsh|cmd|conhost|mintty|bash|alacritty|wezterm|hyper|tabby)$') { return $true }
    if ($WindowTitle -match '(?i)(claude|powershell|cmd\.exe|wsl)') { return $true }
    return $false
}

function Get-ClipwarpForegroundTargetInfo {
    [CmdletBinding()]
    param()
    if (-not ([System.Management.Automation.PSTypeName]'ClipwarpNative.TargetWindow').Type) {
        Add-Type -Namespace ClipwarpNative -Name TargetWindow -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);

public static string GetActiveWindow(out string procName, out uint pid) {
    procName = "";
    pid = 0;
    System.IntPtr hwnd = GetForegroundWindow();
    if (hwnd == System.IntPtr.Zero) return "";
    GetWindowThreadProcessId(hwnd, out pid);
    try {
        procName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
    } catch { }
    System.Text.StringBuilder sb = new System.Text.StringBuilder(512);
    GetWindowText(hwnd, sb, sb.Capacity);
    return sb.ToString();
}
'@
    }
    try {
        $proc = ""
        $pidVal = [uint32]0
        $title = [ClipwarpNative.TargetWindow]::GetActiveWindow([ref]$proc, [ref]$pidVal)
        $isGpt = Test-ClipwarpChatGptTarget -ProcessName $proc -WindowTitle $title
        return [pscustomobject]@{
            ProcessName = $proc
            WindowTitle = $title
            ProcessId   = $pidVal
            IsChatGpt   = $isGpt
        }
    } catch {
        return [pscustomobject]@{
            ProcessName = ""
            WindowTitle = ""
            ProcessId   = 0
            IsChatGpt   = $false
        }
    }
}

function Resolve-ClipwarpPublicationMode {
    [CmdletBinding()]
    param(
        [ValidateSet('auto', 'chatgpt', 'claude', 'image-only', 'dual', 'text', 'web')]
        [Alias('Target')]
        [string]$TargetMode = 'auto',
        [switch]$ImageOnly,
        [switch]$KeepImage,
        [string]$ProcessName,
        [string]$WindowTitle,
        [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath)
    )
    if ($ImageOnly) { return 'image-only' }
    if ($TargetMode -in @('image-only', 'chatgpt', 'web')) { return 'image-only' }
    if ($TargetMode -in @('dual', 'claude')) { return 'dual' }
    if ($TargetMode -eq 'text') { return 'text' }

    $configured = Get-ClipwarpTargetMode -ConfigPath $ConfigPath
    if ($configured -in @('image-only', 'chatgpt', 'web')) { return 'image-only' }
    if ($configured -in @('dual', 'claude')) { return 'dual' }
    if ($configured -eq 'text') { return 'text' }

    if ($ProcessName -or $WindowTitle) {
        if (Test-ClipwarpWebTarget -ProcessName $ProcessName -WindowTitle $WindowTitle) {
            return 'image-only'
        }
    }

    if ($KeepImage) { return 'dual' }
    return 'text'
}

function Clear-ClipwarpCalendarTitleFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Directory,[datetime]$BeforeUtc=[datetime]::UtcNow.AddDays(-1),[ValidateRange(1,1000)][int]$MaximumFiles=100)
    $removed=0; $examined=0
    if(Test-Path -LiteralPath $Directory -PathType Container){
        Get-ChildItem -LiteralPath $Directory -File -Filter 'clipwarp-title-*.txt' | Sort-Object LastWriteTimeUtc | Select-Object -First $MaximumFiles | ForEach-Object {
            $examined++; if($_.Name -match '^clipwarp-title-[0-9a-f]{32}\.txt$' -and $_.LastWriteTimeUtc -lt $BeforeUtc){ Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; if(-not(Test-Path -LiteralPath $_.FullName)){$removed++} }
        }
    }
    [pscustomobject]@{ ExaminedCount=$examined; RemovedCount=$removed; Directory=$Directory }
}

function Resolve-ClipwarpOutDir {
    param([Parameter(Mandatory = $true)][string]$OutDir)
    if ([string]::IsNullOrWhiteSpace($OutDir)) { throw 'OutDir cannot be empty.' }
    $full = [IO.Path]::GetFullPath($OutDir)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\') -eq $root.TrimEnd('\')) { throw 'Refusing to use a drive root as OutDir.' }
    $full
}

function Get-ClipwarpHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OutDir, [ValidateRange(1, 100)][int]$Limit = 20)
    $dir = Resolve-ClipwarpOutDir $OutDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop |
        Where-Object { $_.Name -match '^clip-.*\.(png|jpe?g|gif|webp)$' } |
        Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $true } |
        Select-Object -First $Limit
}

function Get-ClipwarpRecopyTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [string]$Path,
        [ValidateRange(1, 100)][Nullable[int]]$Index
    )
    $dir = Resolve-ClipwarpOutDir $OutDir
    if ($Path -and $null -ne $Index) { throw 'Specify either a path or an index, not both.' }
    if ($null -ne $Index) {
        $history = @(Get-ClipwarpHistory -OutDir $dir -Limit 100)
        if ($Index -gt $history.Count) { throw "No managed clipwarp image exists at history index $Index." }
        return $history[$Index - 1]
    }
    if ($Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not $item.PSIsContainer -and
            [string]::Equals($item.Directory.FullName.TrimEnd('\'), $dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and
            $item.Name -match '^clip-.*\.(png|jpe?g|gif|webp)$') { return $item }
        throw 'The recopy path must be a managed clipwarp image directly inside OutDir.'
    }
    $item = Get-ClipwarpHistory -OutDir $dir -Limit 1 | Select-Object -First 1
    if (-not $item) { throw 'No managed clipwarp image was found to recopy.' }
    $item
}

function Clear-ClipwarpHistory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$OutDir, [datetime]$Before = (Get-Date).AddDays(-7))
    $dir = Resolve-ClipwarpOutDir $OutDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $targets = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop |
        Where-Object { $_.Name -match '^clip-.*\.(png|jpe?g|gif|webp)$' -and $_.LastWriteTime -lt $Before } |
        Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $false }, Name)
    foreach ($file in $targets) {
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete saved clipwarp image')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $file.FullName
        }
    }
}

function Test-ClipwarpEnvironment {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$ConfigPath = (Get-ClipwarpDefaultConfigPath),
        [string]$OutDir = (Join-Path $env:USERPROFILE '.claude\pasted-images'),
        [string[]]$ProfilePaths = @($PROFILE.CurrentUserAllHosts),
        [string]$StartupPath = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'),
        [string]$PidPath = (Join-Path $env:USERPROFILE '.claude\scripts\clipwarp-watch.pid')
    )
    $required = @('clipwarp.ps1','clipwarp-watch.ps1','clipwarp-calendar.psm1','clipwarp-calendar-popup.ps1','clipwarp-support.psm1')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ScriptRoot $_) -PathType Leaf) })
    [pscustomobject]@{ Name='Installed scripts'; Status=if($missing.Count){'WARN'}else{'OK'}; Detail=if($missing.Count){'missing: '+($missing -join ', ')}else{'all present'}; MutatesState=$false }
    $marker = '# >>> clipwarp (Claude Code image paste helper) >>>'
    $marked = @($ProfilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) -and ((Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue).Contains($marker)) })
    [pscustomobject]@{ Name='Profile markers'; Status=if($marked.Count){'OK'}else{'WARN'}; Detail=if($marked.Count){$marked -join '; '}else{'not found'}; MutatesState=$false }
    $watchStatus = 'WARN'; $watchDetail = 'not running (no pid file)'
    if (Test-Path -LiteralPath $PidPath -PathType Leaf) {
        $watchPid = 0
        if ([int]::TryParse((Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$watchPid)) {
            $watchProcess = Get-Process -Id $watchPid -ErrorAction SilentlyContinue
            if ($watchProcess -and $watchProcess.ProcessName -in @('powershell','pwsh')) { $watchStatus='INFO'; $watchDetail="PowerShell process present at pid $watchPid; identity is not changed or killed by doctor" }
            elseif ($watchProcess) { $watchDetail="foreign process at pid $watchPid; watcher not verified" }
            else { $watchDetail="stale pid file ($watchPid); watcher not running" }
        } else { $watchDetail='invalid pid file; watcher not verified' }
    }
    [pscustomobject]@{ Name='Watcher'; Status=$watchStatus; Detail=$watchDetail; MutatesState=$false }
    [pscustomobject]@{ Name='Autostart'; Status='INFO'; Detail=if(Test-Path -LiteralPath $StartupPath -PathType Leaf){'enabled'}else{'disabled'}; MutatesState=$false }
    [pscustomobject]@{ Name='PowerShell'; Status='INFO'; Detail="$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion); execution policy $(Get-ExecutionPolicy)"; MutatesState=$false }
    $calendarState=if(Get-ClipwarpCalendarEnabled -ConfigPath $ConfigPath){'enabled'}else{'disabled'}
    $calendarDetail="$calendarState; image details $(Get-ClipwarpCalendarImageDetails -ConfigPath $ConfigPath); default duration $(Get-ClipwarpCalendarDefaultDuration -ConfigPath $ConfigPath) minutes"
    [pscustomobject]@{ Name='Calendar'; Status='INFO'; Detail=$calendarDetail; MutatesState=$false }
    $targetMode = Get-ClipwarpTargetMode -ConfigPath $ConfigPath
    [pscustomobject]@{ Name='Target mode'; Status='INFO'; Detail="configured: $targetMode (ChatGPT browser detection: active in auto mode)"; MutatesState=$false }
    $titleDir=Split-Path -Parent $ConfigPath
    $orphanCount=if(Test-Path -LiteralPath $titleDir -PathType Container){@(Get-ChildItem -LiteralPath $titleDir -File -Filter 'clipwarp-title-*.txt' -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '^clipwarp-title-[0-9a-f]{32}\.txt$' -and $_.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-1)} | Select-Object -First 101).Count}else{0}
    [pscustomobject]@{ Name='Calendar transport'; Status=if($orphanCount){'WARN'}else{'OK'}; Detail=if($orphanCount -gt 100){'more than 100 old managed title files'}elseif($orphanCount){"$orphanCount old managed title file(s)"}else{'no old managed title files'}; MutatesState=$false }
    $install = Join-Path $ScriptRoot 'install.ps1'
    $drift = $true
    if (Test-Path -LiteralPath $install -PathType Leaf) { $drift = -not ((Get-Content -LiteralPath $install -Raw) -match 'raw\.githubusercontent\.com/chakritago/clipwarp/main') }
    [pscustomobject]@{ Name='Repository URL'; Status=if($drift){'WARN'}else{'OK'}; Detail=if($drift){'installer default differs from chakritago/clipwarp'}else{'chakritago/clipwarp'}; MutatesState=$false }
    $resolvedOut = try { Resolve-ClipwarpOutDir $OutDir } catch { $null }
    [pscustomobject]@{ Name='Image directory'; Status=if($resolvedOut){'INFO'}else{'WARN'}; Detail=if($resolvedOut){$resolvedOut}else{'unsafe or invalid OutDir'}; MutatesState=$false }
}

Export-ModuleMember -Function Get-ClipwarpDefaultConfigPath, Get-ClipwarpCalendarEnabled, Set-ClipwarpCalendarEnabled, Get-ClipwarpCalendarImageDetails, Set-ClipwarpCalendarImageDetails, Get-ClipwarpCalendarDefaultDuration, Set-ClipwarpCalendarDefaultDuration, Clear-ClipwarpCalendarTitleFiles, Resolve-ClipwarpOutDir, Get-ClipwarpHistory, Get-ClipwarpRecopyTarget, Clear-ClipwarpHistory, Test-ClipwarpEnvironment, Get-ClipwarpTargetMode, Set-ClipwarpTargetMode, Test-ClipwarpChatGptTarget, Test-ClipwarpWebTarget, Test-ClipwarpTerminalTarget, Get-ClipwarpForegroundTargetInfo, Resolve-ClipwarpPublicationMode
