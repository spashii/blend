#!/bin/zsh
# Records S4 fixtures: plays far-end speech and music through the speakers at three
# volumes while Blend Lab records the raw mic and the speaker reference.
# Output must be the built-in speakers. Usage: session.sh NAME SECONDS
name=${1:-farend}
seconds=${2:-75}
root=${0:A:h:h:h}
out=$root/build/echo
fx=$root/build/fixtures
mkdir -p $out
( LAB_TIMEOUT=$((seconds + 120)) $root/spikes/lab/lab.sh record-echo $seconds $out/$name.wav > $out/$name.txt 2>&1 & )
sleep 2
for v in 0.25 0.5 1.0; do
  afplay -v $v $fx/speech/babble_1.wav
  afplay -v $v $fx/music.wav
  sleep 1
done
while pgrep -f "BlendLab record-echo" >/dev/null; do sleep 1; done
cat $out/$name.txt
