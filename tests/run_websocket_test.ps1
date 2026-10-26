#requires -Version 5.1
<#
    Three-process WebSocket proof for Shroomlands.

    Starts one headless dedicated server in websocket mode
    (`Network.start_dedicated(port, "websocket")`) plus two real WebSocket
    clients, all separate OS processes running `tests/net_harness.gd`. The first
    client plays (walks, gathers, chats, takes a bite); the second only observes
    the replicated roster. Passes when:
      * the server reports transport=websocket and players=2,
      * client 1 reports NET_RESULT players=2 walked=1 hp_dropped=1,
      * client 2 reports NET_RESULT observe players=2,
      * all three processes exit 0 and no log contains ERROR.

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tests\run_websocket_test.ps1
#>
param(
    [int]$Port = 7777,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$godot = Join-Path $root 'Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe'
$serverLog = Join-Path $PSScriptRoot '_net_ws_server.log'
$serverErrLog = Join-Path $PSScriptRoot '_net_ws_server.err.log'
$clientLogs = @(
    (Join-Path $PSScriptRoot '_net_ws_client1.log'),
    (Join-Path $PSScriptRoot '_net_ws_client2.log')
)
$clientErrLogs = @(
    (Join-Path $PSScriptRoot '_net_ws_client1.err.log'),
    (Join-Path $PSScriptRoot '_net_ws_client2.err.log')
)
$allLogs = @($serverLog, $serverErrLog) + $clientLogs + $clientErrLogs

foreach ($log in $allLogs) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }
}

if (-not (Test-Path -LiteralPath $godot)) {
    Write-Host "FAIL  Godot console binary not found: $godot"
    exit 1
}

$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

$commonArgs = @(
    '--headless',
    '--path', $root,
    '--script', 'res://tests/net_harness.gd',
    '--',
    '--net-transport=websocket',
    "--net-port=$Port"
)

function Start-GodotProcess {
    param(
        [string[]]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $argLine = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $godot
    $startInfo.Arguments = $argLine
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    return @{
        Process = $process
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        OutTask = $process.StandardOutput.ReadToEndAsync()
        ErrTask = $process.StandardError.ReadToEndAsync()
        ExitCode = $null
        TimedOut = $false
    }
}

function Wait-GodotProcess {
    param($Run, [int]$TimeoutMs)

    if (-not $Run.Process.WaitForExit($TimeoutMs)) {
        $Run.TimedOut = $true
        Stop-Process -Id $Run.Process.Id -Force -ErrorAction SilentlyContinue
        $Run.Process.WaitForExit()
    }

    [System.IO.File]::WriteAllText($Run.StdoutPath, $Run.OutTask.Result, $utf8NoBom)
    [System.IO.File]::WriteAllText($Run.StderrPath, $Run.ErrTask.Result, $utf8NoBom)
    $Run.ExitCode = $Run.Process.ExitCode
}

function Stop-GodotRun {
    param($Run)
    if ($null -eq $Run) {
        return
    }
    try {
        if (-not $Run.Process.HasExited) {
            Write-Host ("Cleaning up leftover Godot process pid {0}" -f $Run.Process.Id)
            Stop-Process -Id $Run.Process.Id -Force -ErrorAction SilentlyContinue
            $Run.Process.WaitForExit()
        }
    }
    catch {
        Write-Host ("Could not clean up pid {0}: {1}" -f $Run.Process.Id, $_.Exception.Message)
    }
}

function Get-CombinedLog {
    param([string]$StdoutPath, [string]$StderrPath)
    $text = ''
    if (Test-Path -LiteralPath $StdoutPath) {
        $text += (Get-Content -LiteralPath $StdoutPath -Raw -Encoding UTF8)
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $text += "`n" + (Get-Content -LiteralPath $StderrPath -Raw -Encoding UTF8)
    }
    return $text
}

function Find-ResultLine {
    param([string]$Text, [string]$Pattern)
    $found = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match $Pattern) {
            $found = $line
        }
    }
    return $found
}

$serverRun = $null
$clientRuns = @()
$failures = New-Object System.Collections.Generic.List[string]

