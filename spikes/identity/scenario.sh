#!/bin/zsh
# Spike for source identity: starts several copies of the same apps, each playing a known
# tone, takes an inventory, and stops them again. Only throwaway profiles under /tmp are
# used. Output is muted while it runs; taps capture apps before the output device.
# usage: scenario.sh start|inventory OUT.json|stop
set -u
dir=/tmp/blend-identity
lab=${0:A:h:h:h}/build/spikes/lab/BlendLab.app/Contents/MacOS/BlendLab

tone() { # tone FREQ: writes $dir/FREQ.wav and $dir/FREQ.html
  /opt/homebrew/bin/python3 -I - "$dir" "$1" <<'PY'
import math, struct, sys, wave
d, f = sys.argv[1], int(sys.argv[2])
w = wave.open(f"{d}/{f}.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
# 30 s, so no loop restart (which jumps phase) falls inside a recording.
n = 48000 * 30
w.writeframes(b"".join(struct.pack("<hh", *(2 * [int(6000 * math.sin(2 * math.pi * f * i / 48000))])) for i in range(n)))
w.close()
open(f"{d}/{f}.html", "w").write(f'<title>tone {f}</title><audio src="{f}.wav" autoplay loop></audio>')
PY
}

firefox_profile() { # firefox_profile NAME
  mkdir -p $dir/ff-$1
  cat > $dir/ff-$1/user.js <<'JS'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
JS
}

case ${1:-} in
start)
  mkdir -p $dir
  osascript -e "output muted of (get volume settings)" > $dir/was-muted
  osascript -e "set volume with output muted"
  for f in 440 660 550 330; do tone $f; done
  firefox_profile A; firefox_profile B
  open -na Firefox --args --new-instance --profile $dir/ff-A file://$dir/440.html
  sleep 3
  open -na Firefox --args --new-instance --profile $dir/ff-B file://$dir/660.html
  open -na "Brave Browser" --args --user-data-dir=$dir/brave-X --no-first-run \
    --autoplay-policy=no-user-gesture-required file://$dir/550.html
  sleep 3
  # A second profile inside the same Brave copy: Chromium hands it to the running process.
  open -na "Brave Browser" --args --user-data-dir=$dir/brave-X --profile-directory="Profile 2" \
    --no-first-run --autoplay-policy=no-user-gesture-required file://$dir/330.html
  open -na "Brave Browser" --args --user-data-dir=$dir/brave-Y --no-first-run \
    --autoplay-policy=no-user-gesture-required file://$dir/330.html
  before=$(pgrep -x TextEdit | sort)
  open -na TextEdit; open -na TextEdit
  sleep 6
  comm -13 <(echo "$before") <(pgrep -x TextEdit | sort) > $dir/started-textedit
  ;;
inventory)
  $lab inventory > ${2:-$dir/inventory.json}
  ;;
stop)
  for p in $(pgrep -f "blend-identit[y]/(ff-|brave-)"); do kill $p 2>/dev/null; done
  for p in $(cat $dir/started-textedit 2>/dev/null); do
    kill $p 2>/dev/null
  done
  sleep 2
  [[ $(cat $dir/was-muted 2>/dev/null) == false ]] && osascript -e "set volume without output muted"
  ;;
*) echo "usage: scenario.sh start|inventory OUT.json|stop" >&2; exit 2 ;;
esac
