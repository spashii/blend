#!/bin/zsh
# Step 4 of source identity: a source bound to one Firefox copy must carry only that
# copy's tone, and must find the copy again after it restarts. Records two WAVs for
# spikes/identity/spectrum.py.
set -u
dir=/tmp/blend-identity
here=${0:A:h}
lab=${0:A:h:h}/lab/lab.sh
$here/scenario.sh start
cat > $dir/proof.json <<JSON
{"mixes":[{"id":"proof","name":"Proof","slot":3,"sources":[
  {"id":"a","kind":"app","bundleID":"org.mozilla.firefox","instance":"$dir/ff-A"}]},
 {"id":"control","name":"Control","slot":4,"sources":[
  {"id":"b","kind":"app","bundleID":"org.mozilla.firefox","instance":"$dir/ff-B"}]}]}
JSON
(LAB_TIMEOUT=90 $lab engine $dir/proof.json 45 > $dir/engine.txt 2>&1 &)
sleep 5
LAB_TIMEOUT=40 $lab record app.blend.mix.proof 5 $dir/before.wav
# Control: copy B must be audible through its own source, or the test above proves nothing.
LAB_TIMEOUT=40 $lab record app.blend.mix.control 5 $dir/control.wav
# Restart copy A with the same launch arguments; its process and audio object change.
for p in $(pgrep -f "firefox --new-instance --profile $dir/ff-[A]"); do
  [[ $(ps -o ppid= -p $p | tr -d ' ') == 1 ]] && kill $p && echo "stopped copy A ($p)"
done
sleep 4
open -na Firefox --args --new-instance --profile $dir/ff-A file://$dir/440.html
sleep 8
echo "copy A now: $(pgrep -f "firefox --new-instance --profile $dir/ff-[A]" | head -1)"
LAB_TIMEOUT=40 $lab record app.blend.mix.proof 5 $dir/after.wav
sleep 2
$here/scenario.sh stop
