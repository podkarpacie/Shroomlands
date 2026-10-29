#requires -Version 5.1
<#
    Two-process multiplayer proof for Shroomlands.

    Starts a headless host and a headless client (separate OS processes) over
    ENet by default, or over TCP/WebSocket with `-Transport websocket`. The
    client walks for one second, steps it into a creature's reach, gathers
    three konops and reports its progression. Prints both logs and fails unless
    both sides report NET_RESULT players=2 walked=1, the client logged HP_DROP,
    the host's roster carries the client's real hp/level/gold, the client's
    inventory reached the server (INV_RECV), and neither log contains ERROR.

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tests\run_network_test.ps1
        powershell -ExecutionPolicy Bypass -File tests\run_network_test.ps1 -Transport websocket
#>
param(
    [ValidateSet('enet', 'websocket')]
    [string]$Transport = 'enet'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$godot = Join-Path $root 'Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe'
$hostLog = Join-Path $PSScriptRoot '_net_host.log'
$hostErrLog = Join-Path $PSScriptRoot '_net_host.err.log'
$clientLog = Join-Path $PSScriptRoot '_net_client.log'
$clientErrLog = Join-Path $PSScriptRoot '_net_client.err.log'
$logs = @($hostLog, $hostErrLog, $clientLog, $clientErrLog)

foreach ($log in $logs) {
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
    "--net-transport=$Transport"
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

    $stdout = $Run.OutTask.Result
    $stderr = $Run.ErrTask.Result
    [System.IO.File]::WriteAllText($Run.StdoutPath, $stdout, $utf8NoBom)
    [System.IO.File]::WriteAllText($Run.StderrPath, $stderr, $utf8NoBom)
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

$hostRun = $null
$clientRun = $null
$failures = New-Object System.Collections.Generic.List[string]

try {
    Write-Host 'Starting host ...'
    $hostRun = Start-GodotProcess -Arguments ($commonArgs + '--net-host') `
        -StdoutPath $hostLog -StderrPath $hostErrLog

    Start-Sleep -Seconds 2

    Write-Host 'Starting client ...'
    $clientRun = Start-GodotProcess -Arguments ($commonArgs + '--net-join=127.0.0.1') `
        -StdoutPath $clientLog -StderrPath $clientErrLog

    Wait-GodotProcess -Run $hostRun -TimeoutMs 25000
    Wait-GodotProcess -Run $clientRun -TimeoutMs 25000
}
finally {
    Stop-GodotRun -Run $clientRun
    Stop-GodotRun -Run $hostRun
}

Write-Host ''
Write-Host '================ HOST STDOUT ================'
if (Test-Path -LiteralPath $hostLog) { Get-Content -LiteralPath $hostLog -Encoding UTF8 } else { Write-Host '(missing)' }
Write-Host '================ HOST STDERR ================'
if (Test-Path -LiteralPath $hostErrLog) { Get-Content -LiteralPath $hostErrLog -Encoding UTF8 } else { Write-Host '(missing)' }
Write-Host '================ CLIENT STDOUT =============='
if (Test-Path -LiteralPath $clientLog) { Get-Content -LiteralPath $clientLog -Encoding UTF8 } else { Write-Host '(missing)' }
Write-Host '================ CLIENT STDERR =============='
if (Test-Path -LiteralPath $clientErrLog) { Get-Content -LiteralPath $clientErrLog -Encoding UTF8 } else { Write-Host '(missing)' }
Write-Host '============================================='
Write-Host ''

if ($null -ne $hostRun) { Write-Host ("Host exit code:   {0}" -f $hostRun.ExitCode) }
if ($null -ne $clientRun) { Write-Host ("Client exit code: {0}" -f $clientRun.ExitCode) }

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

function Test-HarnessLog {
    param([string]$Label, [string]$StdoutPath, [string]$StderrPath)

    $text = Get-CombinedLog -StdoutPath $StdoutPath -StderrPath $StderrPath
    if ([string]::IsNullOrWhiteSpace($text)) {
        $script:failures.Add("$Label log is empty")
        return
    }

    $resultLine = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^NET_RESULT') {
            $resultLine = $line
        }
    }
    if ($null -eq $resultLine) {
        $script:failures.Add("$Label log has no NET_RESULT line")
    }
    elseif ($resultLine -notmatch '^NET_RESULT players=2(\s|$)') {
        $script:failures.Add("$Label did not report a complete session with players=2 ($resultLine)")
    }
    elseif ($resultLine -notmatch 'walked=1(\s|$)') {
        $script:failures.Add("$Label did not prove movement ($resultLine)")
    }
    elseif ($Label -eq 'client' -and $resultLine -notmatch 'hp_dropped=1(\s|$)') {
        $script:failures.Add("$Label never took enemy damage ($resultLine)")
    }

    if ($text -match 'ERROR') {
        $errorLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match 'ERROR') {
                $errorLines.Add($line)
            }
        }
        $script:failures.Add("$Label log contains ERROR: " + ($errorLines -join ' | '))
    }
}

