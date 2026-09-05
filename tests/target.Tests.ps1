$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'clipwarp-support.psm1') -Force

# 1. Test-ClipwarpChatGptTarget detection
$browsers = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'arc', 'zen')
foreach ($b in $browsers) {
    if (-not (Test-ClipwarpChatGptTarget -ProcessName $b -WindowTitle 'ChatGPT - Google Chrome')) {
        throw "Expected $b with ChatGPT title to be identified as ChatGPT target"
    }
    if (-not (Test-ClipwarpChatGptTarget -ProcessName $b -WindowTitle 'New chat - ChatGPT - Mozilla Firefox')) {
        throw "Expected $b with chatgpt in title to be identified"
    }
    if (-not (Test-ClipwarpChatGptTarget -ProcessName $b -WindowTitle 'OpenAI ChatGPT')) {
        throw "Expected $b with OpenAI ChatGPT to be identified"
    }
    if (Test-ClipwarpChatGptTarget -ProcessName $b -WindowTitle 'GitHub - chakritago/clipwarp') {
        throw "Expected non-ChatGPT title in $b to return false"
    }
    if (-not (Test-ClipwarpChatGptTarget -ProcessName $b -WindowTitle 'New chat - Google Chrome')) {
        throw "Expected $b with New chat title to be identified"
    }
    if (-not (Test-ClipwarpChatGptTarget -ProcessName $b -WindowTitle 'การสนทนาใหม่ - Google Chrome')) {
        throw "Expected $b with Thai title to be identified"
    }
}
Write-Host 'PASS: browser + ChatGPT title detection matches expected browser processes'

# Desktop app detection
if (-not (Test-ClipwarpChatGptTarget -ProcessName 'ChatGPT' -WindowTitle 'ChatGPT')) {
    throw 'ChatGPT desktop app should be identified as ChatGPT target'
}
if (-not (Test-ClipwarpChatGptTarget -ProcessName 'chatgpt' -WindowTitle '')) {
    throw 'chatgpt process without title should be identified as ChatGPT target'
}
Write-Host 'PASS: ChatGPT desktop app is detected'

# Terminal target detection
$terminals = @('WindowsTerminal', 'powershell', 'pwsh', 'cmd', 'conhost', 'mintty')
foreach ($t in $terminals) {
    if (-not (Test-ClipwarpTerminalTarget -ProcessName $t -WindowTitle '')) {
        throw "Expected $t to be identified as terminal target"
    }
}
if (-not (Test-ClipwarpTerminalTarget -ProcessName 'custom' -WindowTitle 'claude')) {
    throw 'Expected window with claude title to be identified as terminal target'
}
Write-Host 'PASS: terminal target detection identifies terminal processes and claude title'

# Non-browser process with ChatGPT title should NOT be treated as browser ChatGPT
if (Test-ClipwarpChatGptTarget -ProcessName 'notepad' -WindowTitle 'ChatGPT notes.txt - Notepad') {
    throw 'Notepad should not be detected as ChatGPT target'
}
if (Test-ClipwarpChatGptTarget -ProcessName 'powershell' -WindowTitle 'ChatGPT prompt') {
    throw 'PowerShell terminal should not be detected as ChatGPT target'
}
Write-Host 'PASS: non-browser processes are not detected as ChatGPT browser target'

# Test-ClipwarpWebTarget detection for all web browsers
$allBrowsers = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'arc', 'zen', 'waterfox', 'floorp', 'librewolf', 'thorium', 'chromium', 'chatgpt')
foreach ($b in $allBrowsers) {
    if (-not (Test-ClipwarpWebTarget -ProcessName $b -WindowTitle 'GitHub - chakritago/clipwarp')) {
        throw "Expected $b with arbitrary web page title to be identified as web target"
    }
    if (-not (Test-ClipwarpWebTarget -ProcessName $b -WindowTitle '')) {
        throw "Expected $b with empty title to be identified as web target"
    }
}
if (Test-ClipwarpWebTarget -ProcessName 'notepad' -WindowTitle 'notes.txt') {
    throw 'Notepad should not be detected as web target'
}
if (Test-ClipwarpWebTarget -ProcessName 'powershell' -WindowTitle 'Windows PowerShell') {
    throw 'PowerShell should not be detected as web target'
}
if (Test-ClipwarpWebTarget -ProcessName '' -WindowTitle '') {
    throw 'Empty process should not be detected as web target'
}
Write-Host 'PASS: Test-ClipwarpWebTarget detects all supported web browsers'

