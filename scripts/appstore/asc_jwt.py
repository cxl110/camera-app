#!/usr/bin/env python3
"""Mint an App Store Connect API JWT locally (ES256), without the Mac.

ASC wants a short-lived JWT signed with the ES256 private key from the App Store
Connect keys page (.p8). On the Mac this is usually done with
`xcrun altool --generate-jwt`, which makes every API call depend on that machine.
With `cryptography` available this reproduces it exactly:

    python3 asc_jwt.py --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
                       --key-id XXXX --issuer <uuid>

Prints the token on stdout (usable for ~20 minutes by ASC's rules; the iat is set
slightly in the past to tolerate clock skew, exp is capped at 20 minutes).

    python3 asc_jwt.py --selftest     # prove the signing/verification path works
"""

import argparse
import base64
import json
import sys
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA signatures come out DER-encoded; JWS needs fixed-width r||s."""
    r, s = asym_utils.decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def make_jwt(key_pem: bytes, key_id: str, issuer: str, ttl: int = 1200) -> str:
    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise SystemExit("not an EC private key — ASC expects a P-256 .p8")

    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        # 60s in the past: ASC rejects tokens whose iat is ahead of its clock
        "iat": now - 60,
        "exp": now - 60 + min(ttl, 1200),
        "aud": "appstoreconnect-v1",
        "iss": issuer,
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    ).encode()

    der_sig = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    return signing_input.decode() + "." + b64url(der_to_raw(der_sig))


def selftest() -> int:
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    token = make_jwt(pem, "TESTKEY123", "00000000-0000-0000-0000-000000000000")
    header_b64, payload_b64, sig_b64 = token.split(".")

    # header/payload must decode as the JSON we put in
    header = json.loads(base64.urlsafe_b64decode(header_b64 + "=="))
    payload = json.loads(base64.urlsafe_b64decode(payload_b64 + "=="))
    assert header["alg"] == "ES256" and header["kid"] == "TESTKEY123", header
    assert payload["aud"] == "appstoreconnect-v1", payload
    assert payload["exp"] - payload["iat"] <= 1200, payload
    assert payload["iat"] < time.time(), "iat must be in the past"

    # and the signature must verify against the public key (raw -> DER)
    raw = base64.urlsafe_b64decode(sig_b64 + "==")
    assert len(raw) == 64, f"signature is {len(raw)} bytes, expected 64"
    der = asym_utils.encode_dss_signature(
        int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    key.public_key().verify(
        der, f"{header_b64}.{payload_b64}".encode(), ec.ECDSA(hashes.SHA256()))

    print("selftest OK: header, payload and signature all verify")
    print("sample token prefix:", token[:40] + "...")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", help="path to AuthKey_XXXX.p8")
    ap.add_argument("--key-id", help="10-character key id")
    ap.add_argument("--issuer", help="issuer UUID from the keys page")
    ap.add_argument("--ttl", type=int, default=1200)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not (args.key and args.key_id and args.issuer):
        ap.error("--key, --key-id and --issuer are required (or use --selftest)")

    with open(args.key, "rb") as f:
        pem = f.read()
    print(make_jwt(pem, args.key_id, args.issuer, args.ttl))
    return 0


if __name__ == "__main__":
    sys.exit(main())
