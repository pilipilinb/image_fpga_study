import base64, json, os, socket, time, urllib.request, urllib.error

# ★ 强制 IPv4：本机到 GitHub 的 IPv6 路径不可达，urllib 若先试 AAAA 会每次干等超时
_gai = socket.getaddrinfo
def _gai_v4(host, port, family=0, type=0, proto=0, flags=0):
    return _gai(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _gai_v4

OWNER, REPO = "pilipilinb", "image_fpga_study"
ROOT = r"d:\FPGA_proj\image_fpga_test"
MCP = os.path.join(os.environ["APPDATA"], "Trae CN", "User", "mcp.json")

with open(MCP, "r", encoding="utf-8") as f:
    TOKEN = json.load(f)["mcpServers"]["GitHub"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]
API = "https://api.github.com"
EXCLUDE_EXT = (".vvp", ".vcd", ".txt")


def api(method, path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    last = None
    for attempt in range(14):
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
            wait = min(2 + 2 * attempt, 15)      # 2,4,6,...15s
            print(f"  retry {attempt+1}/14 after {type(e).__name__} (wait {wait}s)")
            time.sleep(wait)
    raise last


def collect(local_dir, remote_prefix):
    out = []
    for name in sorted(os.listdir(local_dir)):
        p = os.path.join(local_dir, name)
        if not os.path.isfile(p):
            continue
        if name.lower().endswith(EXCLUDE_EXT):
            print("  skip:", name)
            continue
        out.append((remote_prefix + name, p))
    return out


base_commit = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")["object"]["sha"]
base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{base_commit}")["tree"]["sha"]
print("base_commit =", base_commit)

targets = collect(os.path.join(ROOT, "Gamma"), "Gamma/")
for d in ("README.md", "AGENTS.md", "fifo行缓存与8级ISP链路实施计划.md"):
    p = os.path.join(ROOT, d)
    if os.path.isfile(p):
        targets.append((d, p))
    else:
        print("!! missing:", d)

entries = []
for rel, abspath in targets:
    with open(abspath, "rb") as f:
        raw = f.read()
    blob = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
               {"content": base64.b64encode(raw).decode("ascii"), "encoding": "base64"})
    entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print(f"blob {rel}  ({len(raw)} bytes)")

new_tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees",
               {"base_tree": base_tree, "tree": entries})
msg = ("feat(M4-3): Gamma 伽马校正（10bit→RGB888，全链位宽缩减出口）+ M4 收官\n\n"
       "- Gamma/: 1024x8 LUT x3 并行副本 + 同步读 LAT=1；等延迟 bypass（线性 10-8）\n"
       "- 伪代码核对 3 改 1 补强（资源估算纠错 / 三通道三读口 / 10bit 地址 / 单调性穷举）\n"
       "- 穷举 RAMP TB（查表+bypass 两轮 2048）+ 真图 TB（M3->CCM->Gamma 三级）全 PASS\n"
       "- 全表 1024 项 0 误差 + 单调/端点 + bypass 穷举 1024 项 0 误差；亮度 +62.6%\n"
       "- 修 bypass 缺饱和 bug（v=1022/1023 回绕成黑，TB 期望同表达式导致漏检）\n"
       "- 同步 README/AGENTS/实施计划（M4 标记完成）")
new_commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                 {"message": msg, "tree": new_tree["sha"], "parents": [base_commit]})
api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/main",
    {"sha": new_commit["sha"], "force": False})
print("PUSHED ->", new_commit["sha"])

chk = api("GET", f"/repos/{OWNER}/{REPO}/git/trees/{new_commit['sha']}?recursive=1")
print("=== Gamma/ on remote ===")
for e in chk["tree"]:
    if e["path"].startswith("Gamma/"):
        print("  ", e["path"])
