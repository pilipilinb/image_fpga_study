"""REST 兜底推送 —— 当 github.com:443 的 TLS 被阻断、`git push` 连不上时使用。

用法：
    python _gh_push_files.py <提交信息文件> <文件1> [文件2 ...]

- 文件路径用**相对仓库根**的路径（如 `AGENTS.md`、`Sharpen/README.md`）
- 提交建立在本仓库 `origin/main` 的**当前** HEAD 之上（脚本自己查远端，不依赖本地 git）
- 走 api.github.com 的 Git Data API（本机实测稳定；github.com 会 TLS 超时）
- 任一步失败都**不会改远端 ref**（commit/ref 更新放在最后），可直接重跑

注意：REST 产生的提交与本地同名提交**内容相同、SHA 不同**。
网络恢复后对齐本地：`git fetch` + `git reset --mixed origin/main`。
"""
import base64, hashlib, json, os, socket, sys, time, urllib.request, urllib.error

# 强制 IPv4（本机到 GitHub 的 IPv6 路径不可达）
_gai = socket.getaddrinfo
def _gai_v4(host, port, family=0, type=0, proto=0, flags=0):
    return _gai(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _gai_v4

OWNER, REPO = "pilipilinb", "image_fpga_study"
BRANCH = "main"
ROOT = r"d:\FPGA_proj\image_fpga_test"
API = "https://api.github.com"
MCP = os.path.join(os.environ["APPDATA"], "Trae CN", "User", "mcp.json")

with open(MCP, "r", encoding="utf-8") as f:
    TOKEN = json.load(f)["mcpServers"]["GitHub"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]


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
            print(f"  retry {attempt+1}/10 after {type(e).__name__}")
            time.sleep(min(1 + attempt, 8))
    raise last


def git_blob_sha(raw):
    """本地算 git blob SHA：sha1('blob <len>\\0' + content)，用于校验上传内容一致"""
    return hashlib.sha1(b"blob %d\x00" % len(raw) + raw).hexdigest()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    msgfile, rels = sys.argv[1], sys.argv[2:]

    with open(os.path.join(ROOT, msgfile), "r", encoding="utf-8") as f:
        msg = f.read().rstrip("\n")

    base_commit = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
    base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{base_commit}")["tree"]["sha"]
    print(f"remote {BRANCH} HEAD = {base_commit}")

    entries = []
    for rel in rels:
        p = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.isfile(p):
            print("!! 文件不存在:", rel)
            return 3
        with open(p, "rb") as f:
            raw = f.read()
        local_sha = git_blob_sha(raw)
        blob = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
                   {"content": base64.b64encode(raw).decode("ascii"), "encoding": "base64"})
        ok = "OK" if blob["sha"] == local_sha else "SHA-MISMATCH"
        print(f"  blob {rel}  {len(raw)} B  local={local_sha[:8]} remote={blob['sha'][:8]}  [{ok}]")
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})

    new_tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees",
                   {"base_tree": base_tree, "tree": entries})
    new_commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                     {"message": msg, "tree": new_tree["sha"], "parents": [base_commit]})
    api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": new_commit["sha"], "force": False})
    print("PUSHED ->", new_commit["sha"])

    chk = api("GET", f"/repos/{OWNER}/{REPO}/git/trees/{new_commit['sha']}?recursive=1")
    got = {e["path"]: e["sha"] for e in chk["tree"] if e["type"] == "blob"}
    for rel, abspath in zip(rels, [os.path.join(ROOT, r.replace("/", os.sep)) for r in rels]):
        with open(abspath, "rb") as f:
            raw = f.read()
        print(f"  verify {rel}: {'OK' if got.get(rel) == git_blob_sha(raw) else 'MISMATCH'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
