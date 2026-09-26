#!/usr/bin/env python3
"""Signs the release zips and writes update.json, the feed the apps check.

  make_feed.py --version 1.1.0 --key key.pem --base-url https://github.com/<owner>/<repo>/releases/download/v1.1.0 \
               --mac Backgrounds-mac.zip --windows Backgrounds-windows.zip --notes-from app/CHANGELOG.md --out update.json

The key is ECDSA P-256 (see make-signing-key.sh), passed as a file or in $UPDATE_SIGNING_KEY. For each platform
the signed message is  "backgrounds-update\\n<platform>\\n<version>\\n<sha256 of the zip>"  and the signature is
raw r||s (64 bytes, base64). Binding the version stops an old, validly signed zip from being passed off as new.
Needs: pip install cryptography
"""
import argparse, base64, hashlib, json, os, re, sys, datetime
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

ap = argparse.ArgumentParser()
ap.add_argument("--version", required=True)
ap.add_argument("--key")
ap.add_argument("--base-url", required=True)
ap.add_argument("--mac")
ap.add_argument("--windows")
ap.add_argument("--notes-from")
ap.add_argument("--notes", default="")
ap.add_argument("--out", required=True)
ap.add_argument("--expect-public-key", help="fail unless the signing key matches this public key (the one built into the apps)")
a = ap.parse_args()

pem = open(a.key, "rb").read() if a.key else os.environ.get("UPDATE_SIGNING_KEY", "").encode()
if not pem.strip():
    sys.exit("make_feed: no signing key (set the UPDATE_SIGNING_KEY secret; see app/release/make-signing-key.sh)")
key = serialization.load_pem_private_key(pem, password=None)
if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
    sys.exit("make_feed: the signing key must be an ECDSA P-256 key")

pub_b64 = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)[1:]).decode()
if a.expect_public_key is not None and a.expect_public_key.strip() != pub_b64:
    sys.exit("make_feed: the signing key does not match app/update-public-key.txt, so the apps would reject this "
             "release. Put this public key in app/update-public-key.txt (and rebuild), or fix the secret:\n  " + pub_b64)

def message(platform, version, sha):
    return f"backgrounds-update\n{platform}\n{version}\n{sha}".encode()

def entry(platform, path):
    data = open(path, "rb").read()
    sha = hashlib.sha256(data).hexdigest()
    r, s = utils.decode_dss_signature(key.sign(message(platform, a.version, sha), ec.ECDSA(hashes.SHA256())))
    sig = base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode()
    # self-check with the public key
    key.public_key().verify(utils.encode_dss_signature(r, s), message(platform, a.version, sha), ec.ECDSA(hashes.SHA256()))
    return {"url": a.base_url.rstrip("/") + "/" + os.path.basename(path), "size": len(data), "sha256": sha, "signature": sig}

notes = a.notes
if a.notes_from and os.path.exists(a.notes_from):
    text = open(a.notes_from, encoding="utf-8").read()
    m = re.search(r"^##\s*v?" + re.escape(a.version) + r"\b[^\n]*\n(.*?)(?=^##\s|\Z)", text, re.S | re.M)
    if m: notes = m.group(1).strip()

feed = {"version": a.version, "date": datetime.date.today().isoformat(), "notes": notes}
if a.mac: feed["mac"] = entry("mac", a.mac)
if a.windows: feed["windows"] = entry("windows", a.windows)
with open(a.out, "w") as fh: json.dump(feed, fh, indent=1)
print("make_feed: wrote %s for %s (public key %s)" % (a.out, a.version, pub_b64))
