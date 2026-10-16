import json, os, socket, urllib.request

_gai = socket.getaddrinfo
def _gai_v4(host, port, family=0, type=0, proto=0, flags=0):
    return _gai(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _gai_v4

OWNER, REPO = "pilipilinb", "image_fpga_study"
MCP = os.path.join(os.environ["APPDATA"], "Trae CN", "User", "mcp.json")
with open(MCP, "r", encoding="utf-8") as f:
    TOKEN = json.load(f)["mcpServers"]["GitHub"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]
API = "https://api.github.com"


def api(method, path):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "trae-push")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


head = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")["object"]["sha"]
print("remote main HEAD =", head)
tree = api("GET", f"/repos/{OWNER}/{REPO}/git/trees/{head}?recursive=1")["tree"]
paths = sorted(e["path"] for e in tree if e["type"] == "blob")
print("total blobs =", len(paths))
import collections
tops = collections.Counter(p.split("/")[0] for p in paths)
print("--- top-level ---")
for k, v in sorted(tops.items()):
    print(f"  {k}: {v}")
print("--- root files ---")
for p in paths:
    if "/" not in p:
        print("  ", p)
for pref in ("Sharpen/", "AxisOut/", "Gamma/", "BilateralFilter/", "CCM/", "BLC/"):
    sub = [p for p in paths if p.startswith(pref)]
    print(f"--- {pref} ({len(sub)}) ---")
    for p in sub:
        print("  ", p)
