# Restarts the Mac's audio service, coreaudiod, so it loads new audio plug-ins, and makes
# sure it settles. Runs as root, inlined into Setup's install and uninstall scripts and
# into the development helper (tools/dev-setup.sh), so all of them restart the same way.
#
# The AirPlay helper restarts with it. A helper that outlives coreaudiod registers its
# devices with each new coreaudiod twice as often as with the one before, and after a
# handful of restarts coreaudiod spends all its time on that and stops answering apps.

blend_restart_audio() {
  old=$(pgrep -x coreaudiod) || old=
  if [ -n "$old" ]; then
    kill $old 2>/dev/null || true
    # A stuck coreaudiod ignores SIGTERM.
    i=0
    while [ $i -lt 6 ] && kill -0 $old 2>/dev/null; do
      sleep 0.5
      i=$((i + 1))
    done
    kill -9 $old 2>/dev/null || true
  fi
  killall AirPlayXPCHelper 2>/dev/null || true
}

# Loading plug-ins takes a moment of CPU; one still busy two seconds in a row is stuck.
# The first of top's samples has no CPU figure yet, so three samples give two readings.
blend_audio_settled() {
  pid=$(pgrep -x coreaudiod) || return 0
  busy=$(top -l 3 -s 1 -pid $pid -stats cpu | tail -2 | awk '$1 >= 25 { n++ } END { print n + 0 }')
  [ "$busy" -eq 0 ]
}

blend_restart_audio
for attempt in 1 2 3; do
  [ $attempt -eq 1 ] || blend_restart_audio
  sleep 2
  for check in 1 2 3 4 5; do
    blend_audio_settled && exit 0
  done
done
echo "The Mac's audio service didn't restart cleanly. Restart the Mac to finish." >&2
exit 1
