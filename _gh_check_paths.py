import json, os, socket, urllib.request

_gai = socket.getaddrinfo
def _gai_v4(host, port, family=0, type=0, proto=0, flags=0):
    return _gai(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _gai_v4

OWNER, REPO = "pilipilinb", "image_fpga_study"
MCP = os.path.join(os.environ["APPDATA"], "Trae CN", "User", "mcp.json")
with open(MCP, "r", encoding="utf-8") as f:
    TOKEN = json.load(f)["mcpServers"]["GitHub"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]

req = urllib.request.Request(f"https://api.github.com/repos/{OWNER}/{REPO}/git/trees/main?recursive=1", method="GET")
req.add_header("Authorization", "Bearer " + TOKEN)
req.add_header("Accept", "application/vnd.github+json")
req.add_header("User-Agent", "trae-check")
with urllib.request.urlopen(req, timeout=30) as r:
    tree = json.loads(r.read().decode("utf-8"))["tree"]

paths = sorted(e["path"] for e in tree if e["type"] == "blob")

# 用 ascii() 转义：非 ASCII 字符会显示成 \uXXXX，真正的 '?' 仍是 '?'
out = []
out.append("=== 含非 ASCII 或可疑字符的路径（ascii 转义）===")
for p in paths:
    if any(ord(c) > 127 for c in p) or "?" in p:
        out.append("  " + ascii(p))
out.append("")
out.append("=== 路径中确实含字面 '?' 的（这会阻塞 Windows git）===")
bad = [p for p in paths if "?" in p]
out.append(f"  count = {len(bad)}")
for p in bad:
    out.append("  " + ascii(p))
out.append("")
out.append("=== BLC/ 全部路径 ===")
for p in paths:
    if p.startswith("BLC/"):
        out.append("  " + ascii(p))
out.append("")
out.append(f"total blobs = {len(paths)}")

with open("_remote_paths.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
print("written _remote_paths.txt")
