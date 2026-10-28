#!/usr/bin/env python3
"""Synthesise Shroomlands' sound cues into ``assets/audio/``.

Every sound the game ships is generated here, so the audio has no external
provenance and can be reviewed, tweaked and rebuilt from source. The script is
deterministic: each cue seeds its own ``random.Random`` from its file name, no
clock or OS state is read, and the WAV header carries no timestamp, so running
it twice leaves every file byte-identical.

Output is mono 16-bit PCM at 44.1 kHz. One-shots are peak-normalised to about
-3 dBFS and get a 10 ms fade at both ends; the ambient bed is a seamless loop
and is built so that the wrap point is sample-continuous (see ``_ambient``).

Run from the repo root:

    python tools/generate_audio.py
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path

RATE = 44100
OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "audio"
# -3 dBFS. 16-bit samples are written as round(value * 32767).
PEAK = 10.0 ** (-3.0 / 20.0)
TAU = math.pi * 2.0
FADE_SECONDS = 0.010


# --- small building blocks -------------------------------------------------


def _frames(seconds: float) -> int:
    return int(round(seconds * RATE))


def _buffer(seconds: float) -> list[float]:
    return [0.0] * _frames(seconds)


def _rng(name: str) -> random.Random:
    # Seeding from text is stable across Python versions and runs (sha512).
    return random.Random(name)


def _into(
    target: list[float], source: list[float], gain: float = 1.0, at: float = 0.0
) -> None:
    """Adds ``source`` into ``target`` at ``at`` seconds, clipped to the end."""
    start = _frames(at)
    for index, value in enumerate(source):
        position = start + index
        if position >= len(target):
            break
        target[position] += value * gain


def _sine(freq: float, seconds: float, phase: float = 0.0) -> list[float]:
    step = TAU * freq / RATE
    return [math.sin(phase + step * index) for index in range(_frames(seconds))]


def _sweep(
    seconds: float, start_hz: float, end_hz: float, phase: float = 0.0
) -> list[float]:
    """Sine gliding from ``start_hz`` to ``end_hz`` with an exponential curve.

    The phase is integrated per sample, so the sound stays continuous even when
    the frequency moves far and fast.
    """
    count = _frames(seconds)
    ratio = end_hz / start_hz
    out: list[float] = []
    for index in range(count):
        position = index / (count - 1) if count > 1 else 0.0
        freq = start_hz * (ratio**position)
        phase += TAU * freq / RATE
        out.append(math.sin(phase))
    return out


def _noise(rng: random.Random, seconds: float) -> list[float]:
    return [rng.uniform(-1.0, 1.0) for _ in range(_frames(seconds))]


def _lowpass(samples: list[float], cutoff_hz: float) -> list[float]:
    # One-pole filter: cheap, stable and enough to turn hiss into texture.
    alpha = 1.0 - math.exp(-TAU * cutoff_hz / RATE)
    out: list[float] = []
    state = 0.0
    for sample in samples:
        state += alpha * (sample - state)
        out.append(state)
    return out


def _attack_decay(count: int, attack: float, decay: float) -> list[float]:
    """Linear attack, exponential decay, expressed in seconds."""
    attack_frames = max(1, _frames(attack))
    out: list[float] = []
    for index in range(count):
        if index < attack_frames:
            value = index / attack_frames
        else:
            elapsed = (index - attack_frames) / RATE
            value = math.exp(-elapsed / max(decay, 1e-4))
        out.append(value)
    return out


def _shape(samples: list[float], attack: float, decay: float) -> list[float]:
    envelope = _attack_decay(len(samples), attack, decay)
    return [sample * envelope[i] for i, sample in enumerate(samples)]


def _fade_edges(samples: list[float]) -> list[float]:
    """10 ms linear fade in and out, so a one-shot never clicks."""
    fade = min(_frames(FADE_SECONDS), len(samples) // 2)
    out = list(samples)
    for index in range(fade):
        gain = index / fade
        out[index] *= gain
        out[-1 - index] *= gain
    return out


# --- the cues --------------------------------------------------------------


def _hit() -> list[float]:
    """Melee connect: a short noisy thwack with a fast downward pitch drop."""
    out = _buffer(0.12)
    body = _shape(_sweep(0.12, 220.0, 70.0), 0.002, 0.035)
    snap = _shape(_lowpass(_noise(_rng("hit"), 0.12), 2600.0), 0.001, 0.022)
    thump = _shape(_sine(62.0, 0.12), 0.001, 0.045)
    _into(out, body, 0.85)
    _into(out, snap, 0.45)
    _into(out, thump, 0.35)
    return out


def _enemy_hit() -> list[float]:
    """Enemy reaction: softer and wetter than the player's own connect."""
    out = _buffer(0.14)
    body = _shape(_sweep(0.14, 150.0, 52.0), 0.006, 0.050)
    wet = _shape(_lowpass(_noise(_rng("enemy_hit"), 0.14), 720.0), 0.004, 0.060)
    sub = _shape(_sine(58.0, 0.14), 0.004, 0.050)
    _into(out, body, 0.70)
    _into(out, wet, 0.55)
    _into(out, sub, 0.40)
    return out


