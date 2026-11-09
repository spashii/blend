#!/bin/zsh
# Builds the release disk image: tools/release.sh [--publish]
#
# Output: build/release/Blend-VERSION.dmg with Blend.app, which carries the driver.
# --publish then uploads it as GitHub release vVERSION and pushes the update feed and the
# Homebrew cask that point at it; it needs a clean, pushed checkout and gh logged in.
# With tools/release-identity.sh set up, it signs with that Developer ID, then notarizes and
# staples both the app and the image, so Blend opens on any Mac without a Gatekeeper
# warning, offline too. BLEND_SIGN_ID and BLEND_NOTARY_PROFILE use an identity and a
# notarytool profile from your login keychain instead. Signed ad hoc otherwise.
set -euo pipefail
root=${0:A:h:h}
cd $root
version=$(<VERSION)
publish=false
if [[ ${1:-} == --publish ]]; then
  publish=true
  # The release is built from HEAD and tagged there, so HEAD has to be exactly what is on
  # GitHub; these checks fail when GitHub can't be reached, rather than passing.
  [[ -z $(git status --porcelain) ]] || { print -u2 "Commit everything first."; exit 1 }
  git fetch -q origin
  [[ $(git rev-parse HEAD) == $(git rev-parse "@{u}") ]] || { print -u2 "Push HEAD first."; exit 1 }
  gh auth status >/dev/null
  if [[ -n $(gh release list --json tagName -q ".[] | select(.tagName == \"v$version\")") ]]; then
    print -u2 "v$version is already released; raise VERSION."
    exit 1
  fi
fi
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
xcodebuild test -project app/Blend.xcodeproj -scheme BlendTests \
  -destination "platform=macOS,arch=arm64" -derivedDataPath $out/tests -quiet
xcodebuild -project app/Blend.xcodeproj -scheme Blend -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath $out/xcode -quiet \
  BLEND_BUILD_DIR=$cmakeDir MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$version \
  CODE_SIGN_IDENTITY="$identity" ${signFlags:+OTHER_CODE_SIGN_FLAGS="$signFlags"} build
app=$out/xcode/Build/Products/Release/Blend.app
# Xcode signs the Sparkle framework it embeds but not the helpers inside it, and
# notarization needs every one signed with the Developer ID. This is the order Sparkle's
# documentation gives for an app that isn't sandboxed; the app is signed again last, since
# its signature covers the framework's.
sparkleFramework=$app/Contents/Frameworks/Sparkle.framework
if [[ $identity != - && -d $sparkleFramework ]]; then
  helpers=$sparkleFramework/Versions/B
  for code in $helpers/XPCServices/Installer.xpc $helpers/XPCServices/Downloader.xpc \
    $helpers/Autoupdate $helpers/Updater.app $sparkleFramework $app; do
    codesign --force --sign "$identity" --options runtime --preserve-metadata=entitlements \
      $signFlags $code
  done
fi
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

# A notarized image becomes the newest entry in the update feed and the Homebrew cask. Both
# are files in the repo, published by committing them with the GitHub release.
sparkle=${BLEND_SPARKLE_DIR:-$HOME/.blend-signing/sparkle-2.10.1}
sparkleKey=${BLEND_SPARKLE_KEY:-$HOME/.blend-signing/sparkle-private-key}
releases=${BLEND_RELEASES_URL:-https://github.com/spashii/blend/releases/download}
if [[ -n $profile && -f $sparkleKey ]]; then
  signature=$($sparkle/bin/sign_update --ed-key-file $sparkleKey $dmg)
  item="    <item>
      <title>Blend $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$releases/v$version/${dmg:t}\" $signature type=\"application/octet-stream\"/>
    </item>"
  ITEM=$item VERSION=$version perl -0pi -e '
    s{\s*<item>(?:(?!</item>).)*<sparkle:version>\Q$ENV{VERSION}\E</sparkle:version>.*?</item>}{}s;
    s{(<!-- tools/release.sh adds each release below this line. -->)}{$1\n$ENV{ITEM}}' site/appcast.xml
  sha=$(cut -d' ' -f1 $dmg.sha256)
  sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    Casks/blend.rb
fi
if $publish; then
  [[ -n $profile && -f $sparkleKey ]] || {
    print -u2 "Not published: a release needs the Developer ID, notarization and the update key."
    exit 1
  }
  # The image goes up before the feed that offers it.
  gh release create v$version $dmg $dmg.sha256 --target $(git rev-parse HEAD) \
    --title "Blend $version" --generate-notes
  git commit -q -m "Blend $version" site/appcast.xml Casks/blend.rb
  git push -q
  echo "Published v$version."
elif [[ -n $profile && -f $sparkleKey ]]; then
  echo "Updated site/appcast.xml and Casks/blend.rb; tools/release.sh --publish uploads and pushes."
fi
echo "$dmg"
