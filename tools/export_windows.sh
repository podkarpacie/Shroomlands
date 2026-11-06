#!/usr/bin/env bash
# Linux/macOS counterpart to tools/export_all.ps1: export the Windows client and
# dedicated server with the editor-only godot_ai entries stripped.
#
#     bash tools/export_windows.sh
#
# Requires the Godot 4.7.2 export templates in
# ~/.local/share/godot/export_templates/4.7.2.stable/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot4}"
CLIENT_OUT="$ROOT/build/windows/Shroomlands.exe"
SERVER_OUT="$ROOT/build/server/ShroomlandsServer.exe"

mkdir -p "$ROOT/build/windows" "$ROOT/build/server"
# Keep the editor from importing exported artifacts on the next scan.
: > "$ROOT/build/.gdignore"

BACKUP="$(mktemp)"
cp "$ROOT/project.godot" "$BACKUP"
restore() {
    cp "$BACKUP" "$ROOT/project.godot"
    rm -f "$BACKUP"
    echo "project.godot restored."
}
trap restore EXIT

# Drop the MCP autoload and the whole [editor_plugins] section, leaving every
# other byte intact. These are editor-only and must not ship in the pack.
python3 - "$ROOT/project.godot" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(True)
out = []
in_plugins = False
for line in lines:
    if line.strip() == "[editor_plugins]":
        in_plugins = True
        continue
    if in_plugins and line.startswith("["):
        in_plugins = False
    if in_plugins:
        continue
    if line.startswith("_mcp_game_helper="):
        continue
    out.append(line)
open(path, "w", encoding="utf-8").writelines(out)
PY

echo "===== EXPORT Windows Desktop ====="
"$GODOT" --headless --path "$ROOT" --export-release "Windows Desktop" "$CLIENT_OUT"
echo "===== EXPORT Windows Server ====="
"$GODOT" --headless --path "$ROOT" --export-release "Windows Server" "$SERVER_OUT"

ls -lh "$CLIENT_OUT" "$SERVER_OUT"
if grep -a -q 'godot_ai' "$CLIENT_OUT"; then
    echo "FAIL  the Windows pack still contains the godot_ai string."
    exit 1
fi
echo "PASS  Windows client + server exported without the editor addon."
