import json, sys, urllib.request, urllib.error
sys.path.insert(0, '/opt/muse/skills/custom-connector-setup/bin')
from dynamic_credentials import add_surrogate_to_request

# Dispatch workflow "Build App" (build.yml) on main, then poll for the run
# on head e5fd260c (2.0 build 15).
TARGET = 'e5fd260cab2fc958ce89390b0b30fde81b814a97'
API = 'https://api.github.com/repos/nvd29u1/NVDAppleIDDownload'

def call(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data:
        req.add_header('Content-Type', 'application/json')
    add_surrogate_to_request(req, 'custom.github', allowed_hosts=['api.github.com'])
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r) if r.headers.get_content_type() == 'application/json' else {}
    except urllib.error.HTTPError as e:
        print('HTTP', e.code, e.read()[:300].decode('utf-8', 'replace'))
        raise

if len(sys.argv) > 1 and sys.argv[1] == 'dispatch':
    status, _ = call('POST', API + '/actions/workflows/build.yml/dispatches', {'ref': 'main'})
    print('dispatch status', status)
    sys.exit(0)

import time
for attempt in range(60):
    _, data = call('GET', API + '/actions/runs?per_page=10')
    runs = data.get('workflow_runs', [])
    match = [x for x in runs if x['head_sha'].startswith(TARGET[:8])]
    if match:
        run = match[0]
        print(f"attempt {attempt}: run {run['id']} status={run['status']} conclusion={run['conclusion']}", flush=True)
        if run['status'] == 'completed':
            print('RUN_ID', run['id'])
            print('CONCLUSION', run['conclusion'])
            print('URL', run['html_url'])
            sys.exit(0 if run['conclusion'] == 'success' else 2)
    else:
        latest = runs[0] if runs else None
        print(f"attempt {attempt}: no run for target yet; latest head={latest['head_sha'][:8] if latest else 'none'} status={latest['status'] if latest else 'none'}", flush=True)
    time.sleep(30)
print('TIMEOUT waiting for run')
sys.exit(3)
