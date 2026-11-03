#!/usr/bin/env python3
"""Fill the App Store Connect record for SQ Cam.

Idempotent: safe to re-run; it PATCHes the same values and prints what is stored
afterwards. Run it on the Mac because the API key lives there
(~/.appstoreconnect/private_keys) and the JWT is minted with `xcrun altool`.

    python3 scripts/appstore/asc_metadata.py           # apply
    python3 scripts/appstore/asc_metadata.py --dry-run # print only

What it sets:
  * app name, subtitle, privacy policy URL      (appInfoLocalization)
  * version string 1.2.0, copyright             (appStoreVersion)
  * description, keywords, support/marketing URL (appStoreVersionLocalization)
  * primary category Photo & Video              (appInfo relationship)
  * age rating 4+                               (ageRatingDeclaration)
"""

import json
import subprocess
import sys
import urllib.error
import urllib.request

KEY_ID = "C5LL8Z7QYM"
ISSUER = "979a8469-69a2-461d-a324-f8cece66b002"
API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6827651876"
BUNDLE = "com.zivigo.cameraapp"
LOCALE = "en-US"

NAME = "SQ Cam - Film Camera & Filters"
SUBTITLE = "Film looks for your camera"
PRIVACY_URL = "https://sanqi-lab.cn/sqcam/privacy.html"
SUPPORT_URL = "https://sanqi-lab.cn/sqcam/support.html"
VERSION = "1.2.0"
COPYRIGHT = "2026 Shenzhen Beili Times Technology Co., Ltd."
KEYWORDS = "zivigo,wifi camera,film simulation,fujifilm,kodak,portra,velvia,acros,photo editor,retro,grain"

DESCRIPTION = """SQ Cam is the companion app for ZIVIGo compact cameras.

Join the camera's own Wi-Fi and your iPhone becomes its viewfinder and its photo lab.

LIVE VIEW AND SHUTTER
Frame the shot on a large screen and release the shutter without touching the camera.

CAMERA ROLL
Browse what is on the camera, download full-resolution photos, and fetch videos (converted to MP4 automatically so the iOS library can play them).

13 FILM SIMULATIONS
PROVIA, VELVIA, ASTIA, ACROS, Classic Chrome, Classic Negative, ETERNA, PRO Neg, Pro 400H, Superia, Reala, Kodak Portra 400, Gold 200, UltraMax 400 - with a BEFORE/AFTER toggle so you can see exactly what each one does.

FINISHING TOUCHES
Adjustable grain and light leaks, plus film-frame borders: 35mm contact strip, Polaroid frame and more.

ORIGINAL DATES PRESERVED
Exported photos keep the capture date reported by the camera, so your library stays in order.

NO CAMERA? NO PROBLEM
Tap "Try without a camera" and apply every film look and border to a photo from your library.

PRIVACY
SQ Cam collects no data. Photos travel only between your iPhone and your camera."""

DRY = "--dry-run" in sys.argv


def jwt() -> str:
    out = subprocess.run(
        ["sh", "-c", f"cd /tmp && xcrun altool --generate-jwt --apiKey {KEY_ID} --apiIssuer {ISSUER}"],
        capture_output=True, text=True,
    )
    token = next((l.strip() for l in (out.stdout + out.stderr).splitlines() if l.strip().startswith("eyJ")), "")
    if not token:
        raise SystemExit("could not mint JWT (needs the Mac + the App Store Connect key)")
    return token


TOKEN = "" if DRY else jwt()


def api(method, path, body=None):
    if DRY:
        print(f"  [dry-run] {method} {path}")
        return 200, {}
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


def check_len(label, value, limit):
    if len(value) > limit:
        raise SystemExit(f"{label} is {len(value)} chars, limit {limit}: {value}")
    print(f"  {label}: {len(value)}/{limit} chars")


def show_errors(status, payload):
    if status >= 400:
        for e in payload.get("errors", []):
            print(f"    ERROR {e.get('code')}: {e.get('title')} — {(e.get('detail') or '')[:200]}")
    return status < 400


