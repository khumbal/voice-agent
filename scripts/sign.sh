#!/bin/bash
# Signs VoiceAgent.app with a local self-signed certificate. macOS ties the app's Microphone, Speech Recognition and
# Accessibility permissions to its signature; an ad-hoc signature changes on every build, so each build lost them.
# The certificate lives in its own keychain, unlocked with a generated password, so signing never prompts.
set -e
APP=${1:-~/Applications/VoiceAgent.app}
DATA=~/.local/share/voice-agent
KEYCHAIN=$DATA/signing.keychain-db
PASSWORD_FILE=$DATA/signing-keychain-password
READY=$DATA/signing-ready # written last: a run that failed half-way is redone from scratch
NAME="VoiceAgent Local Signing"

if [ ! -f "$READY" ] || [ ! -f "$KEYCHAIN" ] || [ ! -f "$PASSWORD_FILE" ]; then
    # A new certificate is a new signature: macOS forgets the app's Microphone/Speech grants and asks again.
    echo "⚠️  Creating a new signing certificate: macOS will ask for Microphone and Speech Recognition again"
    mkdir -p "$DATA"
    rm -f "$READY"
    [ -f "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN"
    (umask 077; /usr/bin/openssl rand -hex 32 > "$PASSWORD_FILE")
    PASSWORD=$(cat "$PASSWORD_FILE")
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2> /dev/null
    # LibreSSL: its PKCS#12 encryption is the kind `security import` reads (OpenSSL 3 would need -legacy).
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
        -passout "pass:$PASSWORD"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN" # no auto-lock
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" > /dev/null
    touch "$READY"
fi

# codesign only finds an identity in a keychain on the user's search list; keep the existing entries (one per line,
# quoted, possibly with spaces).
SEARCH=()
while IFS= read -r line; do
    line=${line#*\"}; SEARCH+=("${line%\"*}")
done < <(security list-keychains -d user)
if [[ ! " ${SEARCH[*]} " == *" $KEYCHAIN "* ]]; then
    security list-keychains -d user -s "${SEARCH[@]}" "$KEYCHAIN"
fi
security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
IDENTITY=$(security find-certificate -c "$NAME" -Z "$KEYCHAIN" | awk '/SHA-1/ {print $NF}')
# Re-running after deleting the marker makes a new certificate (see above).
[ -n "$IDENTITY" ] || { echo "❌ signing certificate missing: delete $READY and re-run"; exit 1; }
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier com.local.voiceagent.cli "$APP"
