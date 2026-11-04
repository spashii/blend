"""Scores spikes/split/check.sh: the tone (system audio) must be on the right only and the
microphone on the left only. Prints each side's level and how far each leaks into the other.
Usage: python3 spikes/split/score.py build/split/split.wav"""
import sys
import wave

import numpy as np

w = wave.open(sys.argv[1])
rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
raw = w.readframes(w.getnframes())
x = (np.frombuffer(raw, "<f4") if width == 4 else np.frombuffer(raw, "<i2") / 32768.0).reshape(-1, channels)
left, right = x[:, 0].astype(float), x[:, 1].astype(float)


def db(power):
    return 10 * np.log10(power + 1e-20)


def tone_fit(signal, freq=1000.0):
    t = np.arange(len(signal)) / rate
    basis = np.stack([np.sin(2 * np.pi * freq * t), np.cos(2 * np.pi * freq * t)], axis=1)
    coef, *_ = np.linalg.lstsq(basis, signal, rcond=None)
    fitted = basis @ coef
    return np.mean(fitted ** 2), signal - fitted


# Only where the tone plays on the right, so silence before and after doesn't flatter it.
envelope = np.convolve(right ** 2, np.ones(4800) / 4800, mode="same")
on = envelope > 0.5 * envelope.max()
tone_right, residual_right = tone_fit(right[on])
tone_left, residual_left = tone_fit(left[on])
mic = np.mean(residual_left ** 2)
print(f"tone on the right   {db(tone_right):7.1f} dBFS over {on.sum() / rate:.1f} s")
print(f"tone on the left    {db(tone_left):7.1f} dBFS  (leak {db(tone_left) - db(tone_right):6.1f} dB)")
print(f"mic on the left     {db(mic):7.1f} dBFS")
print(f"rest of the right   {db(np.mean(residual_right ** 2)):7.1f} dBFS  "
      f"(mic leak at most {db(np.mean(residual_right ** 2)) - db(mic):6.1f} dB)")
