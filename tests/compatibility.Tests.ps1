$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$powershellFiles = @(Get-ChildItem -LiteralPath $root -File | Where-Object Extension -in @('.ps1','.psm1')) + @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')
foreach ($file in $powershellFiles) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed for $($file.Name): $($errors[0].Message)" }
}
Write-Host "PASS: parsed $($powershellFiles.Count) PowerShell files"

Add-Type -AssemblyName System.Windows.Forms
function Get-HereStringValue([string]$Path, [string]$Contains) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains($Contains) }, $true)
    if (-not $node) { throw "Embedded C# containing '$Contains' not found in $Path" }
    $node.Value
}

$watchSource = Get-HereStringValue (Join-Path $root 'clipwarp-watch.ps1') 'namespace ClipwarpWatch'
$watchSource += [IO.File]::ReadAllText((Join-Path $root 'clipwarp-clipboard.cs'))
$watchSource += [IO.File]::ReadAllText((Join-Path $root 'clipwarp-rightlang.cs'))
$watchSource += [IO.File]::ReadAllText((Join-Path $root 'clipwarp-editor-bridge.cs'))
if ($PSVersionTable.PSEdition -eq 'Core') {
    # Prefer compilation contracts over runtime facades (notably System.Collections).
    $references = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)
    $references += @([AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES') -split [IO.Path]::PathSeparator)
    $references += [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | ForEach-Object Location
    Add-Type -TypeDefinition $watchSource -ReferencedAssemblies ($references | Group-Object { [IO.Path]::GetFileName($_) } | ForEach-Object { $_.Group[0] })
} else { Add-Type -TypeDefinition $watchSource -ReferencedAssemblies @('System','System.Windows.Forms','System.Drawing') }
Write-Host 'PASS: compiled watcher C#'
# Pure policy tests run on Windows CI without a live keyboard hook or clipboard.
if (-not [ClipwarpRightLang.Engine]::CanCorrect('l;ylfu','สวัสดี',$true,$false,$false)) { throw 'selected text should qualify for conversion' }
if (-not [ClipwarpRightLang.Engine]::CanCorrect('l;ylfu','สวัสดี',$false,$true,$false)) { throw 'explicit instant rule should qualify' }
if (-not [ClipwarpRightLang.Engine]::CanCorrect('l;ylfu','สวัสดี',$false,$false,$true)) { throw 'known word should qualify' }
if ([ClipwarpRightLang.Engine]::CanCorrect('l;ylfu','สวัสดี',$false,$false,$false)) { throw 'unknown word must not auto-convert' }
if ([ClipwarpRightLang.Engine]::CanCorrect('password','password',$true,$true,$true)) { throw 'identity correction must be rejected' }
if ([ClipwarpRightLang.Engine]::CanCorrect('a','บ',$true,$false,$false)) { throw 'single char correction must be rejected' }
if ([ClipwarpRightLang.Engine]::CanCorrect(('a'*65),'คำ',$true,$false,$false)) { throw 'oversized token must be rejected' }
if (-not [ClipwarpRightLang.Engine]::IsUndoCandidate('beforeสวัสดี',12,12,'สวัสดี')) { throw 'matching tail should permit undo' }
if ([ClipwarpRightLang.Engine]::IsUndoCandidate('beforeสวัสดี',11,11,'สวัสดี')) { throw 'moved caret must block undo' }
if ([ClipwarpRightLang.Engine]::IsUndoCandidate('beforeสวัสดี',6,12,'สวัสดี')) { throw 'active selection must block undo' }
if ([ClipwarpRightLang.Engine]::IsUndoCandidate('beforeสวัสดี',12,12,'ขอบคุณ')) { throw 'changed text must block undo' }
Assert-True ([ClipwarpRightLang.Engine]::EvaluateInputTransaction(6,0,$false).State -eq [ClipwarpRightLang.EditorTransactionState]::NoInput) 'transaction distinguishes no accepted input'
$partial=[ClipwarpRightLang.Engine]::EvaluateInputTransaction(6,4,$false)
Assert-True ($partial.State -eq [ClipwarpRightLang.EditorTransactionState]::PartialInput -and
    -not $partial.CanOfferUndo -and $partial.RequiresRecovery) 'partial SendInput is never offered as a safe Undo transaction'
$unverified=[ClipwarpRightLang.Engine]::EvaluateInputTransaction(6,6,$false)
Assert-True ($unverified.State -eq [ClipwarpRightLang.EditorTransactionState]::InputSentUnverified -and
    -not $unverified.CanOfferUndo) 'full input without verified postcondition cannot offer Undo'
$committed=[ClipwarpRightLang.Engine]::EvaluateInputTransaction(6,6,$true)
Assert-True ($committed.State -eq [ClipwarpRightLang.EditorTransactionState]::Committed -and
    $committed.CanOfferUndo) 'only a full send with verified postcondition commits'
Assert-True ([ClipwarpRightLang.Engine]::EvaluateInputTransaction(6,8,$true).State -eq [ClipwarpRightLang.EditorTransactionState]::PartialInput) 'unexpected SendInput event count is rejected'
Assert-True ([ClipwarpRightLang.Engine]::EvaluateUndoTransaction($true,$false).State -eq [ClipwarpRightLang.EditorTransactionState]::UndoSentUnverified) 'Undo request and verified restoration are distinct states'
Assert-True ([ClipwarpRightLang.Engine]::EvaluateUndoTransaction($true,$true).State -eq [ClipwarpRightLang.EditorTransactionState]::Restored) 'Undo reports restored only after verification'
Assert-True ([ClipwarpRightLang.Engine]::IsExpectedTextAfterReplacement('hello world','world','โลก',6,11,$false,'hello โลก')) 'transaction checks exact full document postcondition'
Assert-True (-not [ClipwarpRightLang.Engine]::IsExpectedTextAfterReplacement('hello world','world','โลก',6,11,$false,'hello xโลก')) 'unexpected editor content fails transaction postcondition'
Assert-True ([ClipwarpRightLang.Engine]::IsExpectedTextAfterReplacement('hello world','world','โลก',6,11,$true,'hello โลก ')) 'automatic correction verifies the expected trailing space'
Write-Host 'PASS: editor transaction and recovery state machine'
Write-Host 'PASS: RightLang correction and undo safety policy'




$popupSource = Get-HereStringValue (Join-Path $root 'clipwarp-calendar-popup.ps1') 'public static class ClipwarpPopupNative'
Add-Type -TypeDefinition $popupSource
Write-Host 'PASS: compiled popup C#'

$clipSource = Get-HereStringValue (Join-Path $root 'clipwarp.ps1') 'public static extern uint GetClipboardSequenceNumber'
Add-Type -Namespace ('ClipwarpCompat' + [guid]::NewGuid().ToString('N')) -Name Clip -MemberDefinition $clipSource
$dibSource = Get-HereStringValue (Join-Path $root 'clipwarp.ps1') 'public static byte[] DecodeMasked'
Add-Type -Namespace ('ClipwarpCompat' + [guid]::NewGuid().ToString('N')) -Name Dib -MemberDefinition $dibSource
Write-Host 'PASS: compiled conversion helper C#'
# Exercise embedded helpers without constructing a watcher or opening the clipboard.
function Assert-True([bool]$Value, [string]$Name) {
    if (-not $Value) { throw $Name }
    Write-Host "PASS: $Name"
}
$allowedApps = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$allowedApps.Add('notepad')
[void]$allowedApps.Add('powershell')
$blockedApps = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$blockedApps.Add('powershell')
Assert-True ([ClipwarpRightLang.Engine]::IsApplicationEligible('NOTEPAD',$allowedApps,$blockedApps)) 'notepad is explicitly allowed'
Assert-True (-not [ClipwarpRightLang.Engine]::IsApplicationEligible('chrome',$allowedApps,$blockedApps)) 'browser is denied by default'
Assert-True (-not [ClipwarpRightLang.Engine]::IsApplicationEligible('powershell',$allowedApps,$blockedApps)) 'blocklist overrides allowlist'
Assert-True ([ClipwarpRightLang.Engine]::IsSupportedEditorClass('Edit')) 'native Edit control allowed'
Assert-True ([ClipwarpRightLang.Engine]::IsSupportedEditorClass('WindowsForms10.EDIT.app.0.1')) 'WinForms Edit control allowed'
Assert-True (-not [ClipwarpRightLang.Engine]::IsSupportedEditorClass('Chrome_RenderWidgetHostHWND')) 'browser editor rejected'
Assert-True (-not [ClipwarpRightLang.Engine]::IsSupportedEditorClass('RichEditD2DPT')) 'unverified modern editors rejected'
Write-Host 'PASS: RightLang compatibility allowlist policy'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsProfile('notepad')) 'modern Notepad has an explicit UIA profile'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsProfile('WINWORD')) 'Microsoft Word has an explicit UIA profile'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsProfile('Code')) 'VS Code has an explicit UIA profile'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsProfile('chrome')) 'generic browsers denied by UIA adapter'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::ShouldProbe($false,'notepad',$allowedApps,$blockedApps)) 'no UIA probing without opt-in'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::ShouldProbe($true,'powershell',$allowedApps,$blockedApps)) 'blocklist excludes UIA even when enabled'
Write-Host 'PASS: UIA opt-in policy and editor profiles'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsSingleLineSelection('l;ylfu')) 'bounded English correction selection permitted'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsSingleLineSelection('สวัสดี')) 'bounded Thai correction selection permitted'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsSingleLineSelection("hello`nworld")) 'multiline rich selection rejected'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsSingleLineSelection(('a'*65))) 'oversized UIA selection rejected'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsSingleLineSelection('')) 'empty UIA selection rejected'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsSingleLineSelection('a')) 'single-character UIA selection rejected'
Write-Host 'PASS: UIA bounded selection guards for Word, VS Code and Notepad'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsWordStyleSafe($false,$false,$true,$true)) 'plain editor selection is not blocked by Word policy'
Assert-True ([ClipwarpRightLang.EditorBridge]::IsWordStyleSafe($true,$true,$false,$false)) 'uniform Word formatting qualifies'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsWordStyleSafe($true,$true,$true,$false)) 'mixed Word runs are rejected'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsWordStyleSafe($true,$false,$false,$false)) 'unknown Word formatting fails closed'
Assert-True (-not [ClipwarpRightLang.EditorBridge]::IsWordStyleSafe($true,$true,$false,$true)) 'embedded rich object is rejected'
Write-Host 'PASS: Word format protection policy'
Assert-True ([ClipwarpRightLang.Engine]::ShouldSuggest('l;ylfu',$true,$false,650,700,12000)) 'idle known word may suggest'
Assert-True (-not [ClipwarpRightLang.Engine]::ShouldSuggest('l;ylfu',$true,$false,1200,700,12000)) 'sensitivity delay respected'
Assert-True (-not [ClipwarpRightLang.Engine]::ShouldSuggest('l;ylfu',$true,$true,650,700,12000)) 'ignored suggestion rejected'
Assert-True (-not [ClipwarpRightLang.Engine]::ShouldSuggest('l;ylfu',$false,$false,650,700,12000)) 'disabled suggestion remains off'
Assert-True (-not [ClipwarpRightLang.Engine]::ShouldSuggest('l;ylfu',$true,$false,650,700,200)) 'repeat debounce respected'
Write-Host 'PASS: passive suggestion and duplicate suppression policy'
$policy=[System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$policy['notepad']='manual,off'
$policy['winword']='off,inherit'
$policy['code']='auto,on'
Assert-True ([ClipwarpRightLang.Engine]::IsValidPolicy('auto,off')) 'valid per-app policy accepted'
Assert-True (-not [ClipwarpRightLang.Engine]::IsValidPolicy('admin,on')) 'unknown app mode rejected'
Assert-True ([ClipwarpRightLang.Engine]::ResolveAppMode('manual','code',$policy) -eq 'auto') 'allowed editor can opt into automatic mode'
Assert-True ([ClipwarpRightLang.Engine]::ResolveAppMode('manual','winword',$policy) -eq 'off') 'Word policy can disable correction'
Assert-True ([ClipwarpRightLang.Engine]::ResolveAppMode('off','code',$policy) -eq 'off') 'global Off always overrides app policy'
Assert-True (-not [ClipwarpRightLang.Engine]::ResolveAppHints($false,'code',$policy)) 'global hint opt-out always wins'
Assert-True (-not [ClipwarpRightLang.Engine]::ResolveAppHints($true,'notepad',$policy)) 'app hint opt-out respected'
Assert-True ([ClipwarpRightLang.Engine]::ResolveAppHints($true,'code',$policy)) 'per-app hint setting supported'
Write-Host 'PASS: per-app modes and global privacy precedence'

$t = New-Object ClipwarpWatch.OverlayTargetTracker
$now = [datetime]'2026-09-08T12:00:00Z'
$t.OnForegroundChanged('pwsh','Terminal','ConsoleWindowClass',$now)
$p=''; $title=''; $cls=''
Assert-True ($t.TryResolveTarget('SnippingTool','','',$now.AddSeconds(5),[ref]$p,[ref]$title,[ref]$cls)) 'overlay retains recent target'
Assert-True ($p -eq 'pwsh') 'overlay resolves terminal'
$t.OnForegroundChanged('chrome','ChatGPT','Chrome_WidgetWin_1',$now.AddSeconds(6))
Assert-True ($t.TryResolveTarget('SnippingTool','','',$now.AddSeconds(8),[ref]$p,[ref]$title,[ref]$cls) -and $p -eq 'chrome') 'new foreground replaces retained terminal'
Assert-True (-not $t.TryResolveTarget('SnippingTool','','',$now.AddSeconds(19),[ref]$p,[ref]$title,[ref]$cls) -and -not $t.HasRetainedTarget) 'retention expires and clears'
$t.OnForegroundChanged('pwsh','','',$now)
Assert-True (-not $t.TryResolveTarget('ShareX','','',$now.AddSeconds(-1),[ref]$p,[ref]$title,[ref]$cls)) 'backward clock clears retention'
$t.OnForegroundChanged('pwsh','','',$now)
$t.OnForegroundChanged('','','',$now.AddSeconds(1))
Assert-True (-not $t.HasRetainedTarget) 'unknown new non-overlay clears old target'

$data = New-Object Windows.Forms.DataObject
$data.SetData('ClipwarpManaged','C:\test.png')
[uint32]$updated=0
Assert-True ([ClipwarpWatch.Watcher]::IsClipboardOwnershipValid(10,0,$data,'C:\test.png',[ref]$updated) -and $updated -eq 10) 'initial converter marker establishes ownership'
Assert-True ([ClipwarpWatch.Watcher]::IsClipboardOwnershipValid(10,10,$null,'C:\test.png',[ref]$updated)) 'unchanged sequence permits normal target switching'
$newData=New-Object Windows.Forms.DataObject
$newData.SetText('C:\test.png')
Assert-True (-not [ClipwarpWatch.Watcher]::IsClipboardOwnershipValid(11,10,$newData,'C:\test.png',[ref]$updated)) 'new plain path text is not clipwarp owned'
Assert-True (-not [ClipwarpWatch.Watcher]::IsClipboardOwnershipValid(11,10,$null,'C:\test.png',[ref]$updated)) 'new inaccessible clipboard is not owned'
Assert-True (-not [ClipwarpWatch.Watcher]::IsClipboardOwnershipValid(0,0,$data,'C:\test.png',[ref]$updated)) 'unknown sequence fails closed'
Assert-True (-not [ClipwarpWatch.Watcher]::IsClipboardOwnershipValid(11,10,$data,'C:\other.png',[ref]$updated)) 'different managed path rejected'
Assert-True ([ClipwarpTransport.ClipboardWriter]::SequenceMatches(10,10)) 'compare-and-set accepts original source sequence'
Assert-True (-not [ClipwarpTransport.ClipboardWriter]::SequenceMatches(10,11)) 'compare-and-set rejects newer clipboard'
Assert-True (-not [ClipwarpTransport.ClipboardWriter]::SequenceMatches(0,0)) 'compare-and-set rejects zero sequence'
$raw = New-Object Windows.Forms.DataObject
$raw.SetData('ClipwarpManaged',(New-Object IO.MemoryStream (,[Text.Encoding]::Unicode.GetBytes("C:\test.png`0"))))
Assert-True ([ClipwarpTransport.ClipboardWriter]::Marker($raw) -eq 'C:\test.png') 'native marker decodes from stream'

$bmp=New-Object Drawing.Bitmap 3,3
$png=New-Object IO.MemoryStream
try {
    $bmp.Save($png,[Drawing.Imaging.ImageFormat]::Png)
    $data.SetData('PNG',$png); $data.SetImage($bmp)
    $register=[Func[string,uint32]]{ param($name) if($name -eq 'PNG'){49152}else{49153} }
    $formats=[ClipwarpTransport.ClipboardWriter]::Prepare($data,$register)
    Assert-True ($formats.ContainsKey(8) -and $formats.ContainsKey(49152) -and -not $formats.ContainsKey(13) -and -not $formats.ContainsKey(15)) 'native image-only transport preserves PNG and DIB without text/drop'
    Assert-True ($formats[49152][0] -eq 137 -and [BitConverter]::ToInt32($formats[8],0) -ge 40) 'PNG signature and DIB header are intact'
    $data.SetText('C:\test.png')
    $files=New-Object Collections.Specialized.StringCollection
    [void]$files.Add('C:\test.png'); $data.SetFileDropList($files)
    $formats=[ClipwarpTransport.ClipboardWriter]::Prepare($data,$register)
    Assert-True ($formats.ContainsKey(8) -and $formats.ContainsKey(49152) -and $formats.ContainsKey(13) -and $formats.ContainsKey(15)) 'native dual transport preserves all four payload formats'
    Assert-True ([BitConverter]::ToInt32($formats[15],0) -eq 20 -and [BitConverter]::ToInt32($formats[15],16) -eq 1) 'file-drop header uses Unicode paths'
} finally { $bmp.Dispose(); $png.Dispose() }
$nativeSource=[IO.File]::ReadAllText((Join-Path $root 'clipwarp-clipboard.cs'))
Assert-True ($nativeSource.IndexOf('if (OpenClipboard(owner.Handle))') -lt $nativeSource.IndexOf('if (!SequenceMatches(expected,GetClipboardSequenceNumber()))') -and $nativeSource.IndexOf('if (!SequenceMatches(expected,GetClipboardSequenceNumber()))') -lt $nativeSource.IndexOf('if (!EmptyClipboard())')) 'atomic sequence check precedes mutation inside clipboard lock'
$installer=[IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
Assert-True ($installer -match '& \$installedWatch -Autostart') 'installer enables autostart on installation'
Assert-True ($installer -match 'NoAutostart') 'installer provides NoAutostart opt-out parameter'
Assert-True ($installer -match 'favicon\.png') 'installer includes favicon for system tray icon'

$iconBmp = New-Object Drawing.Bitmap 16, 16
try {
    $testIcon = [ClipwarpWatch.IconHelper]::FromBitmap($iconBmp)
    Assert-True ($testIcon -ne $null -and $testIcon.Width -eq 16) 'IconHelper creates valid icon from bitmap'
    $testIcon.Dispose()
} finally {
    $iconBmp.Dispose()
}

$watchContent = [IO.File]::ReadAllText((Join-Path $root 'clipwarp-watch.ps1'))
Assert-True ($watchContent -match 'Restart ClipWarp') 'watcher provides tray context menu with restart option'
Assert-True ($watchContent -match 'NotifyIcon') 'watcher initializes system tray NotifyIcon'

$t.OnForegroundChanged('pwsh','','',$now)
$t.OnForegroundChanged('SnippingTool','','',$now.AddHours(1))
Assert-True ($t.TryResolveTarget('SnippingTool','','',$now.AddHours(1).AddSeconds(1),[ref]$p,[ref]$title,[ref]$cls)) 'long-lived terminal retains target when overlay starts'
$t.OnForegroundChanged('ShareX','','',$now.AddHours(1).AddSeconds(11))
Assert-True (-not $t.TryResolveTarget('ShareX','','',$now.AddHours(1).AddSeconds(13),[ref]$p,[ref]$title,[ref]$cls)) 'overlay changes do not extend retention bound'
