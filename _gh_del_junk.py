"""删除远程历史推送产生的损坏文件名副本 BLC/BLC???????.md
（'?' 为 Windows 非法文件名字符，会让 git checkout/reset 报 make_cache_entry failed；
 真文件 BLC/BLC黑电平校正实现.md 保留不动。）"""
import json, os, socket, time, urllib.request, urllib.error

_gai = socket.getaddrinfo
def _gai_v4(host, port, family=0, type=0, proto=0, flags=0):
    return _gai(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _gai_v4

OWNER, REPO = "pilipilinb", "image_fpga_study"
MCP = os.path.join(os.environ["APPDATA"], "Trae CN", "User", "mcp.json")
with open(MCP, "r", encoding="utf-8") as f:
    TOKEN = json.load(f)["mcpServers"]["GitHub"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]
API = "https://api.github.com"
JUNK = "BLC/BLC???????.md"


def api(method, path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    last = None
    for attempt in range(10):
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + TOKEN)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("User-Agent", "trae-push")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            print("HTTP", e.code, method, path)
            print(e.read().decode("utf-8", "replace"))
            raise
        except Exception as e:
            last = e
            time.sleep(min(1 + attempt, 8))
    raise last


base_commit = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")["object"]["sha"]
base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{base_commit}")["tree"]["sha"]
print("base_commit =", base_commit, flush=True)

# sha=null + base_tree => 从树上删除该条目
new_tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees",
               {"base_tree": base_tree, "tree": [{"path": JUNK, "mode": "100644",
                                                  "type": "blob", "sha": None}]})

msg = ("chore: 删除历史推送产生的损坏文件名副本 BLC/BLC???????.md\n\n"
       "该文件名含字面 '?'（Windows 非法字符），会导致 git checkout/reset 报\n"
       "`make_cache_entry failed`，阻塞本地仓库与远程同步。\n"
       "真文件 BLC/BLC黑电平校正实现.md 内容完整、原样保留。")
new_commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                 {"message": msg, "tree": new_tree["sha"], "parents": [base_commit]})
api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/main",
    {"sha": new_commit["sha"], "force": False})
print("DELETED, new head =", new_commit["sha"], flush=True)

chk = api("GET", f"/repos/{OWNER}/{REPO}/git/trees/{new_commit['sha']}?recursive=1")
paths = [e["path"] for e in chk["tree"] if e["type"] == "blob"]
bad = [p for p in paths if "?" in p]
print("剩余含 '?' 的路径数 =", len(bad))
print("BLC/ 下文件数 =", len([p for p in paths if p.startswith("BLC/")]))
print("total blobs =", len(paths))
