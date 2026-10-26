#requires -Version 5.1
<#
    Serves the exported web build over plain HTTP.

    The Web preset is exported with the nothreads template, so it does not need
    COOP/COEP headers and a plain `python -m http.server` is enough.

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tools\serve_web.ps1
        powershell -ExecutionPolicy Bypass -File tools\serve_web.ps1 -Port 8080
#>
param(
    [int]$Port = 8000,
    [string]$Root = ""
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path $repo 'build\web'
}

if (-not (Test-Path -LiteralPath (Join-Path $Root 'index.html'))) {
    Write-Host "FAIL  web build not found: $Root\index.html"
    Write-Host 'Export it first:'
    Write-Host '  & ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe" --headless --path . --export-release "Web" "build/web/index.html"'
    exit 1
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) {
    Write-Host 'FAIL  python is not on PATH (Python 3 is required for http.server).'
    exit 1
}

$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($null -ne $busy) {
    Write-Host "FAIL  TCP port $Port is already in use (pid $($busy[0].OwningProcess))."
    exit 1
}

$localIps = @(
    [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } |
        Where-Object { $_ -ne '127.0.0.1' } |
        Select-Object -Unique
)

Write-Host ''
Write-Host 'Shroomlands web build'
Write-Host "  root : $resolvedRoot"
Write-Host "  open : http://127.0.0.1:$Port/index.html"
foreach ($ip in $localIps) {
    Write-Host "  LAN  : http://${ip}:$Port/index.html"
}
Write-Host ''
Write-Host 'Press Ctrl+C to stop.'
Write-Host ''

& python -m http.server $Port --bind 0.0.0.0 --directory $resolvedRoot
exit $LASTEXITCODE
