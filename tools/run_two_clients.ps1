#requires -Version 5.1
<#
    Local two-client smoke test against the exported server build.

    Starts the exported dedicated server plus two headless clients, all from
    `build/server/ShroomlandsServer.exe` through the same `override.cfg`
    bootstrap. Succeeds when both clients log SHROOMLANDS_JOINED and every
    process is still alive a few seconds later.

    `-Transport websocket` runs the same proof over TCP/WebSocket, which is the
    transport a browser client uses (desktop clients can dial it too).

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tools\run_two_clients.ps1
        powershell -ExecutionPolicy Bypass -File tools\run_two_clients.ps1 -Transport websocket
#>
param(
    [int]$Port = 7777,
    [ValidateSet('enet', 'websocket')]
    [string]$Transport = 'enet',
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'build\server\ShroomlandsServer.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "FAIL  dedicated server binary not found: $exe"
    Write-Host 'Export it with: tools\run_server.ps1 (see docs\HOSTING.md).'
    exit 1
}
$resolvedExe = (Resolve-Path -LiteralPath $exe).Path
$exeDir = Split-Path -Parent $resolvedExe

@'
[application]

run/main_scene="res://tools/dedicated_server.tscn"
'@ | Set-Content -LiteralPath (Join-Path $exeDir 'override.cfg') -Encoding ASCII

$logDir = Join-Path $root 'build\two_clients'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$serverOut = Join-Path $logDir 'server.log'
$serverErr = Join-Path $logDir 'server.err.log'
$clientOut = @((Join-Path $logDir 'client_1.log'), (Join-Path $logDir 'client_2.log'))
$clientErr = @((Join-Path $logDir 'client_1.err.log'), (Join-Path $logDir 'client_2.err.log'))
foreach ($file in @($serverOut, $serverErr) + $clientOut + $clientErr) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

function Wait-ForLog {
    param([string]$Path, [string]$Pattern, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $Path) -and
            (Select-String -LiteralPath $Path -Pattern $Pattern -Quiet -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$server = $null
$clients = @()
try {
    $protocol = if ($Transport -eq 'websocket') { 'TCP/WebSocket' } else { 'UDP/ENet' }
    Write-Host "Starting dedicated server on $protocol port $Port ..."
    $server = Start-Process -FilePath $resolvedExe `
        -ArgumentList '--headless', '--', '--net-dedicated', "--port=$Port", "--transport=$Transport" `
        -WorkingDirectory $exeDir -RedirectStandardOutput $serverOut `
        -RedirectStandardError $serverErr -PassThru
    if (-not (Wait-ForLog -Path $serverOut -Pattern 'SHROOMLANDS_DEDICATED' -Seconds 15)) {
        throw 'server never reported SHROOMLANDS_DEDICATED'
    }
    Write-Host "  pid $($server.Id) is listening."

    for ($i = 0; $i -lt 2; $i++) {
        Write-Host "Starting client $($i + 1) ..."
        $clients += Start-Process -FilePath $resolvedExe `
            -ArgumentList '--headless', '--', '--join=127.0.0.1', "--port=$Port", "--transport=$Transport" `
            -WorkingDirectory $exeDir -RedirectStandardOutput $clientOut[$i] `
            -RedirectStandardError $clientErr[$i] -PassThru
    }

    $joined = $true
    for ($i = 0; $i -lt 2; $i++) {
        if (-not (Wait-ForLog -Path $clientOut[$i] -Pattern 'SHROOMLANDS_JOINED' -Seconds $TimeoutSeconds)) {
            Write-Host "FAIL  client $($i + 1) did not join."
            $joined = $false
        } else {
            Write-Host "  client $($i + 1) joined."
        }
    }

    Start-Sleep -Seconds 4
    $alive = $true
    if ($server.HasExited) {
        Write-Host "FAIL  server exited with code $($server.ExitCode)."
        $alive = $false
    }
    for ($i = 0; $i -lt $clients.Count; $i++) {
        if ($clients[$i].HasExited) {
            Write-Host "FAIL  client $($i + 1) exited with code $($clients[$i].ExitCode)."
            $alive = $false
        }
    }

    Write-Host ''
    Write-Host '================ SERVER STDOUT ================'
    Get-Content -LiteralPath $serverOut -ErrorAction SilentlyContinue
    Write-Host '================ SERVER STDERR ================'
    Get-Content -LiteralPath $serverErr -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 2; $i++) {
        Write-Host "================ CLIENT $($i + 1) STDOUT ================"
        Get-Content -LiteralPath $clientOut[$i] -ErrorAction SilentlyContinue
        Write-Host "================ CLIENT $($i + 1) STDERR ================"
        Get-Content -LiteralPath $clientErr[$i] -ErrorAction SilentlyContinue
    }

    if ($joined -and $alive) {
        Write-Host 'PASS  2 clients connected to the exported dedicated server.'
        exit 0
    }
    exit 1
}
finally {
    foreach ($process in @($clients) + @($server)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
