#!/bin/zsh
# Sets up Developer ID signing and notarization for tools/release.sh, once per Mac.
#
#   tools/release-identity.sh KEY.pem CERTIFICATE.cer
#       KEY.pem is the private key the certificate request was made from, and
#       CERTIFICATE.cer the "Developer ID Application" certificate Apple issued for it.
#   tools/release-identity.sh --notary
#       Asks for your Apple ID, an app-specific password (account.apple.com) and your team
#       ID, and saves them as the notarytool profile "blend-notary". Run it in Terminal.
#
# The login keychain is locked to SSH sessions and to scripts that cannot show a prompt, so
# both go in their own keychain, blend-release, unlocked by a random password kept in
# ~/.blend-signing (readable by you only). Anyone with your user account can sign as you,
# as with any signing key on disk.
# Undo: security delete-keychain ~/Library/Keychains/blend-release.keychain-db
#       rm -rf ~/.blend-signing
set -euo pipefail
kc=$HOME/Library/Keychains/blend-release.keychain-db
dir=$HOME/.blend-signing
password=$dir/keychain-password

if [[ ${1:-} == --notary ]]; then
  security unlock-keychain -p "$(<$password)" $kc
  xcrun notarytool store-credentials blend-notary --keychain $kc
  exit 0
fi
if (( $# != 2 )); then
  print -u2 "usage: ${0:t} KEY.pem CERTIFICATE.cer | --notary"
  exit 64
fi
key=${1:A}
cert=${2:A}
if [[ -f $kc ]]; then
  print -u2 "Already set up: $kc"
  security find-identity -v -p codesigning $kc
  exit 1
fi

umask 077
mkdir -p $dir
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
/usr/bin/openssl rand -hex 24 >$password
pass=$(<$password)
/usr/bin/openssl x509 -inform der -in $cert -out $tmp/cert.pem
name=$(/usr/bin/openssl x509 -in $tmp/cert.pem -noout -subject -nameopt multiline |
  sed -n 's/^ *commonName *= *//p')
/usr/bin/openssl pkcs12 -export -out $tmp/identity.p12 -inkey $key -in $tmp/cert.pem \
  -passout file:$password -name "$name"
# Apple's intermediate, so codesign builds the chain without the login keychain.
curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o $tmp/g2.cer

security create-keychain -p "$pass" $kc
security set-keychain-settings $kc
security unlock-keychain -p "$pass" $kc
security import $tmp/identity.p12 -k $kc -P "$pass" -T /usr/bin/codesign >/dev/null
security import $tmp/g2.cer -k $kc >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" $kc >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') $kc
security find-identity -v -p codesigning $kc
