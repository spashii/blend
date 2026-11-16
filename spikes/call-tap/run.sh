#!/bin/zsh
# A call app's sound through BlendKit for a long run on a loaded Mac: Blend Lab Speaker
# plays speech and 10 s pauses, muted, while `lab callwatch` records it the way Dictate
# does and `yes` keeps every core busy. score.py then counts the capture's rebuilds and any
# Call silence that is not in the source.
#
# Usage: run.sh BUILD_DIR OUT_PREFIX SECONDS [LOAD] [OPTION...]
# LOAD is the number of `yes` processes, all at nice 19; the default is one per core.
# kill=N@T destroys the capture's tap T seconds in, and each tap it rebuilds after that,
# N taps in all, as on the call where a rebuild came up dead. `system` records everything the
# Mac plays as Call instead of the speaker alone, and `echo` turns echo cancellation on.
set -eu
build=${1:A}
out=${2:A}
seconds=$3
load=${4:-$(sysctl -n hw.ncpu)}
extra=(${@:5})
here=${0:A:h}
lab="$build/spikes/lab/BlendLab.app"
speaker="$build/spikes/lab/BlendLabSpeaker.app"
mkdir -p "${out:h}"

# The owner's calls come first: wait while Dictate is writing one.
calls="$HOME/Library/Application Support/Dictate/calls"
while [ -n "$(find "$calls" -type f -newermt '-30 seconds' 2>/dev/null | head -1)" ]; do
  echo "a call is recording, waiting" >&2
  sleep 30
done

speech="${out:h}/speech.aiff"
if [ ! -f "$speech" ]; then
  say -o "$speech" --data-format=BEF32@48000 -f "$here/speech.txt"
fi

# The test Mac's shared bench lock, when it has one: a loaded run spoils anyone's timing.
[ -f "$HOME/work/fairlock.sh" ] && source "$HOME/work/fairlock.sh"

pids=()
cleanup() {
  for p in $pids; do kill $p 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM
for i in $(seq 1 $load); do
  nice -n 19 yes > /dev/null &
  pids+=$!
done
(while :; do echo "$(date +%s) $(sysctl -n vm.loadavg)"; sleep 30; done) > "$out.load" &
pids+=$!

rm -f "$out.muted"
# The speaker waits for the mute before it plays anything.
open -g -n "$speaker" --args "$speech" "$out" 15 10 $((seconds - 20)) "$out.muted"
for i in $(seq 1 50); do
  spid=$(pgrep -n -f "BlendLabSpeaker.app/Contents/MacOS/BlendLabSpeaker $speech $out " || true)
  [ -n "$spid" ] && break
  sleep 0.1
done
echo "speaker pid $spid"
pids+=$spid

open -W -n --env LAB_TIMEOUT=$((seconds + 120)) --stdout "$out.stdout" --stderr "$out.stdout" \
  "$lab" --args callwatch app.blend.lab.speaker $seconds "$out" $extra
cat "$out.stdout"
# The speaker quits once its schedule is played and its files are written.
for i in $(seq 1 100); do
  kill -0 $spid 2>/dev/null || break
  sleep 0.2
done
/usr/bin/python3 "$here/score.py" "$out"
