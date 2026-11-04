"""Scores spikes/split/check.sh: the tone (system audio) must be on the right only and the
microphone on the left only. Prints each side's level and how far each leaks into the other.
Usage: python3 spikes/split/score.py build/split/split.wav"""
import sys

import numpy as np
from scipy.io import wavfile

rate, x = wavfile.read(sys.argv[1])
x = x.astype(float) / (32768.0 if x.dtype == np.int16 else 1.0)
left, right = x[:, 0], x[:, 1]


def db(power):
    return 10 * np.log10(power + 1e-20)


def tone_fit(signal, freq=1000.0, block=4800):
    """Fits the tone in 0.1 s blocks: the engine's drift control bends its pitch by a few
    ppm, which over seconds would leave a phase error that looks like leakage."""
    tone, rest = [], []
    for start in range(0, len(signal) - block + 1, block):
        piece = signal[start:start + block]
        t = np.arange(block) / rate
        basis = np.stack([np.sin(2 * np.pi * freq * t), np.cos(2 * np.pi * freq * t)], axis=1)
        coef, *_ = np.linalg.lstsq(basis, piece, rcond=None)
        fitted = basis @ coef
        tone.append(fitted)
        rest.append(piece - fitted)
    tone, rest = np.concatenate(tone), np.concatenate(rest)
    return np.mean(tone ** 2), rest


# Only where the tone plays on the right, so silence before and after doesn't flatter it.
envelope = np.convolve(right ** 2, np.ones(4800) / 4800, mode="same")
on = envelope > 0.5 * envelope.max()
tone_right, residual_right = tone_fit(right[on])
tone_left, residual_left = tone_fit(left[on])
mic = np.mean(residual_left ** 2)
print(f"tone on the right   {db(tone_right):7.1f} dBFS over {on.sum() / rate:.1f} s")
print(f"tone on the left    {db(tone_left):7.1f} dBFS  (leak {db(tone_left) - db(tone_right):6.1f} dB)")
print(f"mic on the left     {db(mic):7.1f} dBFS")
# A routing leak would put the microphone on the right sample for sample, so the right's
# remainder is projected on the left's; what's left over is the tone's own resampling noise.
gain = np.dot(residual_right, residual_left) / np.dot(residual_left, residual_left)
print(f"rest of the right   {db(np.mean(residual_right ** 2)):7.1f} dBFS")
print(f"mic on the right    {db(gain ** 2 * mic):7.1f} dBFS  (leak {20 * np.log10(abs(gain) + 1e-20):6.1f} dB)")
