"""Inspect the release AAB / merged manifest for Google Play readiness.

Prints: min/target SDK, merged permissions, ABIs shipped, and whether every
native library is 16 KB page-size compatible (LOAD segments aligned to 0x4000).
"""

import re
import struct
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AAB = ROOT / "build" / "app" / "outputs" / "bundle" / "release" / "app-release.aab"
MERGED = ROOT / "build" / "app" / "intermediates" / "merged_manifests" / "release" / "AndroidManifest.xml"


def merged_manifest():
    if not MERGED.exists():
        # Flutter's newer output layout
        cands = list((ROOT / "build" / "app" / "intermediates").rglob("release/**/AndroidManifest.xml"))
        if not cands:
            print("!! merged manifest not found")
            return
        path = cands[0]
    else:
        path = MERGED
    text = path.read_text(encoding="utf-8", errors="replace")
    print("merged manifest:", path.relative_to(ROOT))
    m = re.search(r'<uses-sdk[^>]*>', text)
    if m:
        print("  ", " ".join(m.group(0).split()))
    print("  permissions:")
    for perm in sorted(set(re.findall(r'android:name="(android\.permission\.[^"]+)"', text))):
        print("   -", perm)
    for attr in ("usesCleartextTraffic", "allowBackup", "debuggable", "extractNativeLibs", "name"):
        mm = re.search(r'android:%s="([^"]*)"' % attr, text)
        if mm:
            print(f"  application {attr} = {mm.group(1)}")
    # exported components
    export = re.findall(r'<(activity|service|receiver|provider)[^>]*android:exported="true"', text)
    print("  exported components:", export or "none")


def elf_align(data: bytes):
    """Return (bits, max p_align of PT_LOAD segments)."""
    if data[:4] != b"\x7fELF":
        return None, None
    is64 = data[4] == 2
    if is64:
        e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
        e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
        e_phnum = struct.unpack_from("<H", data, 0x38)[0]
        aligns = []
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            p_type = struct.unpack_from("<I", data, off)[0]
            if p_type == 1:  # PT_LOAD
                p_align = struct.unpack_from("<Q", data, off + 48)[0]
                aligns.append(p_align)
        return 64, max(aligns) if aligns else None
    e_phoff = struct.unpack_from("<I", data, 0x1C)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x2A)[0]
    e_phnum = struct.unpack_from("<H", data, 0x2C)[0]
    aligns = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        if p_type == 1:
            p_align = struct.unpack_from("<I", data, off + 28)[0]
            aligns.append(p_align)
    return 32, max(aligns) if aligns else None


def inspect_aab():
    print("\naab:", AAB.name, f"{AAB.stat().st_size / 1e6:.1f} MB")
    with zipfile.ZipFile(AAB) as z:
        names = z.namelist()
        libs = [n for n in names if "/lib/" in n and n.endswith(".so")]
        abis = sorted({n.split("/lib/")[1].split("/")[0] for n in libs})
        print("  ABIs:", ", ".join(abis) or "none")
        bad64 = []
        bad32 = []
        for lib in sorted(libs):
            info = z.getinfo(lib)
            data = z.read(lib)
            bits, align = elf_align(data)
            ok = align is not None and align >= 16384
            if not ok:
                (bad64 if bits == 64 else bad32).append((lib, align))
            page16 = "16KB OK" if ok else f"4KB ({align:#x})"
            print(f"   {lib.split('/lib/')[1]:52s} {bits}bit  {len(data)/1e6:6.2f} MB  {page16}  "
                  f"stored={info.compress_type and 'deflate' or 'store'}")

        # Only 64-bit ABIs are subject to Play's 16 KB page-size requirement;
        # 32-bit devices have 4 KB pages and are exempt.
        if bad64:
            print(f"\n  16 KB page-size: {len(bad64)} x 64-bit libs NOT compatible  <-- PLAY WILL REJECT")
            for lib, align in bad64:
                print("    !!", lib, hex(align or 0))
        else:
            print("\n  16 KB page-size: all 64-bit libs OK"
                  + (f" ({len(bad32)} 32-bit libs at 4 KB, exempt)" if bad32 else ""))
        # asset weight
        big = sorted(
            ((i.file_size, i.filename) for i in z.infolist() if i.file_size > 2_000_000),
            reverse=True,
        )[:8]
        print("\n  largest entries:")
        for size, name in big:
            print(f"   {size/1e6:7.2f} MB  {name}")
        return len(bad64)


if __name__ == "__main__":
    merged_manifest()
    if inspect_aab() != 0:
        sys.exit(1)
