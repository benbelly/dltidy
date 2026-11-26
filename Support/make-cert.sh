#!/bin/bash
# Creates (once) a self-signed code-signing identity in a dedicated keychain and unlocks it.
# The keychain password is the user's choice and is never stored: `make install` asks for it,
# and the keychain locks again after 5 minutes or on sleep. Other processes running as the user
# cannot sign as dltidy (and inherit its Downloads grant) without that password.
# A stable identity keeps the TCC (Downloads) grant and Keychain ACL across rebuilds.
# Prints the keychain path on stdout; prompts go to the terminal. Idempotent.
set -euo pipefail

NAME="${DLTIDY_CERT_NAME:-dltidy Local Signing}"
DIR="$HOME/Library/Application Support/dltidy-signing"
KC="$DIR/signing.keychain-db"
OLD_PWFILE="$DIR/keychain-password"   # written by earlier versions; migrated and removed below

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$KC" ]]; then
  echo "make-cert: choose a password for the dltidy signing keychain (asked at each install)" >&2
  security create-keychain "$KC" >&2
fi

if [[ -f "$OLD_PWFILE" ]]; then
  echo "make-cert: set a new password for the dltidy signing keychain; the stored one is being removed" >&2
  security set-keychain-password -o "$(cat "$OLD_PWFILE")" "$KC" >&2
  rm -P "$OLD_PWFILE" 2>/dev/null || rm -f "$OLD_PWFILE"
fi

security set-keychain-settings -l -u -t 300 "$KC" >&2   # lock on sleep and after 5 min
echo "make-cert: unlock the dltidy signing keychain" >&2
security unlock-keychain "$KC" >&2

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
  echo "make-cert: allow codesign to use the key (keychain password again)" >&2
  security set-key-partition-list -S apple-tool:,apple: -s "$KC" >/dev/null
  echo "make-cert: created identity '$NAME' in $KC" >&2
fi

echo "$KC"
