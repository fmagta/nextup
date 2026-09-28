#!/bin/bash
# Creates a self-signed code-signing identity in the login keychain.
#
# Why: macOS ties privacy grants (Full Disk Access, Calendar, Notifications) to an app's
# signature. Ad-hoc signatures change on every build, so each rebuild would lose the grants.
# A stable self-signed certificate keeps them. It is only trusted by this Mac.
#
# Remove later with: security delete-identity -c "NextUp Local Signing"
set -euo pipefail

NAME="NextUp Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Signing identity '$NAME' already exists."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=$(openssl rand -hex 16)

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# SHA1/3DES PKCS#12 is the format `security import` reads on every macOS version.
openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -out "$tmp/identity.p12" -passout "pass:$pass" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
       -out "$tmp/identity.p12" -passout "pass:$pass"

# -T pre-authorizes codesign to use the private key without a keychain prompt.
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created signing identity '$NAME'."
