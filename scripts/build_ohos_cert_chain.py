"""Assemble the app signing certificate chain for hap-sign-tool.

The keystore's "openharmony application release" entry holds a *self-signed*
placeholder cert, so exporting it directly produces a chain the tool rejects
("verify certificate chain failed"). The real leaf -- issued by the OpenHarmony
Application CA -- is embedded verbatim in the profile template's
`distribution-certificate` field. Use that, then the CA, then the root.
"""

import json
from pathlib import Path

SDK_LIB = Path(r"C:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib")
OUT = Path(r"C:\H3\APP\camera_app\build\ohos\signing")

template = json.loads((SDK_LIB / "UnsgnedReleasedProfileTemplate.json").read_text(encoding="utf-8"))
leaf = template["bundle-info"]["distribution-certificate"]
if not leaf.endswith("\n"):
    leaf += "\n"

ca = (OUT / "app-ca.pem").read_text(encoding="ascii")
root = (OUT / "app-root.pem").read_text(encoding="ascii")

chain = leaf + ca + root
dst = OUT / "app-chain.pem"
dst.write_text(chain, encoding="ascii")

count = chain.count("BEGIN CERTIFICATE")
print("wrote", dst, "with", count, "certs")
for line in chain.splitlines():
    if line.startswith("-----BEGIN"):
        continue
print("leaf subject: OpenHarmony Application Release (from profile template)")
