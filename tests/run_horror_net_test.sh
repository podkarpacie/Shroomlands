#!/usr/bin/env bash
# Two-process proof for the multiplayer horror run (Linux desktop).
# Host and client are separate Godot processes over ENet/UDP.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot4}"
PORT="${1:-7788}"
OUT="${TMPDIR:-/tmp}/shroomlands_horror_net"
mkdir -p "$OUT"
HOST_LOG="$OUT/host.log"
CLIENT_LOG="$OUT/client.log"
rm -f "$HOST_LOG" "$CLIENT_LOG"

cleanup() {
    [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null
}
trap cleanup EXIT

timeout 45 "$GODOT" --headless --path . --script res://tests/horror_net_harness.gd -- \
    --horror-host --horror-port="$PORT" >"$HOST_LOG" 2>&1 &
HOST_PID=$!
sleep 2
timeout 45 "$GODOT" --headless --path . --script res://tests/horror_net_harness.gd -- \
    --horror-join=127.0.0.1 --horror-port="$PORT" >"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?
HOST_PID=""; CLIENT_PID=""

echo "=== host ==="
grep -E 'HORROR_|ERROR|SCRIPT' "$HOST_LOG" | tail -20
echo "=== client ==="
grep -E 'HORROR_|ERROR|SCRIPT' "$CLIENT_LOG" | tail -20

FAIL=0
grep -q 'HORROR_HOST ok=1 ' "$HOST_LOG" || { echo "FAIL host result"; FAIL=1; }
grep -q 'HORROR_CLIENT ok=1 ' "$CLIENT_LOG" || { echo "FAIL client result"; FAIL=1; }
grep -q 'ERROR' "$HOST_LOG" && { echo "FAIL host log has ERROR"; FAIL=1; }
grep -q 'ERROR' "$CLIENT_LOG" && { echo "FAIL client log has ERROR"; FAIL=1; }
[ "$HOST_EXIT" -eq 0 ] || { echo "FAIL host exit=$HOST_EXIT"; FAIL=1; }
[ "$CLIENT_EXIT" -eq 0 ] || { echo "FAIL client exit=$CLIENT_EXIT"; FAIL=1; }
if [ "$FAIL" -ne 0 ]; then
    echo "Logs: $HOST_LOG $CLIENT_LOG"
    exit 1
fi
echo "PASS  two-process horror run: area travel, replicated leader, HUD marker, server-heard voice, leader-gated return"
