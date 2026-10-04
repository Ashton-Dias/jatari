#!/usr/bin/env python3
"""Synthesizes the built-in alarm tones into MyApp/Sounds/*.caf (all original, <= 30 s)."""
import subprocess, wave, os, tempfile
import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "MyApp", "Sounds")

def t(d): return np.arange(int(SR * d)) / SR
def env(n, a=0.005, r=0.05):
    e = np.ones(n); a_n, r_n = int(SR*a), int(SR*r)
    e[:a_n] = np.linspace(0, 1, a_n); e[-r_n:] = np.linspace(1, 0, r_n); return e
def silence(d): return np.zeros(int(SR * d))
def sine(f, d, amp=0.6): return amp * np.sin(2*np.pi*f*t(d)) * env(int(SR*d))
def square(f, d, amp=0.35):
    x = np.sign(np.sin(2*np.pi*f*t(d))); return amp * x * env(len(x), 0.002, 0.01)
def bell(f, d=1.2, amp=0.5):
    x = t(d); s = sum(a*np.sin(2*np.pi*f*m*x) for m, a in [(1,1),(2.76,.5),(5.4,.25),(8.9,.12)])
    return amp * s / 1.9 * np.exp(-3.2*x) * env(len(x), 0.002, 0.02)
def glide(f0, f1, d, amp=0.5, harm=True):
    f = np.linspace(f0, f1, int(SR*d)); ph = 2*np.pi*np.cumsum(f)/SR
    s = np.sin(ph) + (0.5*np.sin(2*ph) + 0.3*np.sin(3*ph) if harm else 0)
    return amp * s / (1.8 if harm else 1) * env(len(s), 0.01, 0.03)

def radar():
    unit = np.concatenate([sine(1046, .12), silence(.08), sine(1046, .12), silence(.08), sine(1318, .3), silence(.9)])
    return np.tile(unit, 8)
def chimes():
    notes = [784, 988, 1175, 1568, 1175, 988]; parts = []
    for _ in range(3):
        for n in notes: parts += [bell(n, 1.0), silence(0.1)]
        parts.append(silence(0.6))
    return np.concatenate([np.pad(p, (0, 0)) for p in parts])
def beacon():
    unit = np.concatenate([sine(660, .35, .6), sine(880, .35, .6), silence(.5)]); return np.tile(unit, 10)
def digital():
    burst = np.concatenate([square(2000, .08), silence(.07)] * 4); return np.tile(np.concatenate([burst, silence(.7)]), 8)
def gentle_rise():
    d = 20; x = t(d); chord = sum(np.sin(2*np.pi*f*x) for f in (261.6, 329.6, 392.0, 523.3)) / 4
    swell = np.linspace(0.05, 0.7, len(x)) ** 1.5; trem = 0.85 + 0.15*np.sin(2*np.pi*0.5*x)
    return 0.8 * chord * swell * trem * env(len(x), 0.5, 0.5)
def rooster():
    cock = np.concatenate([glide(500, 900, .18), glide(900, 800, .08), silence(.04), glide(650, 1000, .2),
                           silence(.05), glide(900, 1300, .25), glide(1300, 1000, .25), glide(1000, 1250, .2), glide(1250, 700, .6)])
    return np.tile(np.concatenate([cock, silence(1.2)]), 5)
def siren():
    up = glide(600, 1200, 1.0, harm=False); dn = glide(1200, 600, 1.0, harm=False); return np.tile(np.concatenate([up, dn]), 8)

SOUNDS = {"Radar": radar, "Chimes": chimes, "Beacon": beacon, "Digital": digital,
          "GentleRise": gentle_rise, "Rooster": rooster, "Siren": siren}

os.makedirs(OUT, exist_ok=True)
for name, fn in SOUNDS.items():
    x = fn()[: SR*29]; x = x / max(1e-9, np.abs(x).max()) * 0.9
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp: wav = tmp.name
    with wave.open(wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((x*32767).astype("<i2").tobytes())
    subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, os.path.join(OUT, f"{name}.caf")], check=True)
    os.unlink(wav); print(f"{name}.caf  {len(x)/SR:.1f}s")
