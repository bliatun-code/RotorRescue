#!/usr/bin/env python3
"""Synthesize the Rotor Rescue engine sound (scripts/RotorRescue/sounds/).

The radio plays one WAV after another, so the engine is a set of clips that
join without a seam:

  loop1..loop10   one loop per rotor speed band (0.6 s)
  upN / downN     a 0.2 s pitch glide between band N and band N + 1
  start / stop    spool up from silence into band 1, and wind down from it

Every tonal part is a harmonic of the blade-pass frequency, and every clip
starts and ends on a whole number of blade passes, so any clip can follow any
clip that ends in the same band. The noise is periodic over the loop length
and the glides cross-fade it from the outgoing to the incoming loop.

The mix is tuned for the small speaker in a radio: the blade-pass rate (about
32 to 96 Hz) is kept as rhythm and implied pitch, but most of the energy sits
between 300 Hz and 4 kHz (blade slap, tail rotor, gear and motor whine), where
the speaker can reproduce it.

    python3 tools/make_sounds.py            # writes the WAV files
"""
import math
import os
import wave

import numpy as np

RATE = 32000
BANDS = 10
LOOP, GLIDE, START, STOP = 0.6, 0.2, 0.4, 0.6
LOW_HZ, HIGH_HZ = 32.0, 96.0
WOBBLE_HZ = 5.0           # slow beat; a whole number of cycles in every clip
PEAK = 0.6                # about -4.4 dBFS: near the old level on full-range speakers
DRIVE = 1.2               # soft clip strength
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "scripts", "RotorRescue", "sounds")

rng = np.random.default_rng(20261111)
MAX_K = 64
PHASES = rng.uniform(-0.35, 0.35, MAX_K + 1) * math.pi  # near-aligned: a sharp blade slap


def band_pitch(band):
    """Blade-pass frequency of a band, rounded so a loop holds whole cycles."""
    f = LOW_HZ * (HIGH_HZ / LOW_HZ) ** ((band - 1) / (BANDS - 1))
    return round(f * LOOP) / LOOP


def band_level(band):
    return 0.40 + 0.60 * ((band - 1) / (BANDS - 1)) ** 0.85


def band_load(band):
    return (band - 1) / (BANDS - 1)


def harmonic_amps(f, load):
    """Amplitude of harmonic k (index 0 unused) for blade-pass frequency f."""
    k = np.arange(MAX_K + 1, dtype=float)
    hz = k * f
    a = np.zeros(MAX_K + 1)
    a[1:4] = [0.34, 0.24, 0.16]                            # rotor thump (felt more than heard)
    with np.errstate(divide="ignore"):
        slap = np.exp(-0.5 * (np.log(np.maximum(hz, 1) / 650.0) / 0.55) ** 2)
    a[2:] += 0.42 * slap[2:] / np.sqrt(k[2:] / 6 + 1)       # blade slap around 650 Hz
    for j, amp in ((5, 0.16), (10, 0.10), (15, 0.06), (20, 0.035)):
        a[j] += amp                                        # tail rotor, five times the main rotor
    a[8] += 0.12                                           # gear mesh
    whine = 0.35 + 0.65 * load
    a[14] += 0.085 * whine                                 # electric motor
    a[28] += 0.035 * whine
    a[42] += 0.015 * whine
    a[hz > 6000] = 0
    a[0] = 0
    return a


def periodic_noise(seconds):
    """Band-limited noise (300 Hz - 4 kHz) that loops seamlessly over `seconds`."""
    n = int(round(seconds * RATE))
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    shape = np.where(freqs > 0, 1 / np.sqrt(np.maximum(freqs, 1) / 300), 0)
    shape *= 1 / (1 + (300 / np.maximum(freqs, 1)) ** 4)
    shape *= 1 / (1 + (freqs / 4000) ** 4)
    spectrum = shape * np.exp(1j * rng.uniform(0, 2 * math.pi, len(freqs)))
    x = np.fft.irfft(spectrum, n)
    return x / np.sqrt(np.mean(x ** 2))


def quiet_start(noise):
    """Rotate a noise loop so it starts at its smallest sample near the beginning."""
    return np.roll(noise, -int(np.argmin(np.abs(noise[:4000]))))


NOISE = {band: quiet_start(periodic_noise(LOOP)) for band in range(1, BANDS + 1)}


def render(theta, f, level, load, noise, t):
    """theta: blade-pass phase in cycles, f: instantaneous blade-pass frequency (Hz)."""
    out = np.zeros_like(theta)
    # Amplitudes follow the instantaneous pitch; evaluate them on a coarse grid.
    grid = np.linspace(0, len(theta) - 1, 33).astype(int)
    amps = np.array([harmonic_amps(f[i], load[i]) for i in grid])
    for k in range(1, MAX_K + 1):
        if not amps[:, k].any():
            continue
        a = np.interp(np.arange(len(theta)), grid, amps[:, k])
        out += a * np.sin(2 * math.pi * k * theta + PHASES[k])
    swish = 0.35 + 0.65 * (0.5 + 0.5 * np.cos(2 * math.pi * theta)) ** 4
    out += noise * swish * 0.085 * (0.6 + 0.4 * load)
    out *= 1 + 0.07 * np.sin(2 * math.pi * WOBBLE_HZ * t)
    return out * level


