#!/usr/bin/env python3
"""Upload the App Store screenshots for SQ Cam (6.5-inch iPhone set).

    python3 scripts/appstore/asc_screenshots.py --dir <folder> [--display-type APP_IPHONE_65]

App Store Connect takes screenshots through a three-step flow, and skipping any
step leaves the set empty without an obvious error:

  1. POST /v1/appScreenshots {fileName, fileSize}  -> per-image uploadOperations
  2. PUT each chunk to the returned URLs            -> the bytes go to Apple's storage
  3. PATCH /v1/appScreenshots/{id} {uploaded: true} -> marks it usable

Then the set itself must be committed: PATCH the screenshot set with the image ids
in order (Apple calls this the "screenshot order" relationship).

Only the 6.5-inch set is uploaded: it is one of the two sets Apple accepts as the
required iPhone set, and iPhone 13 Pro Max screenshots are natively 1284x2778.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

KEY_ID = "C5LL8Z7QYM"
ISSUER = "979a8469-69a2-461d-a324-f8cece66b002"
API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6827651876"
LOCALE = "en-US"
DISPLAY_TYPE = "APP_IPHONE_65"

ALLOWED_SIZES = {(1284, 2778), (1242, 2688), (2778, 1284), (2688, 1242)}


def jwt() -> str:
    out = subprocess.run(
        ["sh", "-c", f"cd /tmp && xcrun altool --generate-jwt --apiKey {KEY_ID} --apiIssuer {ISSUER}"],
        capture_output=True, text=True,
    )
    token = next((l.strip() for l in (out.stdout + out.stderr).splitlines() if l.strip().startswith("eyJ")), "")
    if not token:
        raise SystemExit("could not mint JWT (needs the Mac + the App Store Connect key)")
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
            return e.code, {"raw": raw[:400]}


def image_size(path):
    """Read PNG/JPEG dimensions without extra dependencies."""
    with open(path, "rb") as f:
        head = f.read(32)
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        import struct
        w, h = struct.unpack(">II", head[16:24])
        return w, h
    if head[:2] == b"\xff\xd8":
        with open(path, "rb") as f:
            data = f.read()
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3):
                h = (data[i + 5] << 8) + data[i + 6]
                w = (data[i + 7] << 8) + data[i + 8]
                return w, h
            seg = (data[i + 2] << 8) + data[i + 3]
            i += 2 + seg
    raise SystemExit(f"cannot read dimensions: {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--display-type", default=DISPLAY_TYPE)
    args = ap.parse_args()

    files = sorted(
        f for f in os.listdir(args.dir)
        if f.lower().endswith((".png", ".jpg", ".jpeg"))
    )
    if not files:
        raise SystemExit(f"no images in {args.dir}")
    if len(files) > 10:
        raise SystemExit(f"{len(files)} images, App Store accepts at most 10")
    print(f"{len(files)} image(s) from {args.dir}")

    # find the version + its localization
    st, d = api("GET", f"/apps/{APP_ID}/appStoreVersions")
    vid = d["data"][0]["id"]
    st, d = api("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")
    vloc = next(x for x in d["data"] if x["attributes"]["locale"] == LOCALE)
    lloc_id = vloc["id"]

    # reuse or create the screenshot set
    st, d = api("GET", f"/appStoreVersionLocalizations/{lloc_id}/appScreenshotSets")
    sets = [s for s in d.get("data", []) if s["attributes"]["screenshotDisplayType"] == args.display_type]
    if sets:
        set_id = sets[0]["id"]
        print("reusing screenshot set", set_id)
    else:
        st, d = api("POST", "/appScreenshotSets", {
            "data": {"type": "appScreenshotSets",
                     "attributes": {"screenshotDisplayType": args.display_type},
                     "relationships": {"appStoreVersionLocalization": {
                         "data": {"type": "appStoreVersionLocalizations", "id": lloc_id}}}}})
        if st >= 400:
            raise SystemExit(f"create set failed: {st} {json.dumps(d)[:400]}")
        set_id = d["data"]["id"]
        print("created screenshot set", set_id)

    ids = []
    for name in files:
        path = os.path.join(args.dir, name)
        size = os.path.getsize(path)
        w, h = image_size(path)
        if (w, h) not in ALLOWED_SIZES:
            raise SystemExit(f"{name}: {w}x{h} is not a valid 6.5-inch size {sorted(ALLOWED_SIZES)}")
        print(f"  {name}  {w}x{h}  {size} bytes")

        st, d = api("POST", "/appScreenshots", {
            "data": {"type": "appScreenshots",
                     "attributes": {"fileName": name, "fileSize": size},
                     "relationships": {"appScreenshotSet": {
                         "data": {"type": "appScreenshotSets", "id": set_id}}}}})
        if st >= 400:
            raise SystemExit(f"reserve failed for {name}: {st} {json.dumps(d)[:400]}")
        shot_id = d["data"]["id"]
        ops = d["data"]["attributes"].get("uploadOperations") or []

        with open(path, "rb") as f:
            blob = f.read()
        for op in ops:
            chunk = blob[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
            for hdr in op.get("requestHeaders", []):
                req.add_header(hdr["name"], hdr["value"])
            with urllib.request.urlopen(req) as r:
                if r.status >= 300:
                    raise SystemExit(f"chunk upload failed for {name}: {r.status}")

        st, d = api("PATCH", f"/appScreenshots/{shot_id}", {
            "data": {"type": "appScreenshots", "id": shot_id, "attributes": {"uploaded": True}}})
        if st >= 400:
            raise SystemExit(f"commit failed for {name}: {st} {json.dumps(d)[:400]}")
        ids.append(shot_id)
        print(f"    uploaded id={shot_id}")

    # order the set (Apple shows them in relationship order)
    st, d = api("PATCH", f"/appScreenshotSets/{set_id}", {
        "data": {"type": "appScreenshotSets", "id": set_id,
                 "relationships": {"appScreenshots": {
                     "data": [{"type": "appScreenshots", "id": i} for i in ids]}}}})
    print("order set ->", st)

    st, d = api("GET", f"/appScreenshotSets/{set_id}/appScreenshots")
    print(f"\nset now has {len(d.get('data', []))} screenshot(s):")
    for s in d.get("data", []):
        a = s["attributes"]
        print(f"  {a.get('fileName')}  {a.get('imageAsset', {}).get('width')}x{a.get('imageAsset', {}).get('height')}")


if __name__ == "__main__":
    main()
