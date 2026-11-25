import sys
sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request
import urllib.request, urllib.error

API = "https://api.github.com"
HEADERS = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "NVD-1506"}

class NoFollow(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # -> urlopen raises HTTPError with Location in headers

artifact_id, out = sys.argv[1], sys.argv[2]
req = urllib.request.Request(f"{API}/repos/nvd29u1/NVDAppleIDDownload/actions/artifacts/{artifact_id}/zip", headers=dict(HEADERS), method="GET")
add_surrogate_to_request(req, "custom.github", allowed_hosts=["api.github.com"])
opener = urllib.request.build_opener(NoFollow())
loc = None
try:
    with opener.open(req, timeout=60) as resp:
        print("unexpected direct status", resp.status); sys.exit(3)
except urllib.error.HTTPError as e:
    print("api status", e.code)
    loc = e.headers.get("Location")
if not loc:
    print("no Location header"); sys.exit(4)
print("blob host:", loc.split("/")[2])
with urllib.request.urlopen(loc, timeout=120) as resp:
    print("blob status", resp.status, "len", resp.headers.get("Content-Length"))
    total = 0
    with open(out, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            total += len(chunk)
            print("...", total, flush=True)
    print("downloaded bytes", total)
