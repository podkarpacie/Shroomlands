# Hosting Shroomlands

This page covers the exported builds, not running from source. Export first:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export_all.ps1
```

That produces:

| Build | Path | What it is |
| --- | --- | --- |
| Windows Desktop | `build\windows\Shroomlands.exe` | Game client, can also host a listen server |
| Web | `build\web\index.html` | Browser client (static files) |
| Windows Server | `build\server\ShroomlandsServer.exe` | Headless dedicated server |

## 1. Ports and transports

| Port | Protocol | Used by | Notes |
| --- | --- | --- | --- |
| 7777 | **UDP** (ENet) | Desktop client + `-Transport enet` server (default) | Desktop-only sessions |
| 7777 | **TCP** (WebSocket) | Browser client + `-Transport websocket` server | Same number, different protocol |
| 8000 | TCP (HTTP) | `tools/serve_web.ps1` | Static files for the web client, not a game port |

ENet is UDP. Forwarding TCP 7777 will not work for an ENet server. Forward **UDP 7777**.
A WebSocket server is the opposite: forward **TCP 7777** (or whatever `-Port` you chose).

**One server process serves one transport.** `-Transport enet` speaks only ENet/UDP;
`-Transport websocket` speaks only WebSocket/TCP. A mixed ENet + WebSocket instance would
need a second `MultiplayerAPI` and is out of scope. Pick the transport that matches your
players:

- Desktop players → `-Transport enet` (the default) and a UDP tunnel/forward.
- Browser players → `-Transport websocket` and a TCP tunnel/forward.
- Desktop and browser players **in one session** → not supported yet. One instance
  speaks one transport, so running two servers gives two separate worlds. A shared
  session needs a lobby transport selector or a bridge.

The lobby has a **Port** field next to the address (default `7777`). **Host** and **Join**
both use it, so a tunnelled public port such as `34567` is usable. Values outside
`1024–65535` are rejected inline without touching the network.

A desktop client can also dial a WebSocket server through the engine
(`Network.join(ip, port, "websocket")`, used by `tests\run_websocket_test.ps1`), but the
shipped lobby has no transport selector, so a human desktop player still joins with ENet.

## 2. Run the dedicated server

```powershell
# From the repo root. Blocks until Ctrl+C. UDP/ENet for desktop clients.
powershell -ExecutionPolicy Bypass -File tools\run_server.ps1

# WebSocket/TCP for browser clients (and desktop clients that ask for it).
powershell -ExecutionPolicy Bypass -File tools\run_server.ps1 -Transport websocket

# Same thing on another local port (for tests that dial it explicitly)
powershell -ExecutionPolicy Bypass -File tools\run_server.ps1 -Port 7801 -Transport websocket
```

The script:

1. Writes `override.cfg` next to `ShroomlandsServer.exe`. The exported main
   scene is the lobby and the official export template does not allow
   `--scene`, so this is how the binary is pointed at
   `res://tools/dedicated_server.tscn`.
2. Starts `ShroomlandsServer.exe --headless -- --net-dedicated --port=<Port> --transport=<Transport>`.
3. Prints the LAN address, the protocol, the port and the matching firewall command.

Expected log for ENet (default):

```
SHROOMLANDS_DEDICATED transport=enet port=7777
  listening on UDP 7777 (ENet/UDP)
SHROOMLANDS_WORLD_LOADING scene=res://scenes/main.tscn
```

Expected log for WebSocket:

```
SHROOMLANDS_DEDICATED transport=websocket port=7777
  listening on TCP 7777 (WebSocket/TCP)
SHROOMLANDS_WORLD_LOADING scene=res://scenes/main.tscn
```

The server owns plots, enemies, player spawns, vitals and the roster. It has no
local player and no rendering.

### LAN checklist

1. Run `tools\run_server.ps1` (add `-Transport websocket` for browser players).
2. Allow the app through Windows Defender Firewall, or run the printed
   `New-NetFirewallRule` command as Administrator. UDP for ENet, TCP for WebSocket.
3. On another PC, start `Shroomlands.exe`, type the host's LAN IPv4 address
   (for example `192.168.0.9`) and the port (`7777`) and press **Join**.
4. Browser players: serve `build\web` over HTTP, open it, and enter the host's LAN
   address and the WebSocket port in the lobby.

`tools\run_two_clients.ps1` is a one-command local smoke test: it starts the
dedicated server plus two headless clients and checks that both connect. Add
`-Transport websocket` to run the same proof over TCP.

## 3. playit.gg (UDP for ENet, TCP for WebSocket)

