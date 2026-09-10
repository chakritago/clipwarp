$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$helperSource = [IO.File]::ReadAllText((Join-Path $repo 'clipwarp-popup-host.cs'), [Text.Encoding]::UTF8)
Add-Type -TypeDefinition $helperSource

function Check($cond, [string]$msg) {
    if (-not $cond) { throw "FAIL: $msg" }
    Write-Host "PASS: $msg"
}

# 1. Round-trip
$req = New-Object ClipwarpPopupHost.PopupRequest
$req.RequestId = 42
$req.Text = "line 1`r`nline 2: test text with symbols [OK]"
$req.ExpectedSequence = 12345
$req.HasPointer = $true
$req.PointerX = 1920
$req.PointerY = 1080

$bytes = $req.Serialize()
Check ($bytes.Length -gt 0) 'PopupRequest serializes to non-empty bytes'
$ms = New-Object IO.MemoryStream(,$bytes)
$deser = [ClipwarpPopupHost.PopupRequest]::Deserialize($ms)

Check ($deser.RequestId -eq 42) 'RequestId matches'
Check ($deser.Text -ceq $req.Text) 'Exact text preserved'
Check ($deser.ExpectedSequence -eq 12345) 'ExpectedSequence matches'
Check ($deser.HasPointer -and $deser.PointerX -eq 1920 -and $deser.PointerY -eq 1080) 'Pointer coordinates match'

# 2. Oversized payload
$huge = New-Object ClipwarpPopupHost.PopupRequest
$huge.Text = [string]::new('x', (1024 * 1024 + 10))
$oversizedRejected = $false
try {
    [void]$huge.Serialize()
} catch {
    $oversizedRejected = $true
}
Check $oversizedRejected 'Payload > 1 MiB is rejected by serializer'

# 3. Invalid magic bytes
$badBytes = [byte[]]@(0x00, 0x00, 0x01, 0x00)
$msBad = New-Object IO.MemoryStream(,$badBytes)
$badMagicRejected = $false
try {
    [void][ClipwarpPopupHost.PopupRequest]::Deserialize($msBad)
} catch {
    $badMagicRejected = $true
}
Check $badMagicRejected 'Invalid magic bytes rejected by deserializer'

# 4. Mailbox latest-only replacement
$box = New-Object ClipwarpPopupHost.PopupMailbox
$r1 = New-Object ClipwarpPopupHost.PopupRequest
$r1.RequestId = 1
$r1.Text = 'first'

$r2 = New-Object ClipwarpPopupHost.PopupRequest
$r2.RequestId = 2
$r2.Text = 'second'

$box.Post($r1)
$box.Post($r2)

$taken = $box.TakeLatest()
Check ($taken.RequestId -eq 2 -and $taken.Text -eq 'second') 'Mailbox keeps latest request'
Check ($null -eq $box.TakeLatest()) 'Mailbox emptied after TakeLatest'

# 5. Stale request dropped
$rStale = New-Object ClipwarpPopupHost.PopupRequest
$rStale.RequestId = 1
$rStale.Text = 'stale'
$box.Post($rStale)
Check ($null -eq $box.TakeLatest()) 'Older request ID is ignored by mailbox'
