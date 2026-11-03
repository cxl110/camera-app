#!/usr/bin/env python3
"""Attach the freshly uploaded build to the App Store version and fill review notes.

    ASC_CONTACT_PHONE=+86... ASC_CONTACT_EMAIL=... ASC_CONTACT_NAME="..." \
      python3 scripts/appstore/asc_attach_build.py [--build 24] [--wait-minutes 45]

Why review notes matter here: the reviewer has no ZIVIGo camera, so without a
pointer to "Try without a camera" the app looks unusable and gets rejected under
guideline 2.1. The notes also explain the Local Network permission, which is
otherwise a common rejection reason for camera/Wi-Fi apps.
"""

import argparse
import json
import os
import subprocess
import time
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
            return e.code, {"raw": raw[:300]}


NOTES = """SQ Cam is the companion app for ZIVIGo compact cameras.

NO CAMERA NEEDED FOR REVIEW
The reviewer does not have a ZIVIGo camera, and the app is fully usable without one:
1. Launch the app. The camera screen shows "Disconnected" and an outlined button
   "Try without a camera".
2. Tap it. iOS asks for photo library access - pick any photo.
3. The full editing experience opens: 13 film simulations with a BEFORE/AFTER
   toggle, grain, light leaks, and film-frame borders. Export saves to Photos.

WHAT THE APP DOES WITH A CAMERA
The ZIVIGo camera creates its own Wi-Fi hotspot (no internet). The app joins it and
talks to the camera's local HTTP API on 192.168.5.1 to show a live view, release the
shutter, browse the camera roll, and download photos/videos. Nothing leaves the
device, and there is no account, no analytics and no third-party tracking.

LOCAL NETWORK PERMISSION
iOS asks for Local Network access on first connect. It is required to reach the
camera; if it is denied the app cannot connect and shows the camera as
"Disconnected". There is no way around it, and no data is sent anywhere else.

VIDEOS
The camera records AVI. iOS cannot play AVI, so the app transcodes to MP4 locally
before saving to the photo library. If transcode fails the app reports the error and
saves nothing.

FIRMWARE UPDATES
Not included in this build. The app does not ship or flash device firmware.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=None, help="build number, default: newest")
    ap.add_argument("--wait-minutes", type=float, default=45.0)
    args = ap.parse_args()

    phone = os.environ.get("ASC_CONTACT_PHONE", "")
    email = os.environ.get("ASC_CONTACT_EMAIL", "support@sanqi-lab.cn")
    name = os.environ.get("ASC_CONTACT_NAME", "Sanqi Support")

    # ── find the build and wait for Apple to finish processing ──
    deadline = time.time() + args.wait_minutes * 60
    build = None
    while time.time() < deadline:
        st, d = api("GET", f"/builds?filter[app]={APP_ID}&limit=10&sort=-uploadedDate")
        for b in d.get("data", []):
            a = b["attributes"]
            if args.build and a.get("version") != args.build:
                continue
            if args.build is None and build is None:
                build = b
            if a.get("version") == args.build:
                build = b
                break
        if build:
            state = build["attributes"].get("processingState")
            print(f"build {build['attributes'].get('version')}: {state}")
            if state == "VALID":
                break
            if state in ("INVALID", "FAILED"):
                raise SystemExit("build processing failed — check the email from App Store Connect")
        else:
            print("build not listed yet")
        time.sleep(30)

    if not build or build["attributes"].get("processingState") != "VALID":
        raise SystemExit("timed out waiting for the build to become VALID")

    build_id = build["id"]
    print("build id:", build_id)

    # ── attach to the version ──
    st, d = api("GET", f"/apps/{APP_ID}/appStoreVersions")
    ver = d["data"][0]
    vid = ver["id"]
    st, r = api("PATCH", f"/appStoreVersions/{vid}", {
        "data": {"type": "appStoreVersions", "id": vid,
                 "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    print("attach build ->", st)
    if st >= 400:
        print(json.dumps(r)[:400])

    # ── review notes ──
    st, d = api("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail")
    detail = d.get("data")
    attrs = {"notes": NOTES, "demoAccountRequired": False,
             "contactEmail": email,
             "contactFirstName": name.split()[0] if name else "Sanqi",
             "contactLastName": " ".join(name.split()[1:]) or "Support"}
    if phone:
        attrs["contactPhone"] = phone
    if detail:
        st, r = api("PATCH", f"/appStoreReviewDetails/{detail['id']}", {
            "data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": attrs}})
        print("review notes ->", st)
    else:
        st, r = api("POST", "/appStoreReviewDetails", {
            "data": {"type": "appStoreReviewDetails", "attributes": attrs,
                     "relationships": {"appStoreVersion": {
                         "data": {"type": "appStoreVersions", "id": vid}}}}})
        print("review notes (create) ->", st)
    if st >= 400:
        for e in r.get("errors", []):
            print("  ERROR", e.get("code"), (e.get("detail") or "")[:160])

    # ── readback ──
    print("\nreadback")
    st, d = api("GET", f"/appStoreVersions/{vid}?include=build")
    a = d["data"]["attributes"]
    inc = (d.get("included") or [])
    print(f"  version={a.get('versionString')} state={a.get('appStoreState')}")
    print(f"  build={(inc[0]['attributes'].get('version') if inc else '(none)')} "
          f"{(inc[0]['attributes'].get('processingState') if inc else '')}")
    st, d = api("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail")
    det = d.get("data")
    print(f"  reviewNotes={len((det or {}).get('attributes', {}).get('notes') or '')} chars")


if __name__ == "__main__":
    main()