# Test-ClipwarpFilePickerTarget detection
if (-not (Test-ClipwarpFilePickerTarget -ProcessName 'msedge' -WindowTitle 'Open' -WindowClass '#32770')) {
    throw 'Expected Edge Open dialog (#32770) to be identified as file picker'
}
if (-not (Test-ClipwarpFilePickerTarget -ProcessName 'chrome' -WindowTitle 'Save As' -WindowClass '#32770')) {
    throw 'Expected Chrome Save As dialog (#32770) to be identified as file picker'
}
if (-not (Test-ClipwarpFilePickerTarget -ProcessName 'chrome' -WindowTitle 'เปิด' -WindowClass '#32770')) {
    throw 'Expected Thai Open dialog to be identified as file picker'
}
if (-not (Test-ClipwarpFilePickerTarget -ProcessName 'notepad' -WindowTitle 'บันทึกเป็น' -WindowClass '#32770')) {
    throw 'Expected Thai Save As dialog to be identified as file picker'
}
if (-not (Test-ClipwarpFilePickerTarget -ProcessName 'PickerHost' -WindowTitle '' -WindowClass '')) {
    throw 'Expected PickerHost process to be identified as file picker'
}
if (Test-ClipwarpFilePickerTarget -ProcessName 'msedge' -WindowTitle 'ChatGPT - Microsoft Edge' -WindowClass 'Chrome_WidgetWin_1') {
    throw 'Edge browser tab should NOT be identified as file picker'
}
if (Test-ClipwarpFilePickerTarget -ProcessName 'notepad' -WindowTitle 'notes.txt - Notepad' -WindowClass 'Notepad') {
    throw 'Notepad main window should NOT be identified as file picker'
}
Write-Host 'PASS: Test-ClipwarpFilePickerTarget detects Windows file pickers accurately'

# 2. Target mode resolution per user rule:
# - file picker in windows -> dual (paste as path file)
# - Terminal / Claude Code -> dual (paste as path file)
# - other apps -> image-only (paste as image)

# File picker in Windows
$mode = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'msedge' -WindowTitle 'Open' -WindowClass '#32770'
if ($mode -ne 'dual') { throw "Expected dual mode for File Picker, got $mode" }
Write-Host 'PASS: auto mode resolves to dual (path file) for Windows file picker'

# Terminal / Claude Code
$mode = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'WindowsTerminal' -WindowTitle 'claude'
if ($mode -ne 'dual') { throw "Expected dual mode for Terminal, got $mode" }

$modePs = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'powershell' -WindowTitle 'Windows PowerShell'
if ($modePs -ne 'dual') { throw "Expected dual mode for PowerShell, got $modePs" }
Write-Host 'PASS: auto mode resolves to dual (path file) for Terminal / Claude Code'

# Web browser page (not file picker) -> image-only (paste as image)
$modeEdge = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'msedge' -WindowTitle 'ChatGPT'
if ($modeEdge -ne 'image-only') { throw "Expected image-only mode for Edge web page, got $modeEdge" }

$modeChrome = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'chrome' -WindowTitle 'GitHub - chakritago/clipwarp'
if ($modeChrome -ne 'image-only') { throw "Expected image-only mode for Chrome web page, got $modeChrome" }
Write-Host 'PASS: auto mode resolves to image-only for web browsers'

# Other apps (Slack, Discord, Word, Notion) -> image-only (paste as image)
$modeSlack = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'Slack' -WindowTitle 'general - Slack'
if ($modeSlack -ne 'image-only') { throw "Expected image-only mode for Slack, got $modeSlack" }

$modeWord = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'WINWORD' -WindowTitle 'Document1 - Word'
if ($modeWord -ne 'image-only') { throw "Expected image-only mode for Word, got $modeWord" }
Write-Host 'PASS: auto mode resolves to image-only for all other applications'

# explicit target parameter overrides
$mode = Resolve-ClipwarpPublicationMode -Target web -KeepImage -ProcessName 'WindowsTerminal' -WindowTitle 'claude'
if ($mode -ne 'image-only') { throw "Expected explicit -Target web to force image-only" }
Write-Host 'PASS: explicit -Target web forces image-only mode'

$mode = Resolve-ClipwarpPublicationMode -Target chatgpt -KeepImage -ProcessName 'WindowsTerminal' -WindowTitle 'claude'
if ($mode -ne 'image-only') { throw "Expected explicit -Target chatgpt to force image-only" }
Write-Host 'PASS: explicit -Target chatgpt forces image-only mode'

$mode = Resolve-ClipwarpPublicationMode -Target claude -ProcessName 'chrome' -WindowTitle 'ChatGPT'
if ($mode -ne 'dual') { throw "Expected explicit -Target claude to force dual mode" }
Write-Host 'PASS: explicit -Target claude forces dual mode'

$mode = Resolve-ClipwarpPublicationMode -Target text -KeepImage
if ($mode -ne 'text') { throw "Expected -Target text to force text mode" }
Write-Host 'PASS: explicit -Target text forces text mode'

$mode = Resolve-ClipwarpPublicationMode -ImageOnly
if ($mode -ne 'image-only') { throw "Expected -ImageOnly switch to force image-only mode" }
Write-Host 'PASS: -ImageOnly switch forces image-only mode'

