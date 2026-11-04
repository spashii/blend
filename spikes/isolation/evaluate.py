# Spike S6 scoring: word error rate (local Whisper) and SI-SDR against the clean speech,
# for each noisy mix before and after AUSoundIsolation.
# usage: python evaluate.py FIXTURES_DIR SENTENCES_TXT
import json
import re
import sys
import urllib.request
import uuid
from collections import defaultdict
from pathlib import Path

import jiwer
import numpy as np
import soundfile as sf

WHISPER = "http://127.0.0.1:8840/v1/audio/transcriptions"


def transcribe(path):
    boundary = uuid.uuid4().hex
    body = b""
    for name, value in (("model", "whisper-large-v3"), ("response_format", "json")):
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
                 f"{value}\r\n").encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
             f"filename=\"{path.name}\"\r\nContent-Type: audio/wav\r\n\r\n").encode()
    body += path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(WHISPER, data=body, headers={
        "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        return json.load(resp)["text"]


def normalize(text):
    return re.sub(r"[^a-z' ]+", " ", text.lower()).split()


def si_sdr(reference, estimate):
    # Align for the unit's latency first: search lags up to 200 ms.
    n = min(len(reference), len(estimate))
    best = None
    for lag in range(0, 9600, 48):
        est = estimate[lag : lag + n - 9600]
        ref = reference[: len(est)]
        corr = float(np.dot(ref, est))
        if best is None or corr > best[0]:
            best = (corr, lag)
    lag = best[1]
    est = estimate[lag : lag + n - 9600]
    ref = reference[: len(est)]
    alpha = np.dot(est, ref) / (np.dot(ref, ref) + 1e-12)
    target = alpha * ref
    noise = est - target
    return 10 * np.log10(np.dot(target, target) / (np.dot(noise, noise) + 1e-12))


def main():
    root = Path(sys.argv[1])
    refs = {}
    for i, line in enumerate(Path(sys.argv[2]).read_text().splitlines(), start=1):
        refs[f"clean_{i}"] = line.split("|", 1)[1]
    cache_path = root / "transcripts.json"
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}

    rows = defaultdict(lambda: defaultdict(list))
    files = sorted((root / "mixes").glob("*.wav")) + sorted((root / "isolated/out").glob("*.wav"))
    for path in files:
        stem = path.stem
        base, _, variant = stem.partition("__")
        variant = variant or "raw"
        speaker = "_".join(base.split("_")[:2])
        condition = "_".join(base.split("_")[2:]) or "clean"
        if stem not in cache:
            cache[stem] = transcribe(path)
            cache_path.write_text(json.dumps(cache, indent=1))
        wer = jiwer.wer(" ".join(normalize(refs[speaker])), " ".join(normalize(cache[stem])))
        clean, _ = sf.read(root / "mixes" / f"{speaker}.wav", dtype="float32")
        est, _ = sf.read(path, dtype="float32")
        rows[condition][variant].append((wer, si_sdr(clean, est)))

    variants = ["raw", "voice100", "hq100", "hq50"]
    print(f"{'condition':<14}" + "".join(f"{v:>20}" for v in variants))
    print(f"{'':<14}" + "".join(f"{'WER%  SI-SDR dB':>20}" for _ in variants))
    for condition in sorted(rows):
        line = f"{condition:<14}"
        for v in variants:
            vals = rows[condition].get(v)
            if vals:
                wer = 100 * np.mean([w for w, _ in vals])
                sdr = np.mean([s for _, s in vals])
                line += f"{wer:>12.1f}{sdr:>8.1f}"
            else:
                line += f"{'':>20}"
        print(line)


if __name__ == "__main__":
    main()