Test-HarnessLog -Label 'host' -StdoutPath $hostLog -StderrPath $hostErrLog
Test-HarnessLog -Label 'client' -StdoutPath $clientLog -StderrPath $clientErrLog

function Get-ReportedEnemyCount {
    param([string]$Label, [string]$StdoutPath, [string]$StderrPath)

    $text = Get-CombinedLog -StdoutPath $StdoutPath -StderrPath $StderrPath
    $resultLine = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^NET_RESULT') {
            $resultLine = $line
        }
    }
    if ($null -eq $resultLine) {
        $script:failures.Add("$Label log has no NET_RESULT line to read enemies= from")
        return -1
    }
    if ($resultLine -match 'enemies=(\d+)') {
        return [int]$Matches[1]
    }
    $script:failures.Add("$Label NET_RESULT has no enemies= count ($resultLine)")
    return -1
}

# Enemy roster proof: `Main` spawns the creatures on the server and the
# MultiplayerSpawner has to replicate every one of them to the client.
$hostEnemies = Get-ReportedEnemyCount -Label 'host' -StdoutPath $hostLog -StderrPath $hostErrLog
$clientEnemies = Get-ReportedEnemyCount -Label 'client' -StdoutPath $clientLog -StderrPath $clientErrLog
Write-Host ("Enemies reported: host={0} client={1}" -f $hostEnemies, $clientEnemies)
$minimumEnemies = 4
if ($hostEnemies -lt $minimumEnemies) {
    $failures.Add("host reported $hostEnemies enemies, expected at least $minimumEnemies")
}
if ($clientEnemies -lt $minimumEnemies) {
    $failures.Add("client reported $clientEnemies enemies, expected at least $minimumEnemies")
}
if ($hostEnemies -ge 0 -and $clientEnemies -ge 0 -and $hostEnemies -ne $clientEnemies) {
    $failures.Add("peers disagree on the enemy count (host=$hostEnemies client=$clientEnemies)")
}

# Networked chat proof: the client's line must come back through the server
# relay and appear in the host log, verbatim.
$chatText = 'hello from client'
$hostText = Get-CombinedLog -StdoutPath $hostLog -StderrPath $hostErrLog
$clientText = Get-CombinedLog -StdoutPath $clientLog -StderrPath $clientErrLog
$chatReceipt = $null
foreach ($line in ($hostText -split "`r?`n")) {
    if ($line -match ('^CHAT_RECV sender=Player \d+ text=' + [regex]::Escape($chatText) + '(\s|$)')) {
        $chatReceipt = $line
    }
}
if ($null -eq $chatReceipt) {
    $failures.Add("host log has no CHAT_RECV line for '$chatText'")
}
else {
    Write-Host ("Chat proof: {0}" -f $chatReceipt)
}

# Roster proof: the server has to hold the client's real vitals and gold, and a
# client has to see the whole roster (both players), not just itself.
function Get-RosterEntries {
    param([string]$Text)

    $entries = New-Object System.Collections.Generic.List[object]
    $rosterText = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^NET(?:_RESULT)?\s' -and $line -match 'roster=(\S+)') {
            $rosterText = $Matches[1]
        }
    }
    if ([string]::IsNullOrEmpty($rosterText) -or $rosterText -eq '-') {
        return $entries
    }
    foreach ($chunk in ($rosterText -split ';')) {
        if ($chunk -match '^(\d+):(\d+(?:\.\d+)?)/(-?\d+)/(-?\d+)$') {
            $entries.Add([pscustomobject]@{
                PeerId = [int]$Matches[1]
                Hp = [double]$Matches[2]
                Level = [int]$Matches[3]
                Gold = [int]$Matches[4]
            })
        }
    }
    return $entries
}

