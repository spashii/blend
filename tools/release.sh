#!/bin/zsh
# Builds the release disk image: tools/release.sh
#
# Output: build/release/Blend-VERSION.dmg with Blend.app, which carries the driver.
# With tools/release-identity.sh set up, it signs with that Developer ID, then notarizes and
# staples both the app and the image, so Blend opens on any Mac without a Gatekeeper
# warning, offline too. BLEND_SIGN_ID and BLEND_NOTARY_PROFILE use an identity and a
# notarytool profile from your login keychain instead. Signed ad hoc otherwise.
set -euo pipefail
root=${0:A:h:h}
cd $root
version=$(<VERSION)
identity=${BLEND_SIGN_ID:--}
profile=${BLEND_NOTARY_PROFILE:-}
keychain=
keychainArgs=()
kc=$HOME/Library/Keychains/blend-release.keychain-db
if [[ -z ${BLEND_SIGN_ID:-} && -f $kc ]]; then
  security unlock-keychain -p "$(<$HOME/.blend-signing/keychain-password)" $kc
  identity=$(security find-identity -v -p codesigning $kc |
    sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | head -1)
  keychain=$kc
  keychainArgs=(--keychain $kc)
  profile=${profile:-blend-notary}
fi
out=$root/build/release
cmakeDir=$out/cmake
flags=
signFlags=()
if [[ $identity != - ]]; then
  flags="--options runtime --timestamp"
  signFlags=(--timestamp $keychainArgs)
fi
# notarytool exits 0 even when Apple rejects the file, so the status is checked here and a
# rejection prints Apple's reasons.
notarize() {
  local result id
  result=$(xcrun notarytool submit $1 --keychain-profile $profile $keychainArgs --wait \
    --output-format json)
  id=$(print -r -- $result | plutil -extract id raw -o - -)
  if [[ $(print -r -- $result | plutil -extract status raw -o - -) != Accepted ]]; then
    xcrun notarytool log $id --keychain-profile $profile $keychainArgs >&2
    return 1
  fi
  echo "notarized: ${1:t} ($id)"
}

rm -rf $out
mkdir -p $out
cmake -S . -B $cmakeDir -G Ninja -DCMAKE_BUILD_TYPE=Release -DBLEND_BUILD_SPIKES=OFF \
  -DBLEND_CODESIGN_ID="$identity" -DBLEND_CODESIGN_FLAGS="$flags" \
  -DBLEND_KEYCHAIN="$keychain" >/dev/null
cmake --build $cmakeDir
ctest --test-dir $cmakeDir --output-on-failure

(cd app && xcodegen generate --quiet)
xcodebuild -project app/Blend.xcodeproj -scheme Blend -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath $out/xcode -quiet \
  BLEND_BUILD_DIR=$cmakeDir MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$version \
  CODE_SIGN_IDENTITY="$identity" ${signFlags:+OTHER_CODE_SIGN_FLAGS="$signFlags"} build
app=$out/xcode/Build/Products/Release/Blend.app
codesign --verify --deep --strict $app
codesign --verify --strict $app/Contents/PlugIns/BlendDriver.driver

stage=$out/stage
mkdir -p $stage
ditto $app $stage/Blend.app
# The app gets its own ticket, so it opens without a network check once copied out of
# the image.
if [[ -n $profile ]]; then
  ditto -c -k --keepParent $stage/Blend.app $out/Blend.zip
  notarize $out/Blend.zip
  xcrun stapler staple $stage/Blend.app
  rm $out/Blend.zip
fi
ln -s /Applications $stage/Applications
dmg=$out/Blend-$version.dmg
hdiutil create -quiet -volname "Blend $version" -srcfolder $stage -fs HFS+ -format UDZO -ov $dmg
if [[ $identity != - ]]; then
  codesign --sign "$identity" $signFlags $dmg
fi
if [[ -n $profile ]]; then
  notarize $dmg
  xcrun stapler staple $dmg
  spctl --assess --type open --context context:primary-signature -v $dmg
fi
(cd $out && shasum -a 256 ${dmg:t} | tee ${dmg:t}.sha256)
echo "$dmg"