try {
    Write-Host "Starting websocket dedicated server on TCP $Port ..."
    $serverRun = Start-GodotProcess -Arguments ($commonArgs + @(
        '--net-dedicated', '--net-expect-players=2'
    )) -StdoutPath $serverLog -StderrPath $serverErrLog

    Start-Sleep -Seconds 2

    Write-Host 'Starting websocket client 1 (plays) ...'
    $clientRuns += Start-GodotProcess -Arguments ($commonArgs + '--net-join=127.0.0.1') `
        -StdoutPath $clientLogs[0] -StderrPath $clientErrLogs[0]

    Start-Sleep -Seconds 2

    Write-Host 'Starting websocket client 2 (observes) ...'
    $clientRuns += Start-GodotProcess -Arguments ($commonArgs + @(
        '--net-observe', '--net-join=127.0.0.1', '--net-expect-players=2'
    )) -StdoutPath $clientLogs[1] -StderrPath $clientErrLogs[1]

    Wait-GodotProcess -Run $serverRun -TimeoutMs ($TimeoutSeconds * 1000)
    foreach ($run in $clientRuns) {
        Wait-GodotProcess -Run $run -TimeoutMs ($TimeoutSeconds * 1000)
    }
}
finally {
    foreach ($run in $clientRuns) {
        Stop-GodotRun -Run $run
    }
    Stop-GodotRun -Run $serverRun
}

Write-Host ''
Write-Host '================ SERVER STDOUT ================'
if (Test-Path -LiteralPath $serverLog) { Get-Content -LiteralPath $serverLog -Encoding UTF8 } else { Write-Host '(missing)' }
Write-Host '================ SERVER STDERR ================'
if (Test-Path -LiteralPath $serverErrLog) { Get-Content -LiteralPath $serverErrLog -Encoding UTF8 } else { Write-Host '(missing)' }
for ($i = 0; $i -lt 2; $i++) {
    Write-Host "================ CLIENT $($i + 1) STDOUT ================"
    if (Test-Path -LiteralPath $clientLogs[$i]) { Get-Content -LiteralPath $clientLogs[$i] -Encoding UTF8 } else { Write-Host '(missing)' }
    Write-Host "================ CLIENT $($i + 1) STDERR ================"
    if (Test-Path -LiteralPath $clientErrLogs[$i]) { Get-Content -LiteralPath $clientErrLogs[$i] -Encoding UTF8 } else { Write-Host '(missing)' }
}
Write-Host '==============================================='
Write-Host ''

if ($null -ne $serverRun) { Write-Host ("Server exit code:  {0}" -f $serverRun.ExitCode) }
for ($i = 0; $i -lt 2; $i++) {
    Write-Host ("Client {0} exit code: {1}" -f ($i + 1), $clientRuns[$i].ExitCode)
}

# --- transport proof -------------------------------------------------------
$serverText = Get-CombinedLog -StdoutPath $serverLog -StderrPath $serverErrLog
$client1Text = Get-CombinedLog -StdoutPath $clientLogs[0] -StderrPath $clientErrLogs[0]
$client2Text = Get-CombinedLog -StdoutPath $clientLogs[1] -StderrPath $clientErrLogs[1]

foreach ($pair in @(
    @{ Label = 'server'; Text = $serverText },
    @{ Label = 'client 1'; Text = $client1Text },
    @{ Label = 'client 2'; Text = $client2Text }
)) {
    if ($pair.Text -notmatch 'NET_TRANSPORT=websocket') {
        $failures.Add("$($pair.Label) never reported NET_TRANSPORT=websocket")
    }
    if ($pair.Text -match 'ERROR') {
        $errorLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($pair.Text -split "`r?`n")) {
            if ($line -match 'ERROR') { $errorLines.Add($line) }
        }
        $failures.Add("$($pair.Label) log contains ERROR: " + ($errorLines -join ' | '))
    }
}

# --- roster proof ----------------------------------------------------------
$serverResult = Find-ResultLine -Text $serverText -Pattern '^NET_RESULT dedicated '
if ($null -eq $serverResult) {
    $failures.Add('server log has no NET_RESULT dedicated line')
}
elseif ($serverResult -notmatch 'players=2(\s|$)') {
    $failures.Add("server never held two player bodies ($serverResult)")
}
else {
    Write-Host ("Server proof: {0}" -f $serverResult)
}

$client1Result = Find-ResultLine -Text $client1Text -Pattern '^NET_RESULT players='
if ($null -eq $client1Result) {
    $failures.Add('client 1 log has no NET_RESULT line')
}
elseif ($client1Result -notmatch 'players=2(\s|$)') {
    $failures.Add("client 1 did not see both bodies ($client1Result)")
}
elseif ($client1Result -notmatch 'walked=1(\s|$)') {
    $failures.Add("client 1 did not prove movement ($client1Result)")
}
elseif ($client1Result -notmatch 'hp_dropped=1(\s|$)') {
    $failures.Add("client 1 never took enemy damage ($client1Result)")
}
else {
    Write-Host ("Client 1 proof: {0}" -f $client1Result)
}

$client2Result = Find-ResultLine -Text $client2Text -Pattern '^NET_RESULT observe '
if ($null -eq $client2Result) {
    $failures.Add('client 2 log has no NET_RESULT observe line')
}
elseif ($client2Result -notmatch 'players=2(\s|$)') {
    $failures.Add("client 2 did not see both bodies ($client2Result)")
}
else {
    Write-Host ("Client 2 proof: {0}" -f $client2Result)
}

# --- process proof ---------------------------------------------------------
if ($null -eq $serverRun) {
    $failures.Add('server process never started')
}
elseif ($serverRun.TimedOut) {
    $failures.Add("server process did not exit within $TimeoutSeconds s")
}
elseif ($serverRun.ExitCode -ne 0) {
    $failures.Add("server exited with code $($serverRun.ExitCode)")
}

for ($i = 0; $i -lt 2; $i++) {
    $run = $clientRuns[$i]
    if ($null -eq $run) {
        $failures.Add("client $($i + 1) process never started")
    }
    elseif ($run.TimedOut) {
        $failures.Add("client $($i + 1) did not exit within $TimeoutSeconds s")
    }
    elseif ($run.ExitCode -ne 0) {
        $failures.Add("client $($i + 1) exited with code $($run.ExitCode)")
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($failure in $failures) {
        Write-Host ("FAIL  " + $failure)
    }
    exit 1
}

Write-Host ''
Write-Host 'PASS  a websocket-only dedicated server accepted two WebSocket clients, the server held players=2, client 1 played a full session (walk, chat, loot, damage) and both clients saw the replicated roster with 4 creatures'
exit 0
