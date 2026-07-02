#!/bin/zsh
set -euo pipefail

IDENTITY_NAME="${IDENTITY_NAME:-Surge Relay Self-Signed Code Signing}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
EXPORT_P12_PATH="${EXPORT_P12_PATH:-}"
P12_PASSWORD="${P12_PASSWORD:-$(uuidgen)}"

fail() {
  echo "error: $*" >&2
  exit 1
}

identity_is_valid() {
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""
}

identity_exists() {
  security find-identity -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""
}

trust_identity_certificate() {
  local certificate_path="$1"

  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$certificate_path" >/dev/null
}

if identity_is_valid; then
  echo "Code signing identity already exists: $IDENTITY_NAME"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPENSSL_CONFIG="$TMP_DIR/codesign-openssl.cnf"
PRIVATE_KEY="$TMP_DIR/codesign.key"
CERTIFICATE="$TMP_DIR/codesign.cer"
P12_PATH="$TMP_DIR/codesign.p12"

if identity_exists; then
  security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN_PATH" > "$CERTIFICATE"
  trust_identity_certificate "$CERTIFICATE"
  identity_is_valid \
    || fail "identity exists but could not be marked as a valid trusted code signing identity"
  echo "Trusted existing code signing identity: $IDENTITY_NAME"
  exit 0
fi

cat > "$OPENSSL_CONFIG" <<EOF
[ req ]
default_bits = 4096
distinguished_name = dn
prompt = no
x509_extensions = codesign_ext

[ dn ]
CN = $IDENTITY_NAME

[ codesign_ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

openssl req \
  -newkey rsa:4096 \
  -nodes \
  -keyout "$PRIVATE_KEY" \
  -x509 \
  -days 3650 \
  -out "$CERTIFICATE" \
  -config "$OPENSSL_CONFIG" \
  -extensions codesign_ext >/dev/null 2>&1

if ! openssl pkcs12 \
  -export \
  -legacy \
  -macalg sha1 \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE" \
  -name "$IDENTITY_NAME" \
  -out "$P12_PATH" \
  -passout "pass:$P12_PASSWORD" >/dev/null 2>&1; then
  openssl pkcs12 \
    -export \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$PRIVATE_KEY" \
    -in "$CERTIFICATE" \
    -name "$IDENTITY_NAME" \
    -out "$P12_PATH" \
    -passout "pass:$P12_PASSWORD" >/dev/null 2>&1
fi

security import "$P12_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

trust_identity_certificate "$CERTIFICATE"

if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null
fi

if [[ -n "$EXPORT_P12_PATH" ]]; then
  cp "$P12_PATH" "$EXPORT_P12_PATH"
  echo "Exported encrypted p12 to: $EXPORT_P12_PATH"
fi

security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "\"$IDENTITY_NAME\"" \
  || fail "identity was imported but is not visible as a valid code signing identity"

echo "Created code signing identity: $IDENTITY_NAME"
echo "Use CODESIGN_IDENTITY=\"$IDENTITY_NAME\" for release builds."
if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
  echo "If codesign asks for key access, allow it once in the macOS prompt."
fi
