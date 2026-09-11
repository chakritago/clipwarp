[CmdletBinding()]
param([string]$PwshPath = 'pwsh.exe', [string]$WindowsPowerShellPath = 'powershell.exe')
$ErrorActionPreference = 'Stop'
# Each script is isolated so Add-Type and exit cannot contaminate the next test.
# Only *.Tests.ps1 in this directory are eligible; no watcher/install entrypoints.
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.Tests.ps1' | Sort-Object Name)
$failed = 0
$total = 0

# Auto-discover available PowerShell engines
$enginesToRun = @()
if (Get-Command $PwshPath -ErrorAction SilentlyContinue) {
    $enginesToRun += $PwshPath
} else {
    Write-Host "NOTE: $PwshPath not found on system PATH. Skipping pwsh engine tests."
}
if (Get-Command $WindowsPowerShellPath -ErrorAction SilentlyContinue) {
    $enginesToRun += $WindowsPowerShellPath
} else {
    Write-Host "NOTE: $WindowsPowerShellPath not found on system PATH. Skipping Windows PowerShell tests."
}

if ($enginesToRun.Count -eq 0) {
    Write-Error "No PowerShell engine found to run tests."
    exit 1
}

foreach ($engine in $enginesToRun) {
    foreach ($test in $tests) {
        $total++
        Write-Host "TEST: $engine / $($test.Name)"
        try {
            & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $test.FullName
            if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
            Write-Host "RESULT: PASS $engine / $($test.Name)"
        } catch {
            $failed++
            Write-Host "RESULT: FAIL $engine / $($test.Name): $_"
        }
    }
}
Write-Host "TOTAL: $total; PASSED: $($total-$failed); FAILED: $failed"
if ($failed) { exit 1 }
exit 0
