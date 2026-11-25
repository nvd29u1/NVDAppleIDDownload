import json, sys, urllib.request, urllib.error
sys.path.insert(0, '/opt/muse/skills/custom-connector-setup/bin')
from dynamic_credentials import add_surrogate_to_request

# Poll workflow "Build App" (build.yml) on main for head 3020d89c (2.0 build 16).
# Filter by workflow NAME too (build 15 lesson: head-only match grabbed the
# wrong run "Store download checks" sharing the same head SHA).
TARGET = '3020d89c256454aa473e1060087d52902bc1eba8'
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

import time
for attempt in range(100):
    _, data = call('GET', API + '/actions/runs?per_page=20')
    runs = data.get('workflow_runs', [])
    match = [x for x in runs if x['head_sha'].startswith(TARGET[:8]) and x.get('name') == 'Build App']
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
        print(f"attempt {attempt}: no Build App run for target yet; latest head={latest['head_sha'][:8] if latest else 'none'} name={latest['name'] if latest else 'none'} status={latest['status'] if latest else 'none'}", flush=True)
    time.sleep(30)
print('TIMEOUT waiting for run')
sys.exit(3)