def main():
    print("App Store Connect — metadata for SQ Cam")
    check_len("name", NAME, 30)
    check_len("subtitle", SUBTITLE, 30)
    check_len("keywords", KEYWORDS, 100)

    # ── app info (name, subtitle, privacy URL) ──
    st, d = api("GET", f"/apps/{APP_ID}/appInfos")
    info_id = d["data"][0]["id"]
    st, d = api("GET", f"/appInfos/{info_id}/appInfoLocalizations")
    loc = next(x for x in d["data"] if x["attributes"]["locale"] == LOCALE)
    st, r = api("PATCH", f"/appInfoLocalizations/{loc['id']}", {
        "data": {"type": "appInfoLocalizations", "id": loc["id"],
                 "attributes": {"name": NAME, "subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY_URL}}})
    print("name/subtitle/privacy ->", st)
    show_errors(st, r)

    # ── version string + copyright ──
    st, d = api("GET", f"/apps/{APP_ID}/appStoreVersions")
    version = d["data"][0]
    vid = version["id"]
    st, r = api("PATCH", f"/appStoreVersions/{vid}", {
        "data": {"type": "appStoreVersions", "id": vid,
                 "attributes": {"versionString": VERSION, "copyright": COPYRIGHT}}})
    print("version/copyright ->", st)
    show_errors(st, r)

    # ── description, keywords, URLs ──
    st, d = api("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")
    vloc = next(x for x in d["data"] if x["attributes"]["locale"] == LOCALE)
    st, r = api("PATCH", f"/appStoreVersionLocalizations/{vloc['id']}", {
        "data": {"type": "appStoreVersionLocalizations", "id": vloc["id"],
                 "attributes": {"description": DESCRIPTION, "keywords": KEYWORDS,
                                "supportUrl": SUPPORT_URL, "marketingUrl": SUPPORT_URL}}})
    print("description/keywords/urls ->", st)
    show_errors(st, r)

    # ── primary category: Photo & Video ──
    st, d = api("GET", "/appCategories?limit=200")
    cats = {c["attributes"]["platforms"][0] + ":" + str(c["id"]): c for c in d.get("data", [])}
    photo_id = None
    for c in d.get("data", []):
        if c["id"] == "PHOTO_AND_VIDEO":
            photo_id = c["id"]
    print("primary category id ->", photo_id)
    if photo_id:
        st, r = api("PATCH", f"/appInfos/{info_id}", {
            "data": {"type": "appInfos", "id": info_id,
                     "relationships": {"primaryCategory": {"data": {"type": "appCategories", "id": photo_id}}}}})
        print("primaryCategory ->", st)
        show_errors(st, r)

    # ── age rating 4+ ──
    st, d = api("GET", f"/appInfos/{info_id}?include=ageRatingDeclaration")
    decl = (d.get("included") or [{}])[0]
    did = decl.get("id")
    if did:
        st, r = api("PATCH", f"/ageRatingDeclarations/{did}", {
            "data": {"type": "ageRatingDeclarations", "id": did, "attributes": {
                "alcoholTobaccoOrDrugUseOrReferences": "NONE",
                "contests": "NONE",
                "gambling": False,
                "gamblingSimulated": "NONE",
                "horrorOrFearThemes": "NONE",
                "matureOrSuggestiveThemes": "NONE",
                "medicalOrTreatmentInformation": "NONE",
                "profanityOrCrudeHumor": "NONE",
                "sexualContentGraphicAndNudity": "NONE",
                "sexualContentOrNudity": "NONE",
                "unrestrictedWebAccess": False,
                "violenceCartoonOrFantasy": "NONE",
                "violenceRealisticProlongedGraphicOrSadistic": "NONE",
                "violenceRealistic": "NONE",
                "kidsAgeBand": None,
            }}})
        print("ageRating 4+ ->", st)
        show_errors(st, r)

    # ── readback ──
    print("\nreadback")
    st, d = api("GET", f"/appStoreVersions/{vid}")
    a = d["data"]["attributes"]
    print(f"  version={a.get('versionString')} state={a.get('appStoreState')} copyright={a.get('copyright')}")
    st, d = api("GET", f"/appStoreVersionLocalizations/{vloc['id']}")
    a = d["data"]["attributes"]
    print(f"  description={len(a.get('description') or '')} chars keywords={a.get('keywords')}")
    print(f"  supportUrl={a.get('supportUrl')} marketingUrl={a.get('marketingUrl')}")
    st, d = api("GET", f"/appInfoLocalizations/{loc['id']}")
    a = d["data"]["attributes"]
    print(f"  name={a.get('name')} subtitle={a.get('subtitle')}")
    print(f"  privacyPolicyUrl={a.get('privacyPolicyUrl')}")


if __name__ == "__main__":
    main()
