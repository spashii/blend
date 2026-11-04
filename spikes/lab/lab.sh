#!/bin/zsh
# Runs Blend Lab through LaunchServices, so macOS attributes microphone and system audio
# permission to the app instead of the ssh session, and prints its output.
app="${0:A:h:h:h}/build/spikes/lab/BlendLab.app"
log=$(mktemp -t blendlab)
open -W -n --stdout "$log" --stderr "$log" "$app" --args "$@"
cat "$log"
rm -f "$log"
