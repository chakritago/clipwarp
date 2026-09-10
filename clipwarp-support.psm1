function Initialize-ClipwarpPolicy {
    if (-not ('ClipwarpPolicy.ConfigStore' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'clipwarp-policy.cs') -ErrorAction Stop }
}
Initialize-ClipwarpPolicy
function Get-ClipwarpDefaultConfigPath { Join-Path $env:USERPROFILE '.claude\clipwarp.json' }
function Get-ClipwarpConfigStatus { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); [ClipwarpPolicy.ConfigStore]::Read($ConfigPath) }
function Get-ClipwarpConfig { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); (Get-ClipwarpConfigStatus $ConfigPath).Json | ConvertFrom-Json }
function Save-ClipwarpConfig { param($Config,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); [void][ClipwarpPolicy.ConfigStore]::SaveJson($ConfigPath,($Config | ConvertTo-Json -Depth 32 -Compress)) }
function Set-ClipwarpConfigProperty { param([Parameter(Mandatory=$true)][string]$Name,$Value,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); [void][ClipwarpPolicy.ConfigStore]::Update($ConfigPath,$Name,($Value | ConvertTo-Json -Depth 32 -Compress)) }
function Set-ClipwarpCalendarProperty { param([string]$Name,$Value,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpConfigProperty ('calendar.'+$Name) $Value $ConfigPath }
function Get-ClipwarpCalendarEnabled { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); (Get-ClipwarpConfigStatus $ConfigPath).CalendarEnabled }
function Set-ClipwarpCalendarEnabled { param([Parameter(Mandatory=$true)][bool]$Enabled,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpCalendarProperty enabled $Enabled $ConfigPath; $Enabled }
function Get-ClipwarpCalendarImageDetails { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); (Get-ClipwarpConfig $ConfigPath).calendar.imageDetails }
function Set-ClipwarpCalendarImageDetails { param([Parameter(Mandatory=$true)][ValidateSet('Disabled','Filename','FullPath')][string]$Mode,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpCalendarProperty imageDetails $Mode $ConfigPath; $Mode }
function Get-ClipwarpCalendarDefaultDuration { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); [int](Get-ClipwarpConfig $ConfigPath).calendar.defaultDurationMinutes }
function Set-ClipwarpCalendarDefaultDuration { param([Parameter(Mandatory=$true)][ValidateRange(1,1440)][int]$Minutes,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpCalendarProperty defaultDurationMinutes $Minutes $ConfigPath; $Minutes }
function Get-ClipwarpTargetMode { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); (Get-ClipwarpConfigStatus $ConfigPath).TargetMode }
function Set-ClipwarpTargetMode { param([Parameter(Mandatory=$true)][ValidateSet('auto','chatgpt','claude','image-only','dual','text','web')][string]$Mode,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpConfigProperty targetMode $Mode $ConfigPath; $Mode }
function Get-ClipwarpActionEnabled {
    param([ValidateSet('enabled','calendar','chatgpt','runCommand')][string]$Action='enabled',[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $s=Get-ClipwarpConfigStatus $ConfigPath
    switch($Action){ enabled {$s.ActionsEnabled}; calendar {$s.CalendarEnabled}; chatgpt {$s.ChatGptEnabled}; runCommand {$s.RunCommandEnabled} }
}
function Set-ClipwarpActionEnabled { param([ValidateSet('enabled','calendar','chatgpt','runCommand')][string]$Action,[bool]$Enabled,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpConfigProperty ('actions.'+$Action) $Enabled $ConfigPath }
function Set-ClipwarpTargetOverride {
    param([Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9_-]{1,124}(\.exe)?$')][string]$ProcessName,[ValidateSet('auto','chatgpt','claude','image-only','dual','text','web')][string]$Mode='auto',[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    $name=[ClipwarpPolicy.TargetPolicy]::NormalizeProcess($ProcessName).ToLowerInvariant()
    Set-ClipwarpConfigProperty ('targetOverrides.'+$name) $Mode $ConfigPath
}
function Test-ClipwarpChatGptTarget { param([string]$ProcessName,[string]$WindowTitle); [ClipwarpPolicy.TargetPolicy]::IsChatGpt($ProcessName,$WindowTitle) }
function Test-ClipwarpWebTarget { param([string]$ProcessName,[string]$WindowTitle); [ClipwarpPolicy.TargetPolicy]::IsWeb($ProcessName,$WindowTitle) }
function Test-ClipwarpFilePickerTarget { param([string]$ProcessName,[string]$WindowTitle,[string]$WindowClass,[bool]$HasFilePickerControls=$false); [ClipwarpPolicy.TargetPolicy]::IsFilePicker($ProcessName,$WindowTitle,$WindowClass,$HasFilePickerControls) }
function Test-ClipwarpTerminalTarget { param([string]$ProcessName,[string]$WindowTitle); [ClipwarpPolicy.TargetPolicy]::IsTerminal($ProcessName,$WindowTitle) }
function Get-ClipwarpForegroundTargetInfo { [ClipwarpPolicy.TargetPolicy]::CaptureForeground() }
function Get-ClipwarpTargetExplanation {
    [CmdletBinding()]
    param([ValidateSet('auto','chatgpt','claude','image-only','dual','text','web')][Alias('Target')][string]$TargetMode='auto',[switch]$ImageOnly,[switch]$KeepImage,[string]$ProcessName,[string]$WindowTitle,[string]$WindowClass,[bool]$HasFilePickerControls=$false,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    [ClipwarpPolicy.TargetPolicy]::Explain((Get-ClipwarpConfigStatus $ConfigPath),$TargetMode,$ImageOnly.IsPresent,$KeepImage.IsPresent,$ProcessName,$WindowTitle,$WindowClass,$HasFilePickerControls)
}
function Resolve-ClipwarpPublicationMode {
    [CmdletBinding()]
    param([ValidateSet('auto','chatgpt','claude','image-only','dual','text','web')][Alias('Target')][string]$TargetMode='auto',[switch]$ImageOnly,[switch]$KeepImage,[string]$ProcessName,[string]$WindowTitle,[string]$WindowClass,[bool]$HasFilePickerControls=$false,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    (Get-ClipwarpTargetExplanation @PSBoundParameters).Mode
}

function Read-ClipwarpOwnedTitleFile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path,
          [string]$Directory=(Join-Path $env:USERPROFILE '.claude'))
    $root = Assert-ClipwarpSafeDirectory $Directory
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full).TrimEnd('\','/') -ne $root.TrimEnd('\','/') -or
        [IO.Path]::GetFileName($full) -cnotmatch '^clipwarp-title-[0-9a-f]{32}\.txt$') { throw 'Unowned title transport path.' }
    $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 1048576) { throw 'Unsafe or oversized title transport.' }
    $stream = [IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        if ($stream.Length -gt 1048576) { throw 'Oversized title transport.' }
        $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    [void](Assert-ClipwarpSafeDirectory $Directory)
    if (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { [IO.File]::Delete($full) }
    $text
}

function Clear-ClipwarpCalendarTitleFiles {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$Directory,[datetime]$BeforeUtc=[datetime]::UtcNow.AddDays(-1),[ValidateRange(1,1000)][int]$MaximumFiles=100,[string[]]$ExcludePath=@())
    $Directory=Assert-ClipwarpSafeDirectory $Directory
    $removed=0; $examined=0
    if(Test-Path -LiteralPath $Directory -PathType Container){
        foreach($path in [IO.Directory]::EnumerateFiles($Directory,'clipwarp-title-*.txt')){
            if($examined -ge $MaximumFiles){break};$examined++
            $file=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if($file.Name -match '^clipwarp-title-[0-9a-f]{32}\.txt$' -and $file.LastWriteTimeUtc -lt $BeforeUtc -and $path -notin $ExcludePath -and -not($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){
                if($PSCmdlet.ShouldProcess($path,'Delete old managed title transport')){Remove-Item -LiteralPath $path -Force -ErrorAction Stop;$removed++}
            }
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
    # Streaming top-N selection retains only Limit metadata records.
    $top=New-Object 'System.Collections.Generic.List[object]'
    Get-ClipwarpManagedImages $dir | ForEach-Object {
        $f=$_;$at=0
        while($at -lt $top.Count -and ($top[$at].LastWriteTimeUtc -gt $f.LastWriteTimeUtc -or ($top[$at].LastWriteTimeUtc -eq $f.LastWriteTimeUtc -and [string]::CompareOrdinal($top[$at].Name,$f.Name) -gt 0))){$at++}
        if($at -lt $Limit){$top.Insert($at,$f);if($top.Count -gt $Limit){$top.RemoveAt($Limit)}}
    }
    $top.ToArray()
}

function Get-ClipwarpRecopyTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [string]$Path,
        [ValidateRange(1, 100)][Nullable[int]]$Index
    )
    $dir = Assert-ClipwarpSafeDirectory $OutDir
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
            (Test-ClipwarpManagedImageName $item.Name) -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $item }
        throw 'The recopy path must be a managed clipwarp image directly inside OutDir.'
    }
    $item = Get-ClipwarpHistory -OutDir $dir -Limit 1 | Select-Object -First 1
    if (-not $item) { throw 'No managed clipwarp image was found to recopy.' }
    $item
}

function Clear-ClipwarpHistory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$OutDir, [datetime]$Before = (Get-Date).AddDays(-7), [string[]]$ExcludePath=@(), [ValidateRange(1,100000)][int]$MaximumFiles=10000, [switch]$Preview)
    $dir = Resolve-ClipwarpOutDir $OutDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $ancestor = Get-Item -LiteralPath $dir -Force
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing cleanup through a reparse point.' }
        $ancestor = $ancestor.Parent
    }
    $targets=New-Object 'System.Collections.Generic.List[object]'
    Get-ClipwarpManagedImages $dir | ForEach-Object {
        if($_.LastWriteTime -lt $Before -and $_.FullName -notin $ExcludePath){
            if($targets.Count -ge $MaximumFiles){throw 'Cleanup candidate cap reached; no files deleted.'};$targets.Add($_)
        }
    }
    if($Preview){return $targets.ToArray()}
    foreach ($file in $targets) {
        [void](Assert-ClipwarpSafeDirectory $dir)
        if(-not(Test-Path -LiteralPath $file.FullName)){continue}
        $current=Get-Item -LiteralPath $file.FullName -Force
        if(($current.Attributes -band [IO.FileAttributes]::ReparsePoint)-or $current.LastWriteTimeUtc -ne $file.LastWriteTimeUtc -or $current.Length -ne $file.Length){continue}
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
        [string[]]$ProfilePaths = @((Join-Path $(if($env:CLIPWARP_TEST_ROOT){Join-Path $env:CLIPWARP_TEST_ROOT 'documents'}else{[Environment]::GetFolderPath('MyDocuments')}) 'WindowsPowerShell\profile.ps1'),(Join-Path $(if($env:CLIPWARP_TEST_ROOT){Join-Path $env:CLIPWARP_TEST_ROOT 'documents'}else{[Environment]::GetFolderPath('MyDocuments')}) 'PowerShell\profile.ps1')),
        [string]$StartupPath = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\clipwarp-watch.lnk'),
        [string]$PidPath = (Join-Path $env:USERPROFILE '.claude\scripts\clipwarp-watch.pid')
    )
    $required = @('clipwarp.ps1','clipwarp-watch.ps1','clipwarp-calendar.psm1','clipwarp-calendar-popup.ps1','clipwarp-support.psm1','clipwarp-clipboard.cs','clipwarp-policy.cs','clipwarp-image.cs')
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
            if ($watchProcess -and $watchProcess.ProcessName -in @('powershell','pwsh')) {
                $watchDetail="PowerShell process at pid $watchPid; watcher identity unverified"
                try {
                    $identity=Get-CimInstance Win32_Process -Filter "ProcessId=$watchPid" -ErrorAction Stop
                    $expected=[IO.Path]::GetFullPath((Join-Path $ScriptRoot 'clipwarp-watch.ps1'))
                    $args=[string]$identity.CommandLine
                    if($args -match '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|([^\s]+))'){
                        $actual=if($Matches[1]){$Matches[1]}else{$Matches[2]}
                        if([string]::Equals([IO.Path]::GetFullPath($actual),$expected,[StringComparison]::OrdinalIgnoreCase) -and $args -match '(?i)(?:^|\s)-Daemon(?:\s|$)'){
                            $watchStatus='OK';$watchDetail="Watcher command path verified at pid $watchPid; start UTC $($watchProcess.StartTime.ToUniversalTime().ToString('o'))"
                        }
                    }
                }catch{$watchDetail="PowerShell process at pid $watchPid; command identity unavailable"}
            }
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
    $metadata=Get-ClipwarpInstalledMetadata -ScriptRoot $ScriptRoot
    [pscustomobject]@{Name='Repository URL';Status=if($metadata.Status -eq 'valid'){'INFO'}else{'WARN'};Detail=$metadata.Detail;MutatesState=$false}
    [pscustomobject]@{Name='Installed version';Status=if($metadata.Status -eq 'valid'){'INFO'}else{'WARN'};Detail=$metadata.Version;MutatesState=$false}
    $state=Get-ClipwarpConfigStatus $ConfigPath
    [pscustomobject]@{Name='Configuration';Status=if($state.Status -in @('valid','missing')){'OK'}else{'WARN'};Detail=($state.Status+'; '+$state.Diagnostic);MutatesState=$false}
    [pscustomobject]@{Name='Actions';Status='INFO';Detail=('enabled={0}; calendar={1}; chatgpt={2}; runCommand={3}' -f $state.ActionsEnabled,$state.CalendarEnabled,$state.ChatGptEnabled,$state.RunCommandEnabled);MutatesState=$false}
    try {$acl=Get-Acl -LiteralPath (Split-Path -Parent $ConfigPath) -ErrorAction Stop;$permissionDetail='ACL readable; owner '+$acl.Owner+'; effective write access not probed';$permissionStatus='INFO'}catch{$permissionDetail='Directory ACL unavailable; no write probe performed';$permissionStatus='WARN'}
    [pscustomobject]@{Name='Permissions';Status=$permissionStatus;Detail=$permissionDetail;MutatesState=$false}
    $resolvedOut = try { Resolve-ClipwarpOutDir $OutDir } catch { $null }
    [pscustomobject]@{ Name='Image directory'; Status=if($resolvedOut){'INFO'}else{'WARN'}; Detail=if($resolvedOut){$resolvedOut}else{'unsafe or invalid OutDir'}; MutatesState=$false }
}

