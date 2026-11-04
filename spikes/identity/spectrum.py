# Step 4 check: level of each test tone in a recorded mix, relative to the strongest.
# usage: python spectrum.py WAV...
import sys

import numpy as np
import soundfile as sf

TONES = {440: "Firefox copy A", 660: "Firefox copy B", 550: "Brave X", 330: "Brave X/Y"}

for path in sys.argv[1:]:
    x, rate = sf.read(path)
    left = x[:, 0] if x.ndim > 1 else x
    left = left[rate // 2:]  # skip the first half second
    # A gap in the source's own playback (an <audio loop> restart) smears its energy
    # across nearby frequencies, which says nothing about leakage between sources, so
    # only the longest stretch without silence is measured.
    # A gap is at least 1 ms of exact zeros; a sine crosses zero on single samples.
    zero = np.abs(left) < 1e-6
    run = np.convolve(zero.astype(int), np.ones(48, int), "same") >= 48
    gap = np.zeros_like(zero)
    for i in np.nonzero(run)[0]:
        gap[max(0, i - 24):i + 24] = True
    # A jump bigger than a clean sine can make is a restart in the source; split there too.
    spectrum0 = np.abs(np.fft.rfft(left * np.hanning(len(left))))
    tone = np.fft.rfftfreq(len(left), 1 / rate)[np.argmax(spectrum0)]
    limit = 1.05 * 2 * np.pi * tone / rate * np.abs(left).max()
    jumps = np.nonzero(np.abs(np.diff(left)) > limit)[0]
    for j in jumps:
        gap[max(0, j - 2):j + 3] = True
    if len(jumps):
        print(f"  note: {len(jumps)} jump(s) in the source at "
              f"{', '.join(f'{(j + rate // 2) / rate:.3f} s' for j in jumps[:5])}")
    best, start = (0, 0), None
    for i, g in enumerate(np.append(gap, True)):
        if not g and start is None:
            start = i
        elif g and start is not None:
            best = max(best, (i - start, start))
            start = None
    left = left[best[1]:best[1] + best[0]]
    spectrum = np.abs(np.fft.rfft(left * np.hanning(len(left))))
    freqs = np.fft.rfftfreq(len(left), 1 / rate)
    def level(f):
        band = (freqs > f - 3) & (freqs < f + 3)
        return 20 * np.log10(spectrum[band].max() + 1e-12)
    levels = {f: level(f) for f in TONES}
    top = max(levels.values())
    peak = 20 * np.log10(np.abs(left).max() + 1e-12)
    print(f"{path.split('/')[-1]}: peak {peak:.1f} dBFS over {len(left) / rate:.2f} s without gaps")
    for f, name in TONES.items():
        print(f"  {f} Hz ({name}): {levels[f] - top:+.1f} dB")
    want = 660 if "control" in path else 440
    others = max(v for f, v in levels.items() if f != want)
    verdict = "PASS" if levels[want] == top and levels[want] - others >= 60 and peak > -40 else "FAIL"
    print(f"  {verdict}: {want} Hz is {levels[want] - others:.1f} dB above any other tone")
