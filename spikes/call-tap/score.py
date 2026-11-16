#!/usr/bin/env python3
"""Scores a run.sh run: the capture's rebuilds, and Call silence that is not in the source.

The speaker logs the peak of every 10 ms block it played, and the capture the peak of every
10 ms block of Call. A block is missing when the source played a non-zero sample there and
Call is exact zeros within two blocks either side. Positions follow the clock in both, so one
offset aligns them; it is estimated from host times, then refined on the first minute.
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


def agreement(offset, n=6000):
    good = 0
    for j in range(min(n, len(source))):
        k = j + offset
        if 0 <= k < len(call):
            good += (source[j] != 0) == (call[k] != 0)
    return good


offset = max(range(guess - 50, guess + 51), key=agreement)
spoken = missing = 0
runs = []
run_start = None
for j in range(len(source)):
    k = j + offset
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
diags = re.findall(r"diag (.*)", log)
last = diags[-1] if diags else ""
restarts = int(re.search(r"restarts=(\d+)", last).group(1)) if "restarts=" in last else -1
dead = re.search(r"dead-tap-rebuilds=(\d+)", last)
events = re.findall(r"event (\w+)", log)
loads = [float(l.split()[2]) for l in open(prefix + ".load") if len(l.split()) > 2]
result = {
    "seconds_captured": round(len(call) / 100, 1),
    "offset_blocks": offset,
    "offset_guess": guess,
    "source_speech_s": round(spoken / 100, 1),
    "call_missing_s": round(missing / 100, 2),
    "missing_runs_over_0.2s": [
        (round(a / 100, 1), round((b - a) / 100, 2)) for a, b in runs if b - a > 20
    ],
    "rebuilds": restarts,
    "dead_tap_rebuilds": int(dead.group(1)) if dead else 0,
    "events": {e: events.count(e) for e in sorted(set(events))},
    "load_1min": [min(loads), max(loads)] if loads else [],
}
print(json.dumps(result, indent=1))
json.dump(result, open(prefix + ".score.json", "w"), indent=1)
