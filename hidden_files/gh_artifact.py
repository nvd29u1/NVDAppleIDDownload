import sys
sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request
import urllib.request

API = "https://api.github.com"
HEADERS = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "NVD-1506"}

artifact_id, out = sys.argv[1], sys.argv[2]
req = urllib.request.Request(f"{API}/repos/nvd29u1/NVDAppleIDDownload/actions/artifacts/{artifact_id}/zip", headers=dict(HEADERS), method="GET")
add_surrogate_to_request(req, "custom.github", allowed_hosts=["api.github.com"])
# Default opener follows the 302 to the signed blob URL (auth header is
# stripped on cross-host redirect, which is correct: the blob URL is signed).
with urllib.request.urlopen(req, timeout=120) as resp:
    print("status", resp.status, "url", resp.geturl()[:100])
    total = 0
    with open(out, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            total += len(chunk)
    print("downloaded bytes", total)
