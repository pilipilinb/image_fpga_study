#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""临时恢复脚本：从会话 transcript 里重放工具调用，恢复被清空的文件。
用法：
  python _restore_check.py          # 干跑：只报告能找到多少操作、最终内容长度
  python _restore_check.py --apply  # 实际写盘
"""
import json
import os
import sys

TRANS = r"C:\Users\jingxuanli\.qoder\cache\projects\image_fpga_test-88a59f9\conversation-history\79c791a2\79c791a2.jsonl"

ROOT = r"d:\FPGA_proj\image_fpga_test"
TARGETS = [
    r"Demosaic\demosaic_bilinear.v",
    r"Demosaic\demosaic_mhc.v",
    r"Demosaic\top_demosaic.v",
    r"Demosaic\tb_demosaic.v",
    r"Demosaic\tb_nxn_n5.v",
    r"Demosaic\make_bayer.py",
    r"Demosaic\verify_demosaic.py",
    r"Demosaic\compare_versions.py",
    r"Demosaic\README.md",
    r"DPC\dpc_envelope.v",
    r"DPC\top_dpc.v",
    r"DPC\tb_dpc.v",
    r"DPC\make_dpc_data.py",
    r"DPC\verify_dpc.py",
    r"DPC\README.md",
]

WRITE_NAMES = {'Write', 'write_file', 'CreateFile', 'create_file', 'createFile'}
REPLACE_NAMES = {'SearchReplace', 'search_replace', 'EditFile', 'edit_file',
                 'ReplaceString', 'replace_string_in_file', 'replace_in_file'}


def norm(p):
    return os.path.normcase(os.path.normpath(p))


def walk(obj, ops):
    if isinstance(obj, dict):
        if obj.get('type') == 'tool_use':
            ops.append((obj.get('name'), obj.get('input') or {}))
        for v in obj.values():
            walk(v, ops)
    elif isinstance(obj, list):
        for v in obj:
            walk(v, ops)


def main():
    apply = ('--apply' in sys.argv)
    if not os.path.exists(TRANS):
        print('ERROR: transcript 不存在:', TRANS)
        return

    target_keys = {}
    for t in TARGETS:
        target_keys[norm(os.path.join(ROOT, t))] = os.path.join(ROOT, t)

    ops = []
    n_lines = 0
    with open(TRANS, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            n_lines += 1
            try:
                obj = json.loads(line)
            except Exception:
                continue
            walk(obj, ops)

    print(f'transcript 行数 {n_lines}，解析出工具调用 {len(ops)} 个')

    content = {}       # key -> str
    stat = {}          # key -> [写入次数, 替换次数, 替换失败次数]
    order = []
    for name, args in ops:
        p = args.get('file_path') or args.get('path')
        if not p:
            continue
        key = norm(p)
        if key not in target_keys:
            continue
        if key not in stat:
            stat[key] = [0, 0, 0]
            order.append(key)
        if name in WRITE_NAMES:
            fc = args.get('file_content')
            if fc is None:
                fc = args.get('content') or ''
            content[key] = fc
            stat[key][0] += 1
        elif name in REPLACE_NAMES:
            cur = content.get(key, '')
            reps = args.get('replacements') or []
            if not reps:
                o = args.get('original_text')
                n = args.get('new_text')
                if o is not None and n is not None:
                    reps = [{'original_text': o, 'new_text': n,
                             'replace_all': args.get('replace_all', False)}]
            for r in reps:
                o = r.get('original_text', '')
                n = r.get('new_text', '')
                if o and o in cur:
                    cur = cur.replace(o, n, 1) if not r.get('replace_all') else cur.replace(o, n)
                    stat[key][1] += 1
                else:
                    stat[key][2] += 1
            content[key] = cur

    print('\n=== 恢复情况 ===')
    bad = []
    for key in order:
        path = target_keys[key]
        txt = content.get(key, '')
        w, rp, rf = stat[key]
        flag = '' if (len(txt) > 0 and rf == 0) else '  <== 注意'
        print(f'{os.path.relpath(path, ROOT):40s} 写入{w}次 替换{rp}次 失败{rf}次 最终{len(txt)}字节{flag}')
        if len(txt) == 0 or rf > 0:
            bad.append(key)

    missing = [t for t in TARGETS if norm(os.path.join(ROOT, t)) not in content]
    if missing:
        print('\n未找到任何操作的文件：')
        for m in missing:
            print('  ', m)

    if apply:
        print('\n=== 写盘 ===')
        for key in order:
            path = target_keys[key]
            txt = content.get(key, '')
            if not txt:
                print('跳过（内容为空）:', os.path.relpath(path, ROOT))
                continue
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.write(txt)
            print('已恢复:', os.path.relpath(path, ROOT), len(txt), '字节')
    else:
        print('\n（干跑模式，未写盘；加 --apply 执行恢复）')


if __name__ == '__main__':
    main()