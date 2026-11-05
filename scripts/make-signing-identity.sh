#!/bin/bash
# One-time: create a self-signed code signing identity, "Pocket3Bar Local Signing", in your
# login keychain. Signing every build with it keeps the app's identity stable, so macOS
# remembers its camera permission. It's local only: it doesn't make the app trusted elsewhere.
set -euo pipefail
IDENT="Pocket3Bar Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENT\""; then
  echo "'$IDENT' already exists"; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# /usr/bin/openssl (LibreSSL) writes a .p12 the macOS keychain can import
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
PW=$(/usr/bin/openssl rand -hex 12)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENT" \
  -out "$TMP/id.p12" -passout "pass:$PW"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -T /usr/bin/codesign
echo "created '$IDENT' (it shows as not trusted; that's expected for a self-signed identity)"