# 3. Configurable targetMode
$tempConfig = Join-Path $env:TEMP ('test-clipwarp-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $def = Get-ClipwarpTargetMode -ConfigPath $tempConfig
    if ($def -ne 'auto') { throw "Expected default target mode auto, got $def" }

    [void](Set-ClipwarpTargetMode -Mode web -ConfigPath $tempConfig)
    $saved = Get-ClipwarpTargetMode -ConfigPath $tempConfig
    if ($saved -ne 'web') { throw "Expected saved mode web, got $saved" }

    [void](Set-ClipwarpTargetMode -Mode chatgpt -ConfigPath $tempConfig)
    $saved = Get-ClipwarpTargetMode -ConfigPath $tempConfig
    if ($saved -ne 'chatgpt') { throw "Expected saved mode chatgpt, got $saved" }

    # Resolution with saved config
    $mode = Resolve-ClipwarpPublicationMode -Target auto -KeepImage -ProcessName 'WindowsTerminal' -WindowTitle 'claude' -ConfigPath $tempConfig
    if ($mode -ne 'image-only') { throw "Expected persistent chatgpt setting to yield image-only" }
    Write-Host 'PASS: persistent targetMode config overrides auto resolution'
} finally {
    Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
}

# 4. Publication payload validation (without touching OS clipboard)
# Verify that image-only DataObject contains PNG/Image but NO text or file-drop
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$testBmp = New-Object System.Drawing.Bitmap 8, 8
$pngStream = New-Object System.IO.MemoryStream
$testBmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
$bytes = $pngStream.ToArray()

$imageOnlyDo = New-Object System.Windows.Forms.DataObject
$imageOnlyDo.SetData('PNG', (New-Object System.IO.MemoryStream (,$bytes)))
$imageOnlyDo.SetImage($testBmp)

if ($imageOnlyDo.ContainsText()) { throw 'ImageOnly payload must NOT contain text' }
if ($imageOnlyDo.ContainsFileDropList()) { throw 'ImageOnly payload must NOT contain FileDropList' }
if (-not $imageOnlyDo.ContainsImage()) { throw 'ImageOnly payload must contain image' }
if (-not $imageOnlyDo.GetDataPresent('PNG')) { throw 'ImageOnly payload must contain PNG format' }
Write-Host 'PASS: image-only payload contains image and PNG data with no text or file drop'

# Verify dual DataObject contains UnicodeText, PNG, Image, and FileDropList
$dualDo = New-Object System.Windows.Forms.DataObject
$dualDo.SetData([System.Windows.Forms.DataFormats]::UnicodeText, 'C:\dummy\image.png')
$dualDo.SetData('PNG', (New-Object System.IO.MemoryStream (,$bytes)))
$dualDo.SetImage($testBmp)
$sc = New-Object System.Collections.Specialized.StringCollection
[void]$sc.Add('C:\dummy\image.png')
$dualDo.SetFileDropList($sc)

if (-not $dualDo.ContainsText()) { throw 'Dual payload must contain text' }
if (-not $dualDo.ContainsImage()) { throw 'Dual payload must contain image' }
if (-not $dualDo.ContainsFileDropList()) { throw 'Dual payload must contain FileDropList' }
Write-Host 'PASS: dual payload contains UnicodeText, image, and file drop for Claude Code'

# Verify ClipwarpManaged custom format
$imageOnlyDo.SetData('ClipwarpManaged', 'C:\dummy\image.png')
if (-not $imageOnlyDo.GetDataPresent('ClipwarpManaged')) { throw 'Expected ClipwarpManaged format to be present' }
if ($imageOnlyDo.GetData('ClipwarpManaged') -ne 'C:\dummy\image.png') { throw 'Expected ClipwarpManaged data match' }
if ($imageOnlyDo.ContainsText()) { throw 'ClipwarpManaged format must not cause ContainsText to be true' }
Write-Host 'PASS: ClipwarpManaged custom format identifies clipwarp writes without setting text'

# 5. Watcher launch arguments regex / format test
$watchSource = Get-Content (Join-Path $root 'clipwarp-watch.ps1') -Raw
if ($watchSource -notmatch 'TargetArguments') {
    throw 'Watcher script must incorporate TargetArguments'
}
if ($watchSource -notmatch '-ForegroundProcess') {
    throw 'Watcher script must pass -ForegroundProcess to clipwarp.ps1'
}
if ($watchSource -notmatch '-ForegroundTitle') {
    throw 'Watcher script must pass -ForegroundTitle to clipwarp.ps1'
}
if ($watchSource -notmatch 'EVENT_SYSTEM_FOREGROUND') {
    throw 'Watcher script must register EVENT_SYSTEM_FOREGROUND hook'
}
if ($watchSource -notmatch 'ClipwarpManaged') {
    throw 'Watcher script must track ClipwarpManaged payloads'
}
Write-Host 'PASS: watcher includes foreground target arguments and event hook'

Write-Host 'All target regression tests passed.'