Export-ModuleMember -Function Get-ClipwarpDefaultConfigPath, Get-ClipwarpCalendarEnabled, Set-ClipwarpCalendarEnabled, Get-ClipwarpCalendarImageDetails, Set-ClipwarpCalendarImageDetails, Get-ClipwarpCalendarDefaultDuration, Set-ClipwarpCalendarDefaultDuration, Clear-ClipwarpCalendarTitleFiles, Resolve-ClipwarpOutDir, Get-ClipwarpHistory, Get-ClipwarpRecopyTarget, Clear-ClipwarpHistory, Test-ClipwarpEnvironment, Get-ClipwarpTargetMode, Set-ClipwarpTargetMode, Test-ClipwarpChatGptTarget, Test-ClipwarpWebTarget, Test-ClipwarpFilePickerTarget, Test-ClipwarpTerminalTarget, Get-ClipwarpForegroundTargetInfo, Resolve-ClipwarpPublicationMode

function Get-ClipwarpRetentionDays { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); (Get-ClipwarpConfigStatus $ConfigPath).RetentionDays }
function Set-ClipwarpRetentionDays { param([ValidateRange(0,3650)][int]$Days,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpConfigProperty retentionDays $Days $ConfigPath }
function Get-ClipwarpPaused { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); (Get-ClipwarpConfigStatus $ConfigPath).Paused }
function Set-ClipwarpPaused { param([bool]$Paused,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); Set-ClipwarpConfigProperty paused $Paused $ConfigPath }
function Get-ClipwarpRetentionPolicy { param([string]$ConfigPath=(Get-ClipwarpDefaultConfigPath)); $s=Get-ClipwarpConfigStatus $ConfigPath; $r=($s.Json | ConvertFrom-Json).retention; if(-not $s.IsUsable){$r.enabled=$false}; $r }
function Set-ClipwarpRetentionPolicy {
    param([bool]$Enabled,[ValidateRange(0,3650)][int]$MaxAgeDays=0,[ValidateRange(0,1000000)][int]$MaxCount=0,[ValidateRange(0,1099511627776)][long]$MaxBytes=0,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath))
    Set-ClipwarpConfigProperty retention ([ordered]@{enabled=$Enabled;maxAgeDays=$MaxAgeDays;maxCount=$MaxCount;maxBytes=$MaxBytes}) $ConfigPath
}
function Test-ClipwarpManagedImageName { param([string]$Name); $Name -match '^clip-[0-9]{8}-[0-9]{6}-[0-9]{3}(-[0-9a-f]{32})?\.(png|jpe?g|gif|webp)$' }
function Assert-ClipwarpSafeDirectory {
    param([string]$Directory)
    $dir=Resolve-ClipwarpOutDir $Directory
    $ancestor=$dir
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){$item=Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing access through a reparse point.'}}
        if($ancestor -eq [IO.Path]::GetPathRoot($ancestor)){break}
        $parent=[IO.Path]::GetDirectoryName($ancestor.TrimEnd([char[]]@([char]92,[char]47)));if($parent -eq $ancestor){break};$ancestor=$parent
    }
    $dir
}
function Get-ClipwarpManagedImages {
    param([string]$OutDir)
    $dir=Assert-ClipwarpSafeDirectory $OutDir
    if(-not [IO.Directory]::Exists($dir)){return}
    foreach($path in [IO.Directory]::EnumerateFiles($dir)){
        if(Test-ClipwarpManagedImageName ([IO.Path]::GetFileName($path))){$f=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if(-not($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){$f}}
    }
}
function New-ClipwarpManagedImageFile {
    param([Parameter(Mandatory=$true)][string]$OutDir,[ValidateSet('png','jpg','jpeg','gif','webp')][string]$Extension='png')
    $dir=Assert-ClipwarpSafeDirectory $OutDir
    [void][IO.Directory]::CreateDirectory($dir)
    $path=Join-Path $dir ('clip-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.'+$Extension)
    $stream=New-Object IO.FileStream($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    [pscustomobject]@{Path=$path;Stream=$stream;Published=$false;CreationTimeUtc=[IO.File]::GetCreationTimeUtc($path)}
}
function Remove-ClipwarpOwnedImageFile {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)]$Ownership,[string[]]$ReferencedPaths=@())
    if($Ownership.Published -or $Ownership.Path -in $ReferencedPaths){return}
    [void](Assert-ClipwarpSafeDirectory ([IO.Path]::GetDirectoryName($Ownership.Path)))
    if(-not(Test-ClipwarpManagedImageName ([IO.Path]::GetFileName($Ownership.Path)))){throw 'Not a managed image.'}
    if(Test-Path -LiteralPath $Ownership.Path){$f=Get-Item -LiteralPath $Ownership.Path -Force;if(($f.Attributes -band [IO.FileAttributes]::ReparsePoint)-or $f.CreationTimeUtc -ne $Ownership.CreationTimeUtc){throw 'Image ownership changed.'};if($PSCmdlet.ShouldProcess($f.FullName,'Delete aborted owned image')){if($Ownership.Stream){$Ownership.Stream.Dispose()};Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop}}
}
Export-ModuleMember -Function Initialize-ClipwarpPolicy,Get-ClipwarpConfig,Get-ClipwarpConfigStatus,Save-ClipwarpConfig,Set-ClipwarpConfigProperty,Get-ClipwarpActionEnabled,Set-ClipwarpActionEnabled,Set-ClipwarpTargetOverride,Get-ClipwarpTargetExplanation,Get-ClipwarpRetentionDays,Set-ClipwarpRetentionDays,Get-ClipwarpPaused,Set-ClipwarpPaused,Get-ClipwarpRetentionPolicy,Set-ClipwarpRetentionPolicy,Test-ClipwarpManagedImageName,Assert-ClipwarpSafeDirectory,Get-ClipwarpManagedImages,New-ClipwarpManagedImageFile,Remove-ClipwarpOwnedImageFile

