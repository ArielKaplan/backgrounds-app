#!/bin/bash
# One-time setup: creates the key that signs Backgrounds updates.
#   bash app/release/make-signing-key.sh
# Then:
#   1. Add the PRIVATE key as a GitHub secret named UPDATE_SIGNING_KEY
#      (repo Settings > Secrets and variables > Actions > New repository secret; paste the whole file,
#      including the BEGIN/END lines).
#   2. Put the PUBLIC key line it prints into app/update-public-key.txt and commit it.
#   3. Keep a backup of the private key somewhere safe (password manager), then delete the file.
#      If it's lost, installed apps can't accept updates signed with a new key: users would have to
#      download the new version by hand once.
set -euo pipefail
OUT="${1:-backgrounds-signing-key.pem}"
if [ -e "$OUT" ]; then echo "$OUT already exists, not overwriting"; exit 1; fi
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out "$OUT"
# The public key as the apps want it: base64 of the raw 64-byte X||Y point.
PUB=$(openssl ec -in "$OUT" -pubout -outform DER 2>/dev/null | tail -c 64 | base64 | tr -d '\n')
echo
echo "Private key written to: $OUT   (secret: UPDATE_SIGNING_KEY)"
echo "Public key (put this in app/update-public-key.txt):"
echo "$PUB"