def tonal(band, theta):
    a = harmonic_amps(band_pitch(band), band_load(band))
    return sum(a[k] * np.sin(2 * math.pi * k * theta + PHASES[k]) for k in range(1, MAX_K + 1) if a[k])


def quiet_phase(band):
    """Blade phase between two slaps where the tone crosses zero: every clip of the band
    starts and ends there, so a gap between two files on the radio cannot click."""
    theta = np.linspace(0.3, 0.7, 4001)
    x = tonal(band, theta)
    crossings = np.where(np.signbit(x[:-1]) != np.signbit(x[1:]))[0]
    if len(crossings) == 0:
        return float(theta[np.argmin(np.abs(x))])
    best = crossings[np.argmin(np.abs(theta[crossings] - 0.5))]
    return float(theta[best] - x[best] * (theta[best + 1] - theta[best]) / (x[best + 1] - x[best]))


QUIET = {band: quiet_phase(band) for band in range(1, BANDS + 1)}


def glide_phase(f0, f1, seconds, ease, start=0.0, end=0.0):
    """Phase (cycles) and frequency from f0 to f1. The phase runs from `start` and
    finishes `end` past a whole cycle; a small mid-glide pitch bump makes it fit."""
    n = int(round(seconds * RATE))
    u = np.arange(n) / n
    f = f0 + (f1 - f0) * ease(u)
    bump = 4 * u * (1 - u)
    cycles = f.sum() / RATE
    turn = end - start
    whole = max(1, round(cycles - turn)) + turn
    f = f + (whole - cycles) / (bump.sum() / RATE) * bump
    theta = start + np.concatenate([[0], np.cumsum(f)[:-1]]) / RATE
    return theta, f, np.arange(n) / RATE


def smooth(u):
    return u * u * (3 - 2 * u)


def loop_clip(band):
    n = int(round(LOOP * RATE))
    t = np.arange(n) / RATE
    f = np.full(n, band_pitch(band))
    return render(QUIET[band] + f[0] * t, f, band_level(band), np.full(n, band_load(band)), NOISE[band], t)


def glide_clip(a, b):
    theta, f, t = glide_phase(band_pitch(a), band_pitch(b), GLIDE, smooth, QUIET[a], QUIET[b])
    n, u = len(t), np.arange(len(t)) / len(t)
    w = smooth(u)
    level = band_level(a) + (band_level(b) - band_level(a)) * w
    load = band_load(a) + (band_load(b) - band_load(a)) * w
    m = int(round(LOOP * RATE))
    noise = NOISE[a][:n] * np.cos(u * math.pi / 2) + NOISE[b][m - n:] * np.sin(u * math.pi / 2)
    return render(theta, f, level, load, noise, t)


def start_clip():
    f1 = band_pitch(1)
    theta, f, t = glide_phase(0.3 * f1, f1, START, lambda u: 1 - (1 - u) ** 2, 0.0, QUIET[1])
    n, u = len(t), np.arange(len(t)) / len(t)
    m = int(round(LOOP * RATE))
    level = band_level(1) * u ** 1.3
    return render(theta, f, level, np.zeros(n), NOISE[1][m - n:], t)


def stop_clip():
    f1 = band_pitch(1)
    theta, f, t = glide_phase(f1, 0.3 * f1, STOP, lambda u: u ** 1.5, QUIET[1], 0.0)
    n, u = len(t), np.arange(len(t)) / len(t)
    level = band_level(1) * (1 - u) ** 2
    return render(theta, f, level, np.zeros(n), NOISE[1][:n], t)


def main():
    clips = {f"loop{b}": loop_clip(b) for b in range(1, BANDS + 1)}
    for b in range(1, BANDS):
        clips[f"up{b}"] = glide_clip(b, b + 1)
        clips[f"down{b}"] = glide_clip(b + 1, b)
    clips["start"], clips["stop"] = start_clip(), stop_clip()
    # One gain for every clip keeps the joins seamless; a gentle soft clip tames the slap peaks.
    gain = 1 / max(np.abs(x).max() for x in clips.values())
    os.makedirs(OUT, exist_ok=True)
    for name, x in clips.items():
        y = np.tanh(DRIVE * x * gain) / math.tanh(DRIVE) * PEAK
        pcm = np.round(np.clip(y, -1, 1) * 32767).astype("<i2")
        with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm.tobytes())
    print(f"wrote {len(clips)} clips to {OUT}; band pitches "
          + ", ".join(f"{band_pitch(b):.1f}" for b in range(1, BANDS + 1)) + " Hz")


if __name__ == "__main__":
    main()