function Get-ClipwarpRetentionPreview {
    param([Parameter(Mandatory=$true)][string]$OutDir,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath),[string[]]$ExcludePath=@(),[datetime]$NowUtc=[datetime]::UtcNow,[ValidateRange(1,100000)][int]$MaximumFiles=10000)
    $policy=Get-ClipwarpRetentionPolicy $ConfigPath
    if(-not $policy.enabled){return}
    # Exceeding a bounded inventory aborts before emitting any deletion candidates.
    $files=New-Object 'System.Collections.Generic.List[object]'
    Get-ClipwarpManagedImages $OutDir | ForEach-Object {if($files.Count -ge $MaximumFiles){throw 'Retention scan cap reached; no cleanup performed.'};$files.Add($_)}
    $ordered=@($files | Sort-Object @{Expression='LastWriteTimeUtc';Descending=$true},@{Expression='Name';Descending=$true})
    [long]$bytes=0;[int]$count=0
    foreach($f in $ordered){
        $reason=$null
        if($policy.maxAgeDays -gt 0 -and $f.LastWriteTimeUtc -lt $NowUtc.AddDays(-$policy.maxAgeDays)){$reason='age'}
        elseif($policy.maxCount -gt 0 -and $count -ge $policy.maxCount){$reason='count'}
        elseif($policy.maxBytes -gt 0 -and $f.Length -gt ($policy.maxBytes-$bytes)){$reason='bytes'}
        if($f.FullName -in $ExcludePath){$reason=$null}
        if($reason){[pscustomobject]@{Path=$f.FullName;Length=$f.Length;LastWriteTimeUtc=$f.LastWriteTimeUtc;Reason=$reason}}
        else{$count++;$bytes+=$f.Length}
    }
}
function Invoke-ClipwarpRetention {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$OutDir,[string]$ConfigPath=(Get-ClipwarpDefaultConfigPath),[string[]]$ExcludePath=@(),[switch]$Preview,[ValidateRange(1,100000)][int]$MaximumFiles=10000)
    $targets=@(Get-ClipwarpRetentionPreview -OutDir $OutDir -ConfigPath $ConfigPath -ExcludePath $ExcludePath -MaximumFiles $MaximumFiles)
    if($Preview){return $targets}
    foreach($target in $targets){
        [void](Assert-ClipwarpSafeDirectory $OutDir)
        if(-not(Test-Path -LiteralPath $target.Path)){continue}
        $f=Get-Item -LiteralPath $target.Path -Force
        if(($f.Attributes -band [IO.FileAttributes]::ReparsePoint)-or $f.Length -ne $target.Length -or $f.LastWriteTimeUtc -ne $target.LastWriteTimeUtc){continue}
        if($PSCmdlet.ShouldProcess($target.Path,('Delete managed image by '+$target.Reason+' retention'))){Remove-Item -LiteralPath $target.Path -Force -ErrorAction Stop;$target.Path}
    }
}
Export-ModuleMember -Function Get-ClipwarpRetentionPreview,Invoke-ClipwarpRetention

