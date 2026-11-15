#!/bin/zsh
# Builds MicSim.app next to this script's build folder: spikes/micsim/build.sh
#
# Signed with the "Blend Dev" identity when it exists, so macOS keeps the microphone grant
# across rebuilds; ad hoc otherwise, which asks again after every build.
set -euo pipefail
here=${0:A:h}
out=${1:-$here/../../build/micsim}
app=$out/MicSim.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp $here/Info.plist $app/Contents/Info.plist
swiftc -O -o $app/Contents/MacOS/MicSim $here/main.swift \
  -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Accelerate
kc=~/Library/Keychains/blend-dev.keychain-db
if [[ -f $kc ]]; then
  security unlock-keychain -p blend-dev $kc
  codesign --force --sign "Blend Dev" --keychain $kc $app
else
  codesign --force --sign - $app
fi
# A second app, not tapped when the first is: what a person's own sound looks like to a call capture.
near=$out/MicSimNear.app
rm -rf $near
cp -R $app $near
sed -i '' 's/app.blend.micsim/app.blend.micsimnear/' $near/Contents/Info.plist
if [[ -f $kc ]]; then
  codesign --force --sign "Blend Dev" --keychain $kc $near
else
  codesign --force --sign - $near
fi
# A third, a regular app that only plays: the far end of a call, which the call capture taps.
# BlendKit taps only regular apps, so this one is not an agent; it never takes the microphone.
far=$out/MicSimFar.app
rm -rf $far
cp -R $app $far
sed -i '' 's/app.blend.micsim</app.blend.micsimfar</' $far/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Delete :LSUIElement' $far/Contents/Info.plist
if [[ -f $kc ]]; then
  codesign --force --sign "Blend Dev" --keychain $kc $far
else
  codesign --force --sign - $far
fi
echo $app
