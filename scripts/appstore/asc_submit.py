#!/usr/bin/env python3
"""Submit the SQ Cam version for App Store review.

    python3 scripts/appstore/asc_submit.py [--dry-run]

The submission flow changed: appStoreVersionSubmissions is gone, you now create a
reviewSubmission, add the version as an item, then flip `submitted` to true. The
final PATCH is where App Store Connect validates everything, so the error list it
returns is the authoritative "what is still missing" answer — which is why this
script prints every error verbatim instead of paraphrasing.
"""

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

KEY_ID = "C5LL8Z7QYM"
ISSUER = "979a8469-69a2-461d-a324-f8cece66b002"
API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6827651876"


def jwt():
    out = subprocess.run(
        ["sh", "-c", f"cd /tmp && xcrun altool --generate-jwt --apiKey {KEY_ID} --apiIssuer {ISSUER}"],
        capture_output=True, text=True)
    tok = next((l.strip() for l in (out.stdout + out.stderr).splitlines() if l.strip().startswith("eyJ")), "")
    if not tok:
        raise SystemExit("could not mint JWT")
    return tok


TOKEN = jwt()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:500]}


def show_errors(payload):
    for e in payload.get("errors", []):
        print(f"  [{e.get('code')}] {(e.get('title') or '')}")
        detail = (e.get('detail') or '').strip()
        if detail:
            print(f"     {detail}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    st, d = api("GET", f"/apps/{APP_ID}/appStoreVersions")
    ver = d["data"][0]
    vid, vstr = ver["id"], ver["attributes"]["versionString"]
    print(f"version {vstr} state={ver['attributes']['appStoreState']}")

    st, d = api("GET", f"/apps/{APP_ID}/reviewSubmissions?filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW")
    for rs in d.get("data", []):
        print(f"existing review submission {rs['id']} state={rs['attributes'].get('state')}")

    if args.dry_run:
        print("[dry-run] would create reviewSubmission + item + submit")
        return

    st, d = api("POST", "/reviewSubmissions", {
        "data": {"type": "reviewSubmissions",
                 "attributes": {"platform": "IOS"},
                 "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    print("create reviewSubmission ->", st)
    if st >= 400:
        show_errors(d)
        return
    rid = d["data"]["id"]

    st, d = api("POST", "/reviewSubmissionItems", {
        "data": {"type": "reviewSubmissionItems",
                 "relationships": {
                     "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rid}},
                     "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    print("add version item ->", st)
    if st >= 400:
        show_errors(d)
        api("DELETE", f"/reviewSubmissions/{rid}")
        return

    st, d = api("PATCH", f"/reviewSubmissions/{rid}", {
        "data": {"type": "reviewSubmissions", "id": rid, "attributes": {"submitted": True}}})
    print("submit ->", st)
    if st >= 400:
        show_errors(d)
        print("\n(the draft submission was left in place; fix the items above and re-run)")
        return

    st, d = api("GET", f"/appStoreVersions/{vid}")
    print("\nRESULT=SUBMITTED")
    print("  version state:", d["data"]["attributes"]["appStoreState"])


if __name__ == "__main__":
    main()
