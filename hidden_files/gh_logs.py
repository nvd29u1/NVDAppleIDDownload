import sys
sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request
import urllib.request, urllib.error

API = "https://api.github.com"
HEADERS = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "NVD-1506"}

job_id, out = sys.argv[1], sys.argv[2]
req = urllib.request.Request(f"{API}/repos/nvd29u1/NVDAppleIDDownload/actions/jobs/{job_id}/logs", headers=dict(HEADERS), method="GET")
add_surrogate_to_request(req, "custom.github", allowed_hosts=["api.github.com"])
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        print("api status", resp.status)
        data = resp.read()
        open(out, "wb").write(data)
        print("direct bytes", len(data))
except urllib.error.HTTPError as e:
    print("http status", e.code)
    loc = e.headers.get("Location")
    if loc:
        print("redirect to", loc[:100])
        with urllib.request.urlopen(loc, timeout=180) as r:
            data = r.read()
            print("fetched bytes", len(data))
            open(out, "wb").write(data)
    else:
        print(e.read()[:500])
        raise
