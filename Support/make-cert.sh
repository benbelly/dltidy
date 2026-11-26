#!/bin/bash
# Creates (once) a self-signed code-signing identity in a dedicated keychain and unlocks it.
# The keychain password is generated and kept in a 0600 file, and the key's partition list
# allows codesign, so signing never shows a prompt and works from a headless shell.
# A stable identity keeps the TCC (Downloads) grant and Keychain ACL across rebuilds.
# Prints the keychain path on stdout. Idempotent.
set -euo pipefail

NAME="${DLTIDY_CERT_NAME:-dltidy Local Signing}"
DIR="$HOME/Library/Application Support/dltidy-signing"
KC="$DIR/signing.keychain-db"
PWFILE="$DIR/keychain-password"

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$KC" ]]; then
  uuidgen >"$PWFILE"
  chmod 600 "$PWFILE"
  security create-keychain -p "$(cat "$PWFILE")" "$KC" >&2
  security set-keychain-settings "$KC" >&2   # no auto-lock timeout
fi
PW="$(cat "$PWFILE")"
security unlock-keychain -p "$PW" "$KC" >&2

# codesign finds identities only in the user search list; append ours, keep the rest.
if ! security list-keychains -d user | grep -qF "$KC"; then
  CURRENT=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -n "$line" ]] && CURRENT+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${CURRENT[@]}" "$KC"
fi

if ! security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat >"$TMP/cfg" <<EOF
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
subjectKeyIdentifier = hash
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
  P12PASS="$(uuidgen)"
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PASS"
  security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >&2
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
  echo "make-cert: created identity '$NAME' in $KC" >&2
fi

echo "$KC"
