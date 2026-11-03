#!/usr/bin/env bash
#
# Dump the camera's raw API answers so the APP and firmware sides can settle
# protocol questions with data instead of discussion.
#
# Run it from a machine that is joined to the camera's Wi-Fi hotspot
# (SSID "ZIVIGo", password zivi2025). Nothing is uploaded anywhere.
#
#   ./scripts/capture_camera_api.sh              # defaults to 192.168.5.1
#   ./scripts/capture_camera_api.sh 192.168.5.1  # explicit host
#
# What it answers:
#   * /list ordering (ascending vs descending) — decides how the album pages
#   * total semantics and the limit cap
#   * clock_synced before/after /rtc, boot_id stability, hwclock_ok meaning
#   * mtime backfill after the first /rtc of a boot
#
set -u

HOST="${1:-192.168.5.1}"
BASE="http://${HOST}"
OUT="camera_api_capture_$(date +%Y%m%d_%H%M%S).txt"

say() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*" | tee -a "$OUT"; }
raw() { printf '\n--- %s ---\n' "$1" | tee -a "$OUT"; shift; "$@" 2>&1 | tee -a "$OUT"; }

echo "Camera API capture — $(date)" | tee "$OUT"
echo "Target: $BASE" | tee -a "$OUT"

# ---------------------------------------------------------------- reachability
say "reachability"
if ! curl -s -m 3 -o /dev/null "$BASE/info"; then
  echo "Cannot reach $BASE — is this machine on the camera's hotspot (SSID ZIVIGo)?" | tee -a "$OUT"
  exit 1
fi
echo "ok" | tee -a "$OUT"

# --------------------------------------------------------------------- /info
say "GET /info (before any /rtc)"
curl -s -m 5 "$BASE/info" | tee -a "$OUT"

# --------------------------------------------------------------------- /list
say "GET /list?offset=0&limit=4 — ORDER CHECK"
curl -s -m 5 "$BASE/list?offset=0&limit=4" | tee -a "$OUT"

say "GET /list?offset=0&limit=1 — total semantics"
curl -s -m 5 "$BASE/list?offset=0&limit=1" | tee -a "$OUT"

say "GET /list?offset=0&limit=200 — limit clamp (firmware: >50 falls back to 20, NOT 50)"
curl -s -m 5 -w '\nHTTP %{http_code}\n' "$BASE/list?offset=0&limit=200" | tee -a "$OUT"

# ---------------------------------------------------------------------- /rtc
NOW=$(date +%s)
say "POST /rtc timestamp=$NOW"
curl -s -m 5 -X POST -H 'Content-Type: application/json' \
  -d "{\"timestamp\":$NOW}" "$BASE/rtc" | tee -a "$OUT"

say "GET /info (after /rtc — clock_synced should now be true)"
curl -s -m 5 "$BASE/info" | tee -a "$OUT"

# ----------------------------------------------------- machine-readable verdict
say "SUMMARY"
python3 - "$OUT" <<'PY' 2>/dev/null || echo "(python3 not available — read the raw output above)"
import json, re, sys, subprocess

text = open(sys.argv[1], encoding='utf-8', errors='replace').read()

def section(name):
    m = re.search(r'== ' + re.escape(name) + r' ==\n(.*?)(?=\n== |\Z)', text, re.S)
    return m.group(1) if m else ''

def first_json(block):
    start = block.find('{')
    if start < 0:
        return None
    depth = 0
    for i, ch in enumerate(block[start:], start):
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(block[start:i+1])
                except Exception:
                    return None
    return None

order_block = section('GET /list?offset=0&limit=4 — ORDER CHECK')
lst = first_json(order_block)
if lst and lst.get('files'):
    names = [f['name'] for f in lst['files']]
    key = lambda n: n.split('_', 1)[1] if '_' in n else n
    asc = all(key(names[i]) < key(names[i+1]) for i in range(len(names)-1))
    desc = all(key(names[i]) > key(names[i+1]) for i in range(len(names)-1))
    verdict = 'ASCENDING (oldest first)' if asc else ('DESCENDING (newest first)' if desc else 'MIXED / unclear')
    print(f'  /list order      : {verdict}')
    print(f'  first names      : {names[:4]}')
    print(f'  total            : {lst.get("total")}')
    print(f'  boot_id          : {lst.get("boot_id")}')
else:
    print('  /list            : could not parse (see raw output)')

info_before = first_json(section('GET /info (before any /rtc)'))
info_after = first_json(section('GET /info (after /rtc — clock_synced should now be true)'))
rtc = first_json(section(f'POST /rtc timestamp={NOW}')) or first_json(section('POST /rtc'))
if info_before:
    print(f'  clock_synced     : before={info_before.get("clock_synced")}', end='')
    if info_after:
        print(f' after={info_after.get("clock_synced")}  (must flip false -> true)')
    else:
        print()
    print(f'  clock_source     : {info_before.get("clock_source")}')
if rtc:
    print(f'  /rtc delta       : {rtc.get("delta")}s   mtime_fixed={rtc.get("mtime_fixed")}')
    print(f'  /rtc hwclock_ok  : {rtc.get("hwclock_ok")}  (false is normal: no RTC battery)')
    print(f'  /rtc boot_id     : {rtc.get("boot_id")}')
print()
print('  -> Attach this file to the APP/firmware sync thread.')
PY

printf '\nSaved to %s\n' "$OUT"
