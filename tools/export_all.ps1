#requires -Version 5.1
<#
    Exports all three presets with editor-only project settings removed.

    Two settings in project.godot exist only for the editor toolchain:
      * `editor_plugins/enabled` (the godot_ai MCP plugin), and
      * `autoload/_mcp_game_helper` (the plugin's runtime helper).

    They are not gameplay and must not appear in a shipped pack. The godot_ai
    addon strips the autoload itself when its editor plugin is active, but the
    plugin path still lands in project.binary. This script snapshots
    project.godot, removes both entries for the duration of the export, runs the
    same `--export-release` commands documented in README.md, and restores the
    file in `finally` - even when an export fails.

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tools\export_all.ps1
#>
param(
    [switch]$SkipServer
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$godot = Join-Path $root 'Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe'
$project = Join-Path $root 'project.godot'
$backup = Join-Path ([System.IO.Path]::GetTempPath()) 'shroomlands_project.godot.backup'

if (-not (Test-Path -LiteralPath $godot)) {
    Write-Host "FAIL  Godot console binary not found: $godot"
    exit 1
}

$jobs = @(
    @{ Name = 'Windows Desktop'; Path = (Join-Path $root 'build\windows\Shroomlands.exe') },
    @{ Name = 'Web'; Path = (Join-Path $root 'build\web\index.html') }
)
if (-not $SkipServer) {
    $jobs += @{ Name = 'Windows Server'; Path = (Join-Path $root 'build\server\ShroomlandsServer.exe') }
}

New-Item -ItemType Directory -Force -Path (Join-Path $root 'build\windows') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'build\web') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'build\server') | Out-Null
# Keep Godot's editor scan away from exported artifacts. Without this,
# build/web/index.png is imported as a project texture and lands in the next
# pack as res://build/web/index.png.import.
Set-Content -LiteralPath (Join-Path $root 'build\.gdignore') -Value '' -NoNewline

Copy-Item -LiteralPath $project -Destination $backup -Force
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$failures = 0

try {
    # Filesystem-safe line edit: drop the autoload entry and the whole
    # [editor_plugins] section, leaving every other byte intact.
    $lines = [System.IO.File]::ReadAllLines($project)
    $filtered = New-Object System.Collections.Generic.List[string]
    $inEditorPlugins = $false
    foreach ($line in $lines) {
        if ($line -eq '[editor_plugins]') {
            $inEditorPlugins = $true
            continue
        }
        if ($inEditorPlugins -and $line.StartsWith('[')) {
            $inEditorPlugins = $false
        }
        if ($inEditorPlugins) {
            continue
        }
        if ($line -match '^_mcp_game_helper\s*=') {
            continue
        }
        $filtered.Add($line)
    }
    [System.IO.File]::WriteAllLines($project, $filtered, $utf8NoBom)

    foreach ($job in $jobs) {
        Write-Host "===== EXPORT $($job.Name) ====="
        & $godot --headless --path $root --export-release $job.Name $job.Path
        $code = $LASTEXITCODE
        Write-Host "EXITCODE=$code"
        if ($code -ne 0) {
            $failures++
        }
        Write-Host ''
    }
}
finally {
    Copy-Item -LiteralPath $backup -Destination $project -Force
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    Write-Host 'project.godot restored.'
}

$webPck = Join-Path $root 'build\web\index.pck'
if (Test-Path -LiteralPath $webPck) {
    $bytes = [System.IO.File]::ReadAllBytes($webPck)
    $needle = [System.Text.Encoding]::ASCII.GetBytes('godot_ai')
    $found = $false
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
        if ($bytes[$i] -eq $needle[0]) {
            $match = $true
            for ($j = 1; $j -lt $needle.Length; $j++) {
                if ($bytes[$i + $j] -ne $needle[$j]) {
                    $match = $false
                    break
                }
            }
            if ($match) {
                $found = $true
                break
            }
        }
    }
    if ($found) {
        Write-Host 'FAIL  build/web/index.pck still contains the string godot_ai.'
        $failures++
    } else {
        Write-Host 'PASS  build/web/index.pck contains no godot_ai string.'
    }
}

if ($failures -ne 0) {
    Write-Host "FAIL  $failures export check(s) failed."
    exit 1
}
Write-Host 'PASS  all exports completed and the web pack is addon-free.'
exit 0
