#!/bin/zsh
# Records the "Mic and system audio" preset, split by channel, through the real engine and
# driver, with a 1 kHz tone playing as system audio, and scores how far each side leaks
# into the other (spikes/split/score.py). Nothing is audible: the output volume is 0 for the
# run and restored after. Run it only while nobody is using the Mac or any Blend mix: it
# adds a test mix to the driver and puts the driver's list back afterwards.
# Usage: spikes/split/check.sh   Output: build/split/{split.wav,engine.txt,record.txt}
set -u
root=${0:A:h:h:h}
out=$root/build/split
lab=$root/spikes/lab/lab.sh
rm -rf $out
mkdir -p $out

idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9); exit}')
busy=$(swift $root/spikes/split/busy.swift 2>/dev/null)
if (( idle < 600 )) || [[ -n $busy ]]; then
  print -u2 "Not now: idle ${idle}s, mixes in use: ${busy:-none}"
  exit 75
fi

before=$(LAB_TIMEOUT=20 $lab mixes | tail -1)
volume=$(osascript -e 'output volume of (get volume settings)')
muted=$(osascript -e 'output muted of (get volume settings)')
restore() {
  osascript -e "set volume output volume $volume"
  [[ $muted == true ]] && osascript -e 'set volume with output muted'
  LAB_TIMEOUT=20 $lab mixes-set "$before" > /dev/null
}
trap restore EXIT INT TERM
osascript -e 'set volume output volume 0'

# The person's own mixes stay in the list with no sources, so their devices don't vanish.
python3 - "$before" > $out/config.json <<'PY'
import json, sys
mixes = [dict(m, sources=[]) for m in json.loads(sys.argv[1])]
used = {m["slot"] for m in mixes}
slot = next(s for s in range(16) if s not in used)
mixes.append({"id": "split001", "name": "Split Test", "slot": slot, "split": True, "sources": [
    {"id": "m", "kind": "device", "uid": "BuiltInMicrophoneDevice",
     "processing": {"echoCancel": True, "isolation": "off"}},
    {"id": "s", "kind": "system"}]})
print(json.dumps({"mixes": mixes}))
PY
python3 -c "
import math, struct, wave
w = wave.open('$out/tone.wav', 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b''.join(struct.pack('<hh', *(2 * [int(0.25 * 32767 * math.sin(2 * math.pi * 1000 * i / 48000))])) for i in range(48000 * 16)))
"
LAB_TIMEOUT=120 $lab engine $out/config.json 40 > $out/engine.txt 2>&1 &
sleep 5
LAB_TIMEOUT=120 $lab record app.blend.mix.split001 28 $out/split.wav > $out/record.txt 2>&1 &
sleep 6
afplay $out/tone.wav
wait
tail -1 $out/record.txt
grep -E '^(mix|source) ' $out/engine.txt | tail -3