def _enemy_die() -> list[float]:
    """Descending squelch with a low noise tail."""
    out = _buffer(0.45)
    squelch = _shape(_sweep(0.45, 380.0, 70.0), 0.010, 0.260)
    wobble = _shape(_sweep(0.45, 190.0, 44.0), 0.010, 0.300)
    tail = _shape(_lowpass(_noise(_rng("enemy_die"), 0.45), 900.0), 0.030, 0.220)
    _into(out, squelch, 0.75)
    _into(out, wobble, 0.35)
    _into(out, tail, 0.30)
    return out


def _gather() -> list[float]:
    """Organic pluck/pop: a small pitch drop with a bright fibrous tick."""
    out = _buffer(0.18)
    pop = _shape(_sweep(0.18, 520.0, 250.0), 0.004, 0.055)
    fibre = _shape(_lowpass(_noise(_rng("gather"), 0.18), 2600.0), 0.001, 0.018)
    bloom = _shape(_sine(780.0, 0.18), 0.006, 0.060)
    _into(out, pop, 0.85)
    _into(out, fibre, 0.30)
    _into(out, bloom, 0.22)
    return out


def _pickup() -> list[float]:
    """Bright two-tone ding (A5, then E6) with a soft octave shimmer."""
    out = _buffer(0.20)
    for start, freq in ((0.0, 880.0), (0.075, 1318.51)):
        note = _shape(_sine(freq, 0.125), 0.003, 0.085)
        shimmer = _shape(_sine(freq * 2.0, 0.125), 0.002, 0.045)
        _into(out, note, 0.55, start)
        _into(out, shimmer, 0.14, start)
    return out


def _level_up() -> list[float]:
    """Four rising major notes: C5, E5, G5, C6."""
    out = _buffer(0.70)
    for index, freq in enumerate((523.25, 659.25, 783.99, 1046.50)):
        start = index * 0.13
        note = _shape(_sine(freq, 0.30), 0.008, 0.22)
        under = _shape(_sine(freq * 0.5, 0.30), 0.008, 0.24)
        _into(out, note, 0.50, start)
        _into(out, under, 0.16, start)
    return out


def _death() -> list[float]:
    """Slow descending minor tone with a long fade into a soft noise bed."""
    out = _buffer(0.90)
    lead = _shape(_sweep(0.90, 220.0, 110.0), 0.050, 0.480)
    third = _shape(_sweep(0.90, 261.63, 130.81), 0.050, 0.420)
    bed = _shape(_lowpass(_noise(_rng("death"), 0.90), 320.0), 0.090, 0.500)
    _into(out, lead, 0.80)
    _into(out, third, 0.30)
    _into(out, bed, 0.20)
    return out


