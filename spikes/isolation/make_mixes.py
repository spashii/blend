# Spike S6 fixtures: clean speech mixed with four kinds of background at fixed SNRs.
# usage: python make_mixes.py SPEECH_DIR OUT_DIR
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

RATE = 48000
SNRS_DB = [0, 6]
rng = np.random.default_rng(7)


def load(path):
    audio, rate = sf.read(path, dtype="float32")
    assert rate == RATE, (path, rate)
    return audio if audio.ndim == 1 else audio.mean(axis=1)


def rms(x):
    return float(np.sqrt(np.mean(x**2)) + 1e-12)


def pink(n):
    # Voss-McCartney style: filtered white noise with a 1/f slope.
    white = rng.standard_normal(n)
    spectrum = np.fft.rfft(white)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    spectrum[1:] /= np.sqrt(freqs[1:])
    spectrum[0] = 0
    return np.fft.irfft(spectrum, n).astype(np.float32)


def babble(n, sources):
    out = np.zeros(n, dtype=np.float32)
    for i, src in enumerate(sources):
        offset = int(i * 0.7 * RATE)
        tiled = np.tile(src, int(np.ceil((n + offset) / len(src))) + 1)[offset : offset + n]
        out += tiled / rms(tiled)
    return out


def music(n):
    # Chord progression with a kick and hi-hat pattern at 100 bpm.
    t = np.arange(n) / RATE
    chords = [[220.0, 277.18, 329.63], [196.0, 246.94, 293.66], [174.61, 220.0, 261.63],
              [196.0, 246.94, 329.63]]
    beat = 60 / 100
    out = np.zeros(n, dtype=np.float64)
    for i, chord in enumerate(chords * int(np.ceil(t[-1] / (4 * beat * len(chords))) + 1)):
        start = int(i * 4 * beat * RATE)
        if start >= n:
            break
        seg = slice(start, min(n, start + int(4 * beat * RATE)))
        tt = t[seg] - t[start]
        env = np.exp(-tt * 0.6)
        for f in chord:
            out[seg] += env * (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(4 * np.pi * f * tt))
    for k in range(int(t[-1] / beat) + 1):
        s = int(k * beat * RATE)
        kick = np.arange(min(int(0.15 * RATE), n - s)) / RATE
        out[s : s + len(kick)] += 3 * np.sin(2 * np.pi * 55 * kick) * np.exp(-kick * 25)
        h = s + int(beat / 2 * RATE)
        if h < n:
            hat = rng.standard_normal(min(int(0.04 * RATE), n - h)) * np.exp(
                -np.arange(min(int(0.04 * RATE), n - h)) / RATE * 120)
            out[h : h + len(hat)] += 0.8 * hat
    return out.astype(np.float32)


def keyboard(n):
    out = np.zeros(n, dtype=np.float32)
    pos = 0
    while pos < n:
        pos += int(rng.uniform(0.08, 0.25) * RATE)
        click = rng.standard_normal(min(int(0.012 * RATE), max(0, n - pos)))
        out[pos : pos + len(click)] += click * np.exp(-np.arange(len(click)) / RATE * 400)
    return out


def main():
    speech_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    babble_sources = [load(p) for p in sorted(speech_dir.glob("babble_*.wav"))]
    for clean_path in sorted(speech_dir.glob("clean_*.wav")):
        speech = load(clean_path)
        speech = np.concatenate([np.zeros(RATE // 2, np.float32), speech,
                                 np.zeros(RATE // 2, np.float32)])
        n = len(speech)
        speech = speech / rms(speech) * 0.05
        sf.write(out_dir / f"{clean_path.stem}.wav", speech, RATE, subtype="FLOAT")
        noises = {"pink": pink(n), "babble": babble(n, babble_sources), "music": music(n),
                  "keyboard": keyboard(n)}
        for name, noise in noises.items():
            for snr in SNRS_DB:
                scaled = noise / rms(noise) * rms(speech) / (10 ** (snr / 20))
                mix = speech + scaled
                sf.write(out_dir / f"{clean_path.stem}_{name}_{snr}db.wav", mix, RATE,
                         subtype="FLOAT")


if __name__ == "__main__":
    main()
