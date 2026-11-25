import json, sys, urllib.request, urllib.error, os
sys.path.insert(0, '/opt/muse/skills/custom-connector-setup/bin')
from dynamic_credentials import add_surrogate_to_request

RUN_ID = '45600838987'
API = 'https://api.github.com/repos/nvd29u1/NVDAppleIDDownload'
OUT = '/home/hatch/workspace/nvd-appleid-download/hidden_files/build15-artifact.zip'

def api_get(url):
    req = urllib.request.Request(url)
    add_surrogate_to_request(req, 'custom.github', allowed_hosts=['api.github.com'])
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

data = api_get(API + f'/actions/runs/{RUN_ID}/artifacts')
arts = data.get('artifacts', [])
print([(a['id'], a['name'], a['size_in_bytes'], a['expired']) for a in arts])
art = next(a for a in arts if a['name'] == 'NVDAppleIDDownload.ipa')
print('artifact', art['id'], 'size', art['size_in_bytes'])

# Redirect-capture: GitHub answers 302 to a pre-signed blob URL; fetch the
# Location with NO auth header (gh.py refuses redirects).
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

opener = urllib.request.build_opener(NoRedirect)
req = urllib.request.Request(API + f"/actions/artifacts/{art['id']}/zip")
add_surrogate_to_request(req, 'custom.github', allowed_hosts=['api.github.com'])
try:
    with opener.open(req, timeout=60) as r:
        print('unexpected status', r.status)
        sys.exit(1)
except urllib.error.HTTPError as e:
    if e.code in (301, 302, 303, 307, 308):
        loc = e.headers.get('Location')
        print('redirect to', loc[:80])
        with urllib.request.urlopen(loc, timeout=300) as r2:
            body = r2.read()
        open(OUT, 'wb').write(body)
        print('saved', OUT, len(body), 'bytes')
    else:
        print('HTTP', e.code, e.read()[:200]); sys.exit(1)
