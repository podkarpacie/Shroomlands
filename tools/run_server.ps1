#requires -Version 5.1
<#
    Runs the exported Shroomlands dedicated server.

    The exported game's main scene is the lobby, which has no command-line
    handling. This script writes `override.cfg` next to the server binary so the
    engine boots `res://tools/dedicated_server.tscn` instead, then starts the
    authoritative server with `--headless -- --net-dedicated`.

    One process serves one transport:
        -Transport enet       UDP/ENet, desktop clients (default)
        -Transport websocket  TCP/WebSocket, browser clients + desktop clients

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tools\run_server.ps1
        powershell -ExecutionPolicy Bypass -File tools\run_server.ps1 -Port 7777 -Transport websocket
#>
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 7777,
    [ValidateSet('enet', 'websocket')]
    [string]$Transport = 'enet',
    [string]$Exe = ""
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Exe)) {
    $Exe = Join-Path $root 'build\server\ShroomlandsServer.exe'
}

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "FAIL  dedicated server binary not found: $Exe"
    Write-Host 'Export it first:'
    Write-Host '  & ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe" --headless --path . --export-release "Windows Server" "build/server/ShroomlandsServer.exe"'
    exit 1
}

$resolvedExe = (Resolve-Path -LiteralPath $Exe).Path
$exeDir = Split-Path -Parent $resolvedExe
$overridePath = Join-Path $exeDir 'override.cfg'

# A minimal override.cfg is the only way to change the start scene of an
# exported release build: `--scene` is disabled in official export templates and
# export presets cannot override `application/run/main_scene`.
@'
[application]

run/main_scene="res://tools/dedicated_server.tscn"
'@ | Set-Content -LiteralPath $overridePath -Encoding ASCII

$localIps = @(
    [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } |
        Where-Object { $_ -ne '127.0.0.1' } |
        Select-Object -Unique
)

$isWebSocket = $Transport -eq 'websocket'
$protocol = if ($isWebSocket) { 'TCP' } else { 'UDP' }
$transportLabel = if ($isWebSocket) { 'WebSocket/TCP (browser + desktop clients)' } else { 'ENet/UDP (desktop clients)' }
$firewallProtocol = if ($isWebSocket) { 'TCP' } else { 'UDP' }
$firewallName = if ($isWebSocket) { 'Shroomlands WebSocket' } else { 'Shroomlands ENet' }
$tunnelProtocol = if ($isWebSocket) { 'TCP' } else { 'UDP' }
$joinHint = if ($isWebSocket) { "ws://127.0.0.1:$Port/" } else { "127.0.0.1:$Port" }

Write-Host ''
Write-Host 'Shroomlands dedicated server'
Write-Host "  binary    : $resolvedExe"
Write-Host "  transport : $Transport"
Write-Host "  listen    : $protocol $Port - $transportLabel"
Write-Host "  local     : $joinHint"
foreach ($ip in $localIps) {
    if ($isWebSocket) {
        Write-Host "  LAN       : ws://${ip}:$Port/"
    } else {
        Write-Host "  LAN       : ${ip}:$Port"
    }
}
Write-Host ''
Write-Host "  playit.gg : create a $tunnelProtocol tunnel to 127.0.0.1:$Port (see docs/HOSTING.md)"
Write-Host "  firewall  : allow inbound $firewallProtocol $Port, or run:"
Write-Host "              New-NetFirewallRule -DisplayName '$firewallName' -Direction Inbound -Protocol $firewallProtocol -LocalPort $Port -Action Allow"
if ($isWebSocket) {
    Write-Host '  browser   : serve build\web (tools\serve_web.ps1), enter the public host:port in the lobby'
} else {
    Write-Host '  browser   : browsers need WebSocket; restart with -Transport websocket for web clients'
}
Write-Host ''
Write-Host '  One process serves one transport. This server speaks only the transport above.'
Write-Host ''
Write-Host 'Press Ctrl+C to stop.'
Write-Host ''

& $resolvedExe --headless -- --net-dedicated "--port=$Port" "--transport=$Transport"
exit $LASTEXITCODE
