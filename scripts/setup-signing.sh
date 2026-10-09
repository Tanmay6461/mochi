#!/bin/bash
# One-time: creates a self-signed code-signing certificate "NotchPet Local Signing" in your login
# keychain, so scripts/bundle.sh signs every build with the same identity and macOS keeps
# Accessibility permission across rebuilds. Safe to re-run: does nothing if it already exists.
# macOS will ask for your login password once, to trust the certificate for code signing.
set -euo pipefail

NAME="NotchPet Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 10-year self-signed certificate + key
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.conf" 2>/dev/null

# Bundle and import into the login keychain; let codesign use the key without prompting
legacy=""
case "$(openssl version)" in OpenSSL\ 3*) legacy="-legacy" ;; esac # macOS's importer can't read OpenSSL 3's default format
openssl pkcs12 -export $legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$NAME" -out "$work/identity.p12" -passout pass:notchpet 2>/dev/null
security import "$work/identity.p12" -k "$KEYCHAIN" -P notchpet -T /usr/bin/codesign >/dev/null

# Trust it for code signing (this is the step that asks for your password)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Created \"$NAME\". Now run: scripts/bundle.sh --open"
else
    echo "The certificate was imported but isn't usable for code signing yet." >&2
    echo "Open Keychain Access, find \"$NAME\", and under Trust set Code Signing to Always Trust." >&2
    exit 1
fi
