# Spike S4 scoring for a far-end-only take: echo removed per segment (ERLE) and far-end
# words that survive into a Whisper transcript.
# usage: python score.py RAW_3CH.wav PROCESSED.wav [PROCESSED.wav ...]
import json
import sys
import urllib.request
import uuid
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "isolation"))
from evaluate import transcribe  # noqa: E402

RATE = 48000
HOP = RATE // 10


def frame_energy(x):
    n = len(x) // HOP
    return np.array([np.mean(x[i * HOP:(i + 1) * HOP] ** 2) for i in range(n)])


def segments(active):
    out, start = [], None
    for i, a in enumerate(active):
        if a and start is None:
            start = i
        if not a and start is not None:
            if i - start >= 10:
                out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(active)))
    return out


def main():
    raw, rate = sf.read(sys.argv[1], dtype="float32")
    assert rate == RATE
    mic, ref = raw[:, 0], raw[:, 1:].mean(axis=1)
    e_ref, e_mic = frame_energy(ref), frame_energy(mic)
    active = e_ref > (np.max(e_ref) * 1e-4)
    segs = segments(active)
    print(f"far-end segments: {len(segs)}")
    tmp = Path("/tmp/blend-echo-mic.wav")
    sf.write(tmp, mic, RATE, subtype="FLOAT")
    print(f"raw mic transcript: {transcribe(tmp)!r}")
    for path in sys.argv[2:]:
        out, _ = sf.read(path, dtype="float32")
        e_out = frame_energy(out)
        n = min(len(e_out), len(e_mic))
        cells = []
        for a, b in segs:
            b = min(b, n)
            # Skip the first 0.5 s of each segment while the filter adapts.
            a2 = min(b, a + 5)
            erle = 10 * np.log10(np.sum(e_mic[a2:b]) / (np.sum(e_out[a2:b]) + 1e-15))
            residual = 10 * np.log10(np.mean(e_out[a2:b]) + 1e-15)
            cells.append(f"{erle:5.1f}dB (res {residual:6.1f} dBFS)")
        print(f"\n{Path(path).name}")
        for i, c in enumerate(cells):
            print(f"  segment {i + 1}: ERLE {c}")
        print(f"  transcript: {transcribe(Path(path))!r}")


if __name__ == "__main__":
    main()
