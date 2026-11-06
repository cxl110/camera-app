"""Build a self-signed HarmonyOS/OpenHarmony provision profile for SQ Cam.

Uses the OpenHarmony test PKI that ships with the DevEco SDK
(toolchains/lib/OpenHarmony.p12 + OpenHarmonyProfileRelease.pem). The profile
tells the device which bundle name and signing certificate an app is allowed to
run under.

NOTE: this chain is the public OpenHarmony *test* root. OpenHarmony devices and
emulators accept it; a retail HarmonyOS NEXT phone will not -- those only trust
Huawei-issued profiles bound to the device UDID, which needs a Huawei ID.
"""

import json
import time
from pathlib import Path

SDK_LIB = Path(r"C:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib")
OUT = Path(r"C:\H3\APP\camera_app\build\ohos\signing")
OUT.mkdir(parents=True, exist_ok=True)

BUNDLE = "com.zivigo.camera_app"
VERSION_NAME = "1.2.0"
VERSION_CODE = 24

template = json.loads((SDK_LIB / "UnsgnedReleasedProfileTemplate.json").read_text(encoding="utf-8"))

now = int(time.time())
template["version-name"] = "2.0.0"
template["version-code"] = 2
template["validity"] = {
    "not-before": now - 86400,          # started yesterday
    "not-after": now + 10 * 365 * 86400,  # good for ~10 years
}
template["bundle-info"]["bundle-name"] = BUNDLE
template["bundle-info"]["developer-id"] = "Shenzhen Beili Times Technology Co Ltd"
template["bundle-info"]["apl"] = "normal"
template["bundle-info"]["app-feature"] = "hos_normal_app"
template["issuer"] = "pki_internal"

dst = OUT / "sqcam-profile-release.json"
dst.write_text(json.dumps(template, indent=2, ensure_ascii=False), encoding="utf-8")

print("wrote", dst)
print("  bundle-name :", template["bundle-info"]["bundle-name"])
print("  type        :", template["type"])
print("  distribution:", template["app-distribution-type"])
print("  not-before  :", time.strftime("%Y-%m-%d", time.localtime(template["validity"]["not-before"])))
print("  not-after   :", time.strftime("%Y-%m-%d", time.localtime(template["validity"]["not-after"])))
