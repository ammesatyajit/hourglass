#!/usr/bin/env bash
# Create a stable self-signed code-signing identity for Debug builds so
# macOS TCC (Full Disk Access, Accessibility, etc.) grants survive
# rebuilds.
#
# Why this exists
# ---------------
# Ad-hoc signing (`codesign --sign -`) produces a fresh code identity on
# every rebuild because the identity is just the CDHash of the binary,
# and the binary changes when ANY source changes. TCC keys grants on
# code identity for ad-hoc-signed apps, so every rebuild looks like a
# different app and the user has to remove + re-add to Full Disk Access.
#
# Signing with a real certificate (even a self-signed one) flips TCC to
# key on the certificate's Common Name + bundle id instead. That stays
# stable across rebuilds. One-time setup; grants survive forever (or
# until you revoke).
#
# Idempotent. Safe to re-run.
#
# After this:
#   1. ./scripts/build.sh signs Debug builds with the new identity
#   2. Open the app, grant FDA once
#   3. Future rebuilds re-use the same identity → grant persists
#
# To start fresh, run:
#   security delete-certificate -c "Hourglass Dev"
#   tccutil reset SystemPolicyAllFiles com.satyajit.hourglass

set -euo pipefail

CERT_NAME="Hourglass Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# 1. Already exists? Bail out cheerfully.
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Identity '$CERT_NAME' already in your login keychain."
    echo "  (Re-run with --force to recreate.)"
    if [[ "${1:-}" != "--force" ]]; then
        exit 0
    fi
    echo "  --force: removing existing entry…"
    security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true
fi

# 2. Build the cert + key with `security`'s X.509 generator. The trick:
#    `security create-keypair` lays down a private key in the keychain;
#    we then create a self-signed cert wrapping that key. macOS treats
#    the combination as a code-signing identity if Extended Key Usage
#    includes `codeSigning` (1.3.6.1.5.5.7.3.3).
#
# We use the documented `openssl` + `security import` flow because
# `security` itself doesn't expose code-signing-cert creation directly.

WORKDIR="$(mktemp -d)"
trap "rm -rf '$WORKDIR'" EXIT

CONFIG="$WORKDIR/cert.conf"
KEY="$WORKDIR/key.pem"
CERT="$WORKDIR/cert.pem"
PFX="$WORKDIR/identity.p12"

cat > "$CONFIG" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_codesign

[req_dn]
CN = $CERT_NAME

[v3_codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "  → generating private key + self-signed certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CERT" \
    -days 3650 \
    -config "$CONFIG" >/dev/null 2>&1

# Empty-password PKCS#12 — we want it imported without prompting.
openssl pkcs12 -export \
    -inkey "$KEY" -in "$CERT" \
    -out "$PFX" \
    -name "$CERT_NAME" \
    -passout pass: >/dev/null 2>&1

echo "  → importing into login.keychain"
# `-T /usr/bin/codesign` whitelists codesign to use the private key
# without an interactive prompt every build.
security import "$PFX" \
    -k "$KEYCHAIN" \
    -P "" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null 2>&1

# Mark the certificate as trusted for code signing. `security
# add-trusted-cert` requires sudo for system-wide trust; we scope to
# user trust only (no sudo needed) — that's enough for codesign +
# TCC's identity matching.
security add-trusted-cert \
    -k "$KEYCHAIN" \
    -p codeSign \
    "$CERT" >/dev/null 2>&1 || true

# Re-affirm partition list so codesign can use the key non-interactively
# (otherwise the first build prompts "codesign wants to access key").
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "✓ Identity '$CERT_NAME' is set up in your login keychain."
echo ""
echo "Next:"
echo "  1. ./scripts/build.sh    # signs Debug build with the stable identity"
echo "  2. Open Hourglass → grant Full Disk Access once"
echo "  3. Future rebuilds keep the grant — no more re-adding."