def _place() -> list[float]:
    """Wooden thunk: a damped low body with a short splintery click."""
    out = _buffer(0.16)
    body = _shape(_sweep(0.16, 160.0, 64.0), 0.002, 0.045)
    shell = _shape(_lowpass(_noise(_rng("place"), 0.16), 1400.0), 0.001, 0.020)
    ring = _shape(_sine(238.0, 0.16), 0.002, 0.032)
    _into(out, body, 0.85)
    _into(out, shell, 0.35)
    _into(out, ring, 0.22)
    return out


def _ui_click() -> list[float]:
    """Very short, soft click for menu buttons."""
    out = _buffer(0.05)
    tick = _shape(_sine(760.0, 0.05), 0.001, 0.009)
    grit = _shape(_lowpass(_noise(_rng("ui_click"), 0.05), 4000.0), 0.001, 0.004)
    _into(out, tick, 0.55)
    _into(out, grit, 0.20)
    return out


def _ambient(seconds: float = 20.0) -> list[float]:
    """Seamless mycelial bed: detuned low drone, slow LFO, faint noise.

    The loop is sample-continuous by construction. Every periodic voice uses a
    frequency that is an integer number of cycles over the loop length (all
    multiples of 1/20 Hz), and the noise bed is generated 50 ms past the end and
    crossfaded back over the first 50 ms, so the wrap from the last sample to
    the first is the waveform's own next sample rather than a jump.
    """
    count = _frames(seconds)
    fade = _frames(0.05)
    total = count + fade
    duration = total / RATE

    rng = _rng("ambient_mycelia")
    noise = _lowpass(_noise(rng, duration), 420.0)
    noise_peak = max(abs(value) for value in noise) or 1.0
    noise = [value / noise_peak for value in noise]

    mix: list[float] = []
    for index in range(total):
        position = index / RATE
        lfo = 0.78 + 0.22 * math.sin(TAU * 0.05 * position)
        drone = (
            0.44 * math.sin(TAU * 55.00 * position)
            + 0.22 * math.sin(TAU * 55.35 * position + 0.7)
            + 0.16 * math.sin(TAU * 82.00 * position)
            + 0.10 * math.sin(TAU * 82.40 * position + 1.9)
            + 0.12 * math.sin(TAU * 27.50 * position + 2.4)
        )
        air = 0.05 * noise[index]
        mix.append(lfo * drone + air)

    # Crossfade the overhanging tail into the head: output[0] becomes the
    # sample that naturally follows the last one, so the loop is click-free.
    out = mix[:count]
    for index in range(fade):
        blend = index / fade
        out[index] = mix[index] * blend + mix[count + index] * (1.0 - blend)
    return out


CUES = {
    "hit": _hit,
    "enemy_hit": _enemy_hit,
    "enemy_die": _enemy_die,
    "gather": _gather,
    "pickup": _pickup,
    "level_up": _level_up,
    "death": _death,
    "place": _place,
    "ui_click": _ui_click,
    "ambient_mycelia": _ambient,
}

# The ambient bed is a loop, so it must not be faded at the edges.
LOOPING = {"ambient_mycelia"}


# --- output ----------------------------------------------------------------


def _write_wav(path: Path, samples: list[float]) -> int:
    # Normalise after shaping so every cue really peaks at -3 dBFS, then clamp
    # as a guard: rounding must never produce a sample outside int16.
    loudest = max((abs(value) for value in samples), default=0.0)
    scale = (PEAK / loudest) if loudest > 0.0 else 0.0
    packed = bytearray()
    for value in samples:
        sample = int(round(value * scale * 32767.0))
        packed += struct.pack("<h", max(-32768, min(32767, sample)))
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(bytes(packed))
    return len(packed) + 44


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(
        "format: %d Hz mono 16-bit PCM, peak %.1f dBFS"
        % (RATE, 20.0 * math.log10(PEAK))
    )
    for name, build in CUES.items():
        samples = build()
        if name not in LOOPING:
            samples = _fade_edges(samples)
        path = OUT_DIR / ("%s.wav" % name)
        size = _write_wav(path, samples)
        print("  %-18s %6.2f s  %8d bytes" % (path.name, len(samples) / RATE, size))
    print("wrote %d files to %s" % (len(CUES), OUT_DIR))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
