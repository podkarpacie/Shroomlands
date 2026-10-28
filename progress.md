# Shroomlands — Progress

Status: MVP shipped, models integrated, toolchain extended. `main` = `c31ed8b`, clean, pushed.

## Goal
Shroomlands MVP — 3D multiplayer survival RPG, Godot 4.7.2, GDScript only. Spec: `docs/MVP_SPEC.md`.

## Current state
- **20 test suites / 911 assertions green**, all exit 0. Two real-process multiplayer proofs
  (ENet 2-process, WebSocket 3-process) pass. CI runs the same suites on every push.
- **Exports verified**: Windows 105 MB (Forward+, launches and closes clean), Web 39.5 MB wasm
  (boots in Firefox from plain `http.server`, Compatibility/WebGL2).
- **Repo**: https://github.com/podkarpacie/Shroomlands (private).
- **Models**: 4 Blockbench glTF assets authored + wired into the scenes (player, blightling,
  glowcap, emberstem). `.bbmodel` sources in `assets/models/source/`.

## Workstreams (merged)
There were two parallel lines of work. `328dbf8` (tag `v0.1.0`) is the UI overhaul —
model-backed item icons, hitbox combat, `LimbAnimator`/`SwingWeapon`, themed HUD/inventory.
My line contributed the model pipeline, the 64×64 atlas fix, test isolation, and polish.

## Done this session
- Installed **77 gamedev Agent Skills** (+router) to `~/.config/opencode/skills/`
  (`gamedev-skills/awesome-gamedev-agent-skills`, Apache-2.0, NOTICE retained).
  Verified `godot-multiplayer` loads by ID with its reference files.
- Fixed the glTF UV overflow: `pack_uv` was overflowing a 16 px atlas (used 29×50), so UVs
  exceeded 1.0 and wrapped → smeared faces. All four models rebuilt at 64×64.
- Fixed weapon shadow aliasing (PCSS dither from a small caster), death-overlay overlap,
  and plot-sign/building overlap; stamina now reads 0 while dead.
- Refreshed `docs/screenshots/02-08`.
- **Added the entire audio layer** (there was none): 10 procedural WAV cues synthesised by the
  committed `tools/generate_audio.py` (deterministic — verified byte-identical across runs),
  Master/Music/SFX bus layout, `Audio` autoload with a pooled polyphonic SFX player, a 20 s
  seamlessly looping ambient bed that starts with the world, event wiring for combat/gather/
  pickup/level/death/build, and persisted Music/SFX volume sliders in the lobby.
  Headless runs keep audio output disabled (Godot reports leaked players otherwise); tests
  re-enable it explicitly to assert playback.

- **Held items are inventory-driven.** The selected hotbar slot drives `held_item` (a replicated
  `StringName` on the player), so the owner resolves it from their inventory and every peer renders
  from the replicated id — no remote inventory needed. `HeldItem.gd` shows glowcap/emberstem in the
  left hand (upright, hand-tracked position, yaw-only orientation); the other four mushrooms have no
  model and deliberately render nothing. The club is the weapon, not an inventory item, and stays in
  the right hand.
- **Limb animation**: club-carry pose (40 % swing + forward angle), held-item carry pose for the left
  arm, turn banking, and `stepped` → footstep cue synced to the gait phase. Still procedural — the
  models have no skeleton (`animations=0, skins=0`), so no authored clips are possible yet.

## Known gaps
- No anti-cheat: peers report their own HP, gold, inventory, position; server validates shape
  only. Plots/currency are not reconciled server-side.
- Web renderer is Compatibility/WebGL2 — Forward+ is impossible in 4.7.2's web template.
- One transport per server instance (ENet XOR WebSocket); mixed sessions unsupported.
- Models are unrigged (no skeletal animation); movement uses procedural limb motion.
- No voice chat, skill trees, other biomes, raids, accounts, server browser, TLS.
- Leftover local branch `model-wiring-pre-upstream` holds discarded wiring work (local only).

## Follow-ups
- Consider hiding non-Godot skills (`opencode/autoinvoke: false`) — 78 skills are advertised.
- Server-side validation pass before any economy or PvP work.
