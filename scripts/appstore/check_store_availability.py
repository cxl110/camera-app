import json
import urllib.request

APP_ID = "6827651876"

for cc in ["au", "us", "gb", "jp", "hk", "tw", "mo", "nz", "ca", "cn"]:
    url = "https://itunes.apple.com/lookup?id=%s&country=%s" % (APP_ID, cc)
    try:
        with urllib.request.urlopen(url, timeout=25) as r:
            data = json.load(r)
    except Exception as exc:  # noqa: BLE001
        print("%-3s ERROR %s" % (cc, exc))
        continue
    count = data.get("resultCount", 0)
    if not count:
        print("%-3s resultCount=0  (not in this storefront)" % cc)
        continue
    a = data["results"][0]
    print("%-3s OK  name=%s" % (cc, a.get("trackName")))
    print("      version=%s  price=%s  genre=%s  released=%s"
          % (a.get("version"), a.get("formattedPrice"),
             a.get("primaryGenreName"), a.get("currentVersionReleaseDate")))
    print("      url=%s" % a.get("trackViewUrl"))