playit.gg's free tier supports generic **UDP** and **TCP** tunnels. The tunnel type must
match the server transport; a TCP tunnel will never carry ENet traffic.

1. Create an account at <https://playit.gg> and download the playit agent.
2. Run the agent and open the link it prints. Claim the agent to your account.
3. In the dashboard choose **Create Tunnel**:
   - Desktop server (`-Transport enet`): type **UDP**, local `127.0.0.1:7777`.
   - Browser server (`-Transport websocket`): type **TCP**, local `127.0.0.1:7777`.
   - Region: closest to the server.
4. Copy the public endpoint playit assigns, for example
   `amber.example.playit.gg:34567`.

playit relays the traffic over an outbound connection from the agent, so you do
**not** need a router port-forward. The host's firewall may still prompt for
`ShroomlandsServer.exe` and the playit agent; allow both.

### The public port is random

playit assigns the **public** port and does not let you choose it. The lobby now has a
**Port** field, so enter playit's port there:

- Desktop: address `amber.example.playit.gg`, port `34567`, Join.
- Browser: same host and port; the page must be served over plain HTTP for a `ws://`
  endpoint. If playit (or another tunnel) gives you a TLS `wss://` endpoint, enter the full
  `wss://…` URL in the address field instead; the Port field is then unused.

The tunnel is UDP or TCP, never both. A playit UDP tunnel is for the ENet server; a TCP
tunnel is for the WebSocket server. Two servers on two local ports are two separate
worlds: desktop and browser players cannot share one session yet.

## 4. Cloudflare Tunnel (WebSocket only, not UDP)

Cloudflare Tunnel is useful for the **web build** and for an HTTPS dashboard.
It is not an ENet transport for this project.

```powershell
# Quick demo tunnel for the static web build
tools\serve_web.ps1 -Port 8000
cloudflared tunnel --url http://localhost:8000
```

A named tunnel plus a DNS record gives a stable HTTPS URL for `build\web`.

Cloudflare Tunnel forwards HTTP/HTTPS and WebSocket (TCP) traffic. It does
**not** carry arbitrary public UDP. Cloudflare Spectrum can proxy UDP, but UDP
on Spectrum requires an Enterprise contract; Cloudflare's Zero Trust UDP path
requires every player to install and run WARP, which is not viable for public
game clients. **Do not tell players to connect to a Cloudflare Tunnel hostname
for the ENet server.**

A WebSocket-mode server (`-Transport websocket`) can sit behind an HTTP tunnel,
which would give browsers a `wss://` hostname. That path is not exercised by this
repo's tests; if you use it, put the full `wss://…` URL in the lobby address field
and serve the web page over HTTPS.

## 5. VPS fallback

The repo ships a **Windows x86_64** server preset. A Windows VPS is the
straightforward option:

1. Copy `build\server\ShroomlandsServer.exe` and the generated `override.cfg`
   to the VPS. (Or copy the repo and run `tools\run_server.ps1` there.)
2. Open inbound **UDP 7777** (ENet) or **TCP 7777** (WebSocket), matching the
   server's `-Transport`:

   ```powershell
   # ENet (default)
   New-NetFirewallRule -DisplayName 'Shroomlands ENet' -Direction Inbound `
     -Protocol UDP -LocalPort 7777 -Action Allow

   # WebSocket
   New-NetFirewallRule -DisplayName 'Shroomlands WebSocket' -Direction Inbound `
     -Protocol TCP -LocalPort 7777 -Action Allow
   ```

3. Start the server, then connect with the VPS's public IPv4 and the port the
   server listens on (default 7777). Browser clients need `-Transport websocket`
   and a TCP forward.

A Linux VPS requires adding a Linux export preset (the repo has no Linux
preset) or running the Windows build under Wine. Do not assume the Windows
binary runs on Linux.

Typical `ufw` rules if you add a Linux build later:

```bash
sudo ufw allow 7777/udp   # ENet
sudo ufw allow 7777/tcp   # WebSocket
```

## 6. Serve the web build

```powershell
powershell -ExecutionPolicy Bypass -File tools\serve_web.ps1
# http://127.0.0.1:8000/index.html
```

The Web preset uses the **nothreads** template (`variant/thread_support=false`),
so it does **not** require `Cross-Origin-Opener-Policy` /
`Cross-Origin-Embedder-Policy` headers. `python -m http.server` is enough;
GitHub Pages, Netlify, Cloudflare Pages and nginx also work if they serve
`.wasm` as `application/wasm`. The download is about 39.5 MB of wasm plus a
~224 KB PCK.