function Get-ClipwarpInstalledMetadata {
    param([string]$ScriptRoot=$PSScriptRoot)
    foreach($name in @('clipwarp-installed.json','installed-manifest.json','release-manifest.json')){
        $path=Join-Path $ScriptRoot $name
        if(Test-Path -LiteralPath $path -PathType Leaf){
            try {
                $f=Get-Item -LiteralPath $path -Force
                if($f.Length -gt 1048576 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe metadata'}
                $data=[ClipwarpPolicy.Json]::Parse([IO.File]::ReadAllText($path))
                if($data -isnot [System.Collections.Generic.Dictionary[string,object]]){throw 'Invalid metadata'}
                $version=[string]$data['version'];$commit=[string]$data['commit'];$source=[string]$data['source']
                $origin=$data['origin']
                if($origin -is [System.Collections.Generic.Dictionary[string,object]]) {
                    if(-not $commit){$commit=[string]$origin['commit']}
                    if(-not $source){$source=[string]$origin['source']}
                }
                if(-not $version){$version=$commit};if(-not $version){$version='unknown'}
                # Origin is metadata, not signing authenticity. Never include arbitrary payload fields.
                if($source.Length -gt 512){$source=$source.Substring(0,512)}
                return [pscustomobject]@{Status='valid';Version=$version;Commit=$commit;Source=$source;Detail=('installed origin: '+$source+'; checksum metadata is not a signature');Path=$path}
            }catch{return [pscustomobject]@{Status='invalid';Version='unknown';Commit='';Source='';Detail='Installed metadata invalid or unreadable';Path=$path}}
        }
    }
    [pscustomobject]@{Status='missing';Version='source checkout / unknown';Commit='';Source='';Detail='No installed origin metadata';Path=$null}
}
Export-ModuleMember -Function Get-ClipwarpInstalledMetadata,Read-ClipwarpOwnedTitleFile
