#!/usr/bin/env python3
"""Print the current App Store review state for SQ Cam — runs on any machine.

Unlike the other scripts here this one does not shell out to `xcrun altool`: it
mints the JWT itself (see asc_jwt.py), so it works on Windows/Linux and does not
need the Mac to be awake. Only the .p8 key file is required.

    python3 scripts/appstore/asc_status.py [--key PATH] [--json]
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_jwt import make_jwt  # noqa: E402

APP_ID = "6827651876"
KEY_ID = "C5LL8Z7QYM"
ISSUER = "979a8469-69a2-461d-a324-f8cece66b002"
DEFAULT_KEY = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_C5LL8Z7QYM.p8")
API = "https://api.appstoreconnect.apple.com/v1"


def get(path, token):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"__error__": e.code, "body": e.read().decode()[:300]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.key):
        raise SystemExit(f"key not found: {args.key}\n"
                         "copy it from the Mac: ~/.appstoreconnect/private_keys/")

    with open(args.key, "rb") as f:
        token = make_jwt(f.read(), KEY_ID, ISSUER)

    versions = get(f"/apps/{APP_ID}/appStoreVersions?limit=1", token)
    if "__error__" in versions:
        print("API error:", versions["__error__"], versions.get("body", "")[:200])
        return 1
    v = versions["data"][0]
    va = v["attributes"]

    subs = get(f"/apps/{APP_ID}/reviewSubmissions?limit=10", token)
    live = [s for s in subs.get("data", []) if s["attributes"].get("submittedDate")]

    out = {
        "version": va.get("versionString"),
        "state": va.get("appStoreState"),
        "versionState": va.get("appVersionState"),
        "submitted": live[0]["attributes"].get("submittedDate") if live else None,
        "submissionState": live[0]["attributes"].get("state") if live else None,
        "created": va.get("createdDate"),
    }

    if args.json:
        print(json.dumps(out, indent=2))
        return 0

    print(f"version : {out['version']}")
    print(f"state   : {out['state']}")
    if out["submitted"]:
        print(f"submitted: {out['submitted']}  ({out['submissionState']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
