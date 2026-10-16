"""M5.1 推送：Sharpen/ + AxisOut/ + BilateralFilter/ + Gamma/ + 全局文档 + OOC 脚本
（不推 synth_rpt/ 综合产物；按项目规则排除 *.vvp / *.vcd / *.txt）

走 GitHub REST Git Data API（blob -> tree -> commit -> ref），token 读自 mcp.json。
失败在任何一步中断都不会改远端 ref（commit/ref 更新在最后），可直接重跑。
"""
import base64, json, os, socket, time, urllib.request, urllib.error

# 强制 IPv4：本机到 GitHub 的 IPv6 路径不可达，urllib 若先试 AAAA 会每次干等超时
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
            wait = min(1 + attempt, 8)
            print(f"  retry {attempt+1}/10 after {type(e).__name__} (wait {wait}s)")
            time.sleep(wait)
    raise last


def collect(local_dir, remote_prefix):
    out = []
    for name in sorted(os.listdir(local_dir)):
        p = os.path.join(local_dir, name)
        if not os.path.isfile(p):
            continue
        if name.lower().endswith(EXCLUDE_EXT):
            continue
        out.append((remote_prefix + name, p))
    return out


base_commit = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")["object"]["sha"]
base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{base_commit}")["tree"]["sha"]
print("base_commit =", base_commit, flush=True)

targets = []
for d in ("Sharpen", "AxisOut", "BilateralFilter", "Gamma"):
    targets += collect(os.path.join(ROOT, d), d + "/")
for f in ("README.md", "AGENTS.md", "fifo行缓存与8级ISP链路实施计划.md", "synth_ooc_timing.tcl"):
    p = os.path.join(ROOT, f)
    if os.path.isfile(p):
        targets.append((f, p))
    else:
        print("!! missing:", f)
print("files to push =", len(targets), flush=True)

entries = []
for i, (rel, abspath) in enumerate(targets, 1):
    with open(abspath, "rb") as f:
        raw = f.read()
    blob = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
               {"content": base64.b64encode(raw).decode("ascii"), "encoding": "base64"})
    entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print(f"  [{i}/{len(targets)}] blob {rel} ({len(raw)} B)", flush=True)

new_tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees",
               {"base_tree": base_tree, "tree": entries})

msg = """feat(M5.1): 锐化(USM) + 出端 AXIS 适配 + 时序收敛；补推 Gamma(M4-3)

- Sharpen/: USM(3x3 高斯 0 乘法器 + 修正量"符号-幅值"两路) 核 LAT=2 + stage 窗口寄存器；
  三模式 TB 全 PASS(1536/1536、K64 1536/1536、真图 11536/11536)；Tenengrad +9.3%
- AxisOut/: 简流(RGB888) -> AXIS(tkeep=111 + tuser=帧首 + tlast=行末) + 弹性 FIFO；
  S2MM 契约逐条 PASS(fire 3072=收 3072、帧 16、行 192)
- BilateralFilter/: 核 LAT 3->6 拆流水（输出位级不变，TB 仍 0 误差）
- Gamma/ (M4-3 补推): 1024x8 LUT x3 副本 + 同步读 LAT=1；全表 1024 项 0 误差；亮度 +62.6%
- ★ 时序收敛（新增 synth_ooc_timing.tcl，VU19P @150MHz OOC 预检）：
  sharpen 35 级/-1.930ns -> 15 级/+2.583ns；denoise 40 级/-5.804ns -> 13 级/+2.145ns
  病因：行缓存 pad mux(组合) + 吃窗口的核 挤在同一拍；DSP 级联链(9 项加树 = 8 跳 ~5.5ns)
- 文档：两模块 README 新增「时序收敛实战」(含时序报告片段 + 面试问答)；
  全局 README / AGENTS / 实施计划同步（新增 RTL 铁律 + 交付前 OOC 预检流程）"""

new_commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                 {"message": msg, "tree": new_tree["sha"], "parents": [base_commit]})
api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/main",
    {"sha": new_commit["sha"], "force": False})
print("PUSHED ->", new_commit["sha"], flush=True)

chk = api("GET", f"/repos/{OWNER}/{REPO}/git/trees/{new_commit['sha']}?recursive=1")
paths = sorted(e["path"] for e in chk["tree"] if e["type"] == "blob")
print("=== remote check ===")
for pref in ("Sharpen/", "AxisOut/", "Gamma/", "BilateralFilter/"):
    sub = [p for p in paths if p.startswith(pref)]
    print(f"  {pref}: {len(sub)} files")
for f in ("README.md", "AGENTS.md", "fifo行缓存与8级ISP链路实施计划.md", "synth_ooc_timing.tcl"):
    print(f"  {f}: {'OK' if f in paths else 'MISSING'}")
print("total blobs =", len(paths))
