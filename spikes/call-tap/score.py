#!/usr/bin/env python3
"""Scores a run.sh run: the capture's rebuilds, and Call silence that is not in the source.

The speaker logs the peak of every 10 ms block it played, and the capture the peak of every
10 ms block of Call. A block is missing when the source played a non-zero sample there and
Call is exact zeros within two blocks either side. The speaker counts on the output clock and
the capture on the microphone's, so the offset between them is estimated from host times,
then refined minute by minute to follow any drift.
"""
import json
import re
import sys
from array import array

prefix = sys.argv[1]


def floats(path):
    a = array("f")
    with open(path, "rb") as f:
        a.frombytes(f.read())
    return a


call = floats(prefix + ".call.f32")
source = floats(prefix + ".source.f32")
speaker = json.load(open(prefix + ".speaker.json"))
capture = json.load(open(prefix + ".capture.json"))
guess = round((speaker["go_host"] - capture["start_called"]) * 100)


def heard(k):
    lo, hi = max(0, k - 2), min(len(call), k + 3)
    return any(call[i] != 0 for i in range(lo, hi))


def agreement(offset, start, n=6000):
    good = 0
    for j in range(start, min(start + n, len(source))):
        k = j + offset
        if 0 <= k < len(call):
            good += (source[j] != 0) == (call[k] != 0)
    return good


minute = 6000
offsets = []
offset = max(range(guess - 50, guess + 51), key=lambda o: agreement(o, 0))
for start in range(0, len(source), minute):
    offset = max(range(offset - 5, offset + 6), key=lambda o: agreement(o, start))
    offsets.append(offset)
spoken = missing = 0
runs = []
run_start = None
for j in range(len(source)):
    k = j + offsets[j // minute]
    if k < 0:
        continue
    if k >= len(call):
        break
    if source[j] == 0:
        continue
    spoken += 1
    if heard(k):
        if run_start is not None:
            runs.append((run_start, j))
            run_start = None
    else:
        missing += 1
        if run_start is None:
            run_start = j
if run_start is not None:
    runs.append((run_start, len(source)))

log = open(prefix + ".log").read()
# For a run with dead taps: how long Call stayed silent while the source spoke, from the
# first kill to the first block heard again.
kills = [float(t) for t in re.findall(r"([\d.]+) killed tap", log)]
recovery = None
if kills:
    start = json.load(open(prefix + ".capture.json"))["start_called"]
    first = int(kills[0] * 100)
    # The end of the last stretch of missing Call that began within a minute of the kill.
    ends = [b for a, b in runs if first - 100 <= a + offsets[0] <= first + 6000]
    recovery = round((max(ends) + offsets[0] - first) / 100, 2) if ends else 0
    if runs and runs[-1][1] == len(source) and ends and max(ends) == len(source):
        recovery = "never"
diags = re.findall(r"diag (.*)", log)
last = diags[-1] if diags else ""
restarts = int(re.search(r"restarts=(\d+)", last).group(1)) if "restarts=" in last else -1
dead = re.search(r"dead-tap-rebuilds=(\d+)", last)
events = re.findall(r"event (\w+)", log)
loads = [float(l.split()[2]) for l in open(prefix + ".load") if len(l.split()) > 2]
result = {
    "seconds_captured": round(len(call) / 100, 1),
    "offset_blocks": [offsets[0], offsets[-1]],
    "offset_guess": guess,
    "source_speech_s": round(spoken / 100, 1),
    "call_missing_s": round(missing / 100, 2),
    "missing_runs_over_0.2s": [
        (round(a / 100, 1), round((b - a) / 100, 2)) for a, b in runs if b - a > 20
    ],
    "rebuilds": restarts,
    "dead_tap_rebuilds": int(dead.group(1)) if dead else 0,
    "events": {e: events.count(e) for e in sorted(set(events))},
    "taps_killed": len(kills),
    "call_back_after_first_kill_s": recovery,
    "load_1min": [min(loads), max(loads)] if loads else [],
}
print(json.dumps(result, indent=1))
json.dump(result, open(prefix + ".score.json", "w"), indent=1)