$hostRoster = @(Get-RosterEntries -Text $hostText)
$clientRoster = @(Get-RosterEntries -Text $clientText)
$hostRosterText = ($hostRoster | ForEach-Object {
    "peer={0} hp={1} level={2} gold={3}" -f $_.PeerId, $_.Hp, $_.Level, $_.Gold
}) -join ', '
$clientRosterText = ($clientRoster | ForEach-Object {
    "peer={0} hp={1} level={2} gold={3}" -f $_.PeerId, $_.Hp, $_.Level, $_.Gold
}) -join ', '
Write-Host ("Roster: host=<{0}>" -f $hostRosterText)
Write-Host ("Roster: client=<{0}>" -f $clientRosterText)

$hostEntries = @($hostRoster | Where-Object { $_.PeerId -ne 1 })
if ($hostEntries.Count -lt 1) {
    $failures.Add("host roster has no remote peer entry ($hostRosterText)")
}
foreach ($entry in $hostEntries) {
    if ($entry.Hp -ge 100.0 -or $entry.Hp -le 0.0) {
        $failures.Add("host roster shows the client at hp $($entry.Hp), expected damage from 100")
    }
    if ($entry.Level -lt 1) {
        $failures.Add("host roster shows the client at level $($entry.Level)")
    }
    if ($entry.Gold -ne 50) {
        $failures.Add("host roster shows the client at gold $($entry.Gold), expected the starting 50")
    }
}
if ($clientRoster.Count -lt 2) {
    $failures.Add("client roster only holds $($clientRoster.Count) player(s): $clientRosterText")
}

# Damage proof: the client must take a hit while connected. Its HP only moves
# when the server routes the bite to the owner and the owner's vitals
# synchronizer reports it back.
$hpProof = $null
foreach ($line in ($clientText -split "`r?`n")) {
    if ($line -match '^HP_DROP from=(\d+) to=(\d+)') {
        if ([int]$Matches[1] -gt 0 -and [int]$Matches[2] -lt [int]$Matches[1]) {
            $hpProof = $line
        }
    }
}
if ($null -eq $hpProof) {
    $failures.Add("client log has no HP_DROP line: an enemy bite never reached the client's own body")
}
else {
    Write-Host ("HP proof: {0}" -f $hpProof)
}

# Inventory proof: the client's three konops must arrive on the server.
$invReceipt = $null
foreach ($line in ($hostText -split "`r?`n")) {
    if ($line -match '^INV_RECV peer=(\d+) konop=(\d+)') {
        if ([int]$Matches[1] -ne 1 -and [int]$Matches[2] -eq 3) {
            $invReceipt = $line
        }
    }
}
if ($null -eq $invReceipt) {
    $failures.Add("host log has no INV_RECV line reporting 3 konops from the client")
}
else {
    Write-Host ("Inventory proof: {0}" -f $invReceipt)
}

if ($null -eq $hostRun) {
    $failures.Add('host process never started')
}
elseif ($hostRun.TimedOut) {
    $failures.Add('host process did not exit within 25 s')
}
elseif ($hostRun.ExitCode -ne 0) {
    $failures.Add("host exited with code $($hostRun.ExitCode)")
}

if ($null -eq $clientRun) {
    $failures.Add('client process never started')
}
elseif ($clientRun.TimedOut) {
    $failures.Add('client process did not exit within 25 s')
}
elseif ($clientRun.ExitCode -ne 0) {
    $failures.Add("client exited with code $($clientRun.ExitCode)")
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($failure in $failures) {
        Write-Host ("FAIL  " + $failure)
    }
    exit 1
}

Write-Host ''
Write-Host ("PASS  host and client both reached players=2 over $Transport with a synced walked position, the host received the chat line, the client took enemy damage (HP_DROP), the host roster carries the client's hp/level/gold, the client's 3 konops reached the server (INV_RECV), both peers reported the same enemy count ($hostEnemies >= $minimumEnemies), and there were no errors")
exit 0