The web build is rendered with **Compatibility (WebGL 2.0)**, not Forward+.
Godot 4.7.2's web export template has no WebGPU backend; forcing
`rendering/renderer/rendering_method.web="forward_plus"` still starts the
Compatibility renderer. Desktop stays on Forward+.

### Web multiplayer

Browsers speak WebSocket, so start the server in websocket mode:

```powershell
# TCP 7777, accepts browser clients
powershell -ExecutionPolicy Bypass -File tools\run_server.ps1 -Transport websocket

# Serve the static web build over HTTP
powershell -ExecutionPolicy Bypass -File tools\serve_web.ps1
# http://127.0.0.1:8000/index.html
```

In the browser lobby, enter the server address and the WebSocket port and press **Join**.
`Network.join()` builds `ws://host:port/`; a full `wss://…` URL is used verbatim for TLS
tunnels. The server logs `SHROOMLANDS_DEDICATED transport=websocket port=7777`.

A WebSocket server also accepts desktop clients that ask for that transport
(`Network.join(ip, port, "websocket")`, proven by `tests\run_websocket_test.ps1`). The
shipped lobby has no transport selector, so a human desktop player joins with ENet: one
server instance is either desktop-only (ENet) or browser-capable (WebSocket).

A browser cannot host: `WebSocketMultiplayerPeer.create_server` needs a listening socket.
The lobby's Host button reports that instead of failing silently. An HTTPS-served page
also cannot open a plain `ws://` socket (mixed content) — serve the build over HTTP on the
LAN, or put a TLS tunnel in front and use `wss://`.

## 7. Troubleshooting

| Symptom | Check |
| --- | --- |
| `FAIL dedicated server binary not found` | Run `tools\export_all.ps1` or the `--export-release "Windows Server"` command in `README.md` |
| `Can't run project: no main scene defined` | `override.cfg` is missing or malformed next to the server EXE. Run `tools\run_server.ps1`, which writes it |
| Server starts but prints no `SHROOMLANDS_DEDICATED` | Another process owns the port. `Get-NetUDPEndpoint -LocalPort 7777` (ENet) or `Get-NetTCPConnection -LocalPort 7777` (WebSocket) shows the PID |
| Client says `Connection failed` | Server not running; wrong host or port; **transport mismatch** (ENet client vs `-Transport websocket` server); firewall |
| Join briefly loads the world, then returns to the menu | Expected on failure: the client hands over early so the server's spawn packets find `main.tscn` ready, and Network unwinds to the lobby with `Connection failed: …` |
| Desktop lobby cannot join a WebSocket server | Expected: the lobby has no transport selector. Use the ENet server for desktop play, or `Network.join(ip, port, "websocket")` from code |
| `connect` works on LAN but not over the internet | The public endpoint must match the transport. UDP for ENet, TCP for WebSocket; check the router/VPS firewall |
| playit endpoint does not work | Confirm the tunnel is **UDP** for ENet or **TCP** for WebSocket, the agent is online, and the public port is typed into the lobby's Port field |
| Browser Join fails | Start the server with `-Transport websocket`; use the TCP public port; an HTTPS page needs `wss://`, not `ws://` |
| Web page stays black | Wait for the 39.5 MB wasm; serve over HTTP(S), not `file://`; check the browser console; WebGL 2 is required |
| Web Host fails | Expected: browsers cannot listen. Serve the web build and Join a websocket-mode server |
| Port field shows an inline error | Enter a whole number between 1024 and 65535 |
| `ERROR: Parameter "data.tree" is null` in old server logs | Fixed in `tools/dedicated_server.gd`; re-export |
| Port already in use | Stop the old process: `Stop-Process -Id <pid>` |

Useful commands:

```powershell
Get-NetUDPEndpoint -LocalPort 7777 | Select-Object LocalAddress,LocalPort,OwningProcess
Get-NetTCPConnection -LocalPort 7777 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress,LocalPort,OwningProcess
Get-Process ShroomlandsServer,Shroomlands -ErrorAction SilentlyContinue
```

## 8. Files

- `tools\run_server.ps1` — writes `override.cfg`, prints protocol/IP/port, runs the server (`-Transport enet|websocket`).
- `tools\serve_web.ps1` — `python -m http.server` for `build\web`.
- `tools\run_two_clients.ps1` — server + two headless clients smoke test (`-Transport websocket` for TCP).
- `tools\export_all.ps1` — exports all presets with editor-only settings stripped.
- `tools\dedicated_server.gd` / `.tscn` — the headless bootstrap scene; parses `--transport=enet|websocket`.
