import base64, json, os, subprocess, sys, urllib.request, urllib.error

REPO = os.environ.get("REPO", "woxinxiangyang/p660-bcmdhd")
TOKEN = os.environ["GH_TOKEN"]
CWD = os.environ.get("REPO_DIR", ".")


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=CWD)
    if r.returncode != 0:
        print("CMD FAIL:", cmd)
        print(r.stderr[:300])
        sys.exit(1)
    return r.stdout


def api(method, path, data=None):
    url = "https://api.github.com" + path
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "p660-ci")
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        print("API ERROR", e.code, method, path)
        print(e.read().decode()[:400])
        sys.exit(1)
    except Exception as e:
        print("NETWORK ERROR", method, path, type(e).__name__, str(e)[:200])
        sys.exit(2)


ref = api("GET", "/repos/%s/git/ref/heads/main" % REPO)
remote_sha = ref["object"]["sha"]
commit = api("GET", "/repos/%s/git/commits/%s" % (REPO, remote_sha))
base_tree = commit["tree"]["sha"]
print("remote head:", remote_sha[:8], "| base_tree:", base_tree[:8])

local_head = sh("git rev-parse HEAD").strip()
print("local  head:", local_head[:8])

BASE = os.environ.get("BASE") or remote_sha
diff = sh("git diff --name-status %s %s" % (BASE, local_head))
changes = []
for line in diff.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    changes.append((parts[0].strip(), parts[-1].strip()))
print("files to push:", len(changes))

entries = []
for i, (status, path) in enumerate(changes, 1):
    if status.startswith("D"):
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
        print("  [%d/%d] delete %s" % (i, len(changes), path))
        continue
    full = os.path.join(CWD, path)
    with open(full, "rb") as f:
        content = f.read()
    b64 = base64.b64encode(content).decode()
    blob = api("POST", "/repos/%s/git/blobs" % REPO, {"content": b64, "encoding": "base64"})
    entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print("  [%d/%d] blob %s (%d bytes)" % (i, len(changes), path, len(content)))

tree = api("POST", "/repos/%s/git/trees" % REPO, {"base_tree": base_tree, "tree": entries})
print("tree:", tree["sha"][:8], "entries:", len(tree["tree"]))

msg = sh("git log -1 --pretty=%B").strip()
new_commit = api("POST", "/repos/%s/git/commits" % REPO,
                 {"message": msg, "tree": tree["sha"], "parents": [remote_sha]})
print("commit:", new_commit["sha"][:8])

api("PATCH", "/repos/%s/git/refs/heads/main" % REPO, {"sha": new_commit["sha"], "force": False})
print("PUSHED OK:", new_commit["sha"])
