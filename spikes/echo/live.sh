#!/bin/zsh
# Live echo check through the real engine and driver: two mixes of the built-in microphone,
# one with echo cancellation and one without, both recorded while speech and music play
# through the speakers. Needs the screen unlocked (macOS blocks audio IO while it is
# locked), the speakers as output, and Blend itself quit, since this sets its own mixes.
# Usage: spikes/echo/live.sh   Output: build/live/{aec,raw}.wav and engine.txt
set -u
root=${0:A:h:h:h}
out=$root/build/live
fx=$root/build/fixtures
lab=$root/spikes/lab/lab.sh
rm -rf $out
mkdir -p $out
cat > $out/config.json <<J
{"mixes":[{"id":"aec00001","name":"AEC Test","slot":1,"sources":[{"id":"m","kind":"device","uid":"BuiltInMicrophoneDevice","processing":{"echoCancel":true,"isolation":"off"}}]},
 {"id":"raw00001","name":"Raw Test","slot":2,"sources":[{"id":"m","kind":"device","uid":"BuiltInMicrophoneDevice"}]}]}
J
LAB_TIMEOUT=200 $lab engine $out/config.json 70 > $out/engine.txt 2>&1 &
sleep 5
LAB_TIMEOUT=200 $lab record app.blend.mix.aec00001 50 $out/aec.wav > $out/rec-aec.txt 2>&1 &
LAB_TIMEOUT=200 $lab record app.blend.mix.raw00001 50 $out/raw.wav > $out/rec-raw.txt 2>&1 &
sleep 6
for f in $fx/speech/clean_1.wav $fx/speech/clean_2.wav $fx/music.wav $fx/speech/clean_3.wav; do
  afplay -v 1 $f || echo "afplay failed on $f" >> $out/play.txt
done
wait
tail -1 $out/rec-aec.txt $out/rec-raw.txt
grep -E "^(mix|source) " $out/engine.txt | tail -4
