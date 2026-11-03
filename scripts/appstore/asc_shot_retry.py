#!/usr/bin/env python3
"""Robust screenshot upload for App Store Connect.

The naive flow (reserve -> PUT chunks -> mark uploaded) leaves assets in FAILED
with only "ASSET_FAILED" as the reason when anything goes wrong mid-transfer, and
Apple gives no detail. This version:

  * deletes FAILED assets before retrying (a failed asset cannot be revived);
  * uploads one file at a time, with a pause between files;
  * re-reads the asset state after committing and retries up to N times;
  * prints each chunk's byte range and HTTP status so a partial transfer is
    obvious from the log.

    python3 asc_shot_retry.py --dir ~/asc_shots --set <appScreenshotSetId>
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


def jwt() -> str:
    out = subprocess.run(
        ["sh", "-c", f"cd /tmp && xcrun altool --generate-jwt --apiKey {KEY_ID} --apiIssuer {ISSUER}"],
        capture_output=True, text=True,
    )
    token = next((l.strip() for l in (out.stdout + out.stderr).splitlines() if l.strip().startswith("eyJ")), "")
    if not token:
        raise SystemExit("could not mint JWT")
    return token


TOKEN = jwt()


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"},
    )
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


def state_of(shot_id):
    st, d = api("GET", f"/appScreenshots/{shot_id}")
    a = d.get("data", {}).get("attributes", {})
    stt = (a.get("assetDeliveryState") or {}).get("state")
    return stt, a


def wait_ready(shot_id, timeout=120):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        stt, a = state_of(shot_id)
        if stt != last:
            print(f"      state: {stt}")
            last = stt
        if stt in ("COMPLETE", "FAILED"):
            return stt, a
        time.sleep(5)
    return "TIMEOUT", {}


def reserve(set_id, name, size):
    st, d = api("POST", "/appScreenshots", {
        "data": {"type": "appScreenshots",
                 "attributes": {"fileName": name, "fileSize": size},
                 "relationships": {"appScreenshotSet": {
                     "data": {"type": "appScreenshotSets", "id": set_id}}}}})
    if st >= 400:
        raise RuntimeError(f"reserve failed {st}: {json.dumps(d)[:300]}")
    return d["data"]


def put_chunks(ops, blob):
    for i, op in enumerate(ops, 1):
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        if len(chunk) != op["length"]:
            raise RuntimeError(f"chunk {i}: have {len(chunk)} bytes, op wants {op['length']}")
        req = urllib.request.Request(op["url"], data=chunk, method=op.get("method", "PUT"))
        for hdr in op.get("requestHeaders", []):
            req.add_header(hdr["name"], hdr["value"])
        with urllib.request.urlopen(req, timeout=120) as r:
            print(f"      chunk {i}/{len(ops)} bytes={len(chunk)} -> HTTP {r.status}")


def upload_one(set_id, path, name, attempts=3):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        blob = f.read()
    for attempt in range(1, attempts + 1):
        print(f"  {name} ({size} bytes) attempt {attempt}")
        shot = reserve(set_id, name, size)
        shot_id = shot["id"]
        ops = shot["attributes"].get("uploadOperations") or []
        print(f"      {len(ops)} upload operation(s)")
        try:
            put_chunks(ops, blob)
            st, d = api("PATCH", f"/appScreenshots/{shot_id}",
                        {"data": {"type": "appScreenshots", "id": shot_id,
                                  "attributes": {"uploaded": True}}})
            print(f"      commit -> {st}")
            if st >= 400:
                raise RuntimeError(f"commit failed: {json.dumps(d)[:200]}")
            state, _ = wait_ready(shot_id)
            if state == "COMPLETE":
                return shot_id
            print(f"      {state}; deleting and retrying")
            api("DELETE", f"/appScreenshots/{shot_id}")
        except Exception as e:
            print(f"      error: {e}")
            try:
                api("DELETE", f"/appScreenshots/{shot_id}")
            except Exception:
                pass
        time.sleep(3 * attempt)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--set", required=True, dest="set_id")
    ap.add_argument("--delay", type=float, default=4.0)
    args = ap.parse_args()

    st, d = api("GET", f"/appScreenshotSets/{args.set_id}/appScreenshots")
    existing = d.get("data", [])
    done = set()
    for s in existing:
        a = s["attributes"]
        stt = (a.get("assetDeliveryState") or {}).get("state")
        if stt == "COMPLETE":
            done.add(a.get("fileName"))
            print(f"keep   {a.get('fileName')} ({stt})")
        else:
            print(f"delete {a.get('fileName')} ({stt})")
            api("DELETE", f"/appScreenshots/{s['id']}")

    files = sorted(f for f in os.listdir(args.dir) if f.lower().endswith((".png", ".jpg", ".jpeg")))
    for name in files:
        if name in done:
            print(f"skip   {name} (already complete)")
            continue
        path = os.path.join(args.dir, name)
        shot_id = upload_one(args.set_id, path, name)
        print(f"  => {name}: {'OK ' + shot_id if shot_id else 'FAILED'}")
        time.sleep(args.delay)

    st, d = api("GET", f"/appScreenshotSets/{args.set_id}/appScreenshots")
    print("\nfinal set:")
    for s in d.get("data", []):
        a = s["attributes"]
        ia = a.get("imageAsset") or {}
        print(f"  {a.get('fileName')}  {ia.get('width')}x{ia.get('height')}  {(a.get('assetDeliveryState') or {}).get('state')}")


if __name__ == "__main__":
    main()
