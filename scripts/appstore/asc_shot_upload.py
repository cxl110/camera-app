#!/usr/bin/env python3
"""Upload screenshots to an App Store Connect screenshot set, patiently.

Why this exists (two hard-won details):

1. Uploading several images back-to-back gets some of them rejected with
   `ASSET_FAILED` and no explanation. Doing them one at a time, with a pause,
   works.
2. After committing an upload the asset reports `UPLOAD_COMPLETE` for a while
   before Apple flips it to `COMPLETE`. Treating `UPLOAD_COMPLETE` as failure (and
   deleting the asset) throws away perfectly good uploads and loops forever.

So: upload sequentially, then poll the *set* until every asset is COMPLETE or
FAILED, and only report the failures.

    python3 asc_shot_upload.py --dir ~/asc_shots --set <setId> [--upload-only]
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

KEY_ID = "C5LL8Z7QYM"
ISSUER = "979a8469-69a2-461d-a324-f8cece66b002"
API = "https://api.appstoreconnect.apple.com/v1"


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
            return e.code, {"raw": raw[:300]}


def set_state(set_id):
    st, d = api("GET", f"/appScreenshotSets/{set_id}/appScreenshots")
    out = []
    for s in d.get("data", []):
        a = s["attributes"]
        ia = a.get("imageAsset") or {}
        out.append({
            "id": s["id"],
            "name": a.get("fileName"),
            "w": ia.get("width"), "h": ia.get("height"),
            "state": (a.get("assetDeliveryState") or {}).get("state"),
        })
    return out


def upload(set_id, path, name):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        blob = f.read()
    print(f"  uploading {name} ({size} bytes)")
    st, d = api("POST", "/appScreenshots", {
        "data": {"type": "appScreenshots",
                 "attributes": {"fileName": name, "fileSize": size},
                 "relationships": {"appScreenshotSet": {
                     "data": {"type": "appScreenshotSets", "id": set_id}}}}})
    if st >= 400:
        print(f"    reserve failed {st}: {json.dumps(d)[:200]}")
        return False
    shot = d["data"]
    ops = shot["attributes"].get("uploadOperations") or []
    for i, op in enumerate(ops, 1):
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op.get("method", "PUT"))
        for hdr in op.get("requestHeaders", []):
            req.add_header(hdr["name"], hdr["value"])
        with urllib.request.urlopen(req, timeout=180) as r:
            print(f"    chunk {i}/{len(ops)} {len(chunk)} bytes -> {r.status}")
    st, d = api("PATCH", f"/appScreenshots/{shot['id']}",
                {"data": {"type": "appScreenshots", "id": shot["id"],
                          "attributes": {"uploaded": True}}})
    print(f"    commit -> {st}")
    return st < 400


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--set", required=True, dest="set_id")
    ap.add_argument("--pause", type=float, default=5.0)
    ap.add_argument("--poll-minutes", type=float, default=15.0)
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.dir) if f.lower().endswith((".png", ".jpg", ".jpeg")))
    present = {s["name"] for s in set_state(args.set_id)}
    todo = [f for f in files if f not in present]
    print(f"{len(files)} file(s), {len(todo)} to upload")

    for name in todo:
        upload(args.set_id, os.path.join(args.dir, name), name)
        time.sleep(args.pause)

    deadline = time.time() + args.poll_minutes * 60
    last = None
    while time.time() < deadline:
        rows = set_state(args.set_id)
        summary = ["%s:%s" % (r["name"], r["state"]) for r in rows]
        if summary != last:
            print("  " + "\n  ".join(summary))
            last = summary
        pending = [r for r in rows if r["state"] in ("UPLOAD_COMPLETE", "PROCESSING", None)]
        if not pending:
            break
        time.sleep(20)

    rows = set_state(args.set_id)
    ok = [r for r in rows if r["state"] == "COMPLETE"]
    bad = [r for r in rows if r["state"] == "FAILED"]
    other = [r for r in rows if r["state"] not in ("COMPLETE", "FAILED")]
    print(f"\nRESULT complete={len(ok)} failed={len(bad)} pending={len(other)}")
    for r in bad:
        print(f"  FAILED {r['name']} (id {r['id']})")
    for r in other:
        print(f"  {r['state']} {r['name']}")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
