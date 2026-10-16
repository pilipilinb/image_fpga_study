#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 Qoder 的 Local History 恢复被清空的文件（取每个文件"最新且非空"的版本）。"""
import glob
import json
import os
import shutil
import time
import urllib.parse

HIST = os.path.expandvars(r'%APPDATA%\Qoder\User\History')
ROOT = r'd:\FPGA_proj\image_fpga_test'

TARGETS = [
    r'Demosaic\demosaic_bilinear.v', r'Demosaic\demosaic_mhc.v', r'Demosaic\top_demosaic.v',
    r'Demosaic\tb_demosaic.v', r'Demosaic\tb_nxn_n5.v', r'Demosaic\make_bayer.py',
    r'Demosaic\verify_demosaic.py', r'Demosaic\compare_versions.py', r'Demosaic\README.md',
    r'DPC\dpc_envelope.v', r'DPC\top_dpc.v', r'DPC\tb_dpc.v',
    r'DPC\make_dpc_data.py', r'DPC\verify_dpc.py', r'DPC\README.md',
]
want = {os.path.normcase(os.path.normpath(os.path.join(ROOT, t))): os.path.join(ROOT, t)
        for t in TARGETS}

found = {}
for ent in glob.glob(os.path.join(HIST, '*', 'entries.json')):
    try:
        meta = json.load(open(ent, encoding='utf-8'))
    except Exception:
        continue
    res = meta.get('resource', '')
    if not res.startswith('file:'):
        continue
    p = urllib.parse.unquote(res[5:]).lstrip('/')      # file:///d%3A/... → d:/...
    p = p.replace('/', os.sep)
    key = os.path.normcase(os.path.normpath(p))
    if key not in want:
        continue
    best = None
    for e in meta.get('entries', []):
        fp = os.path.join(os.path.dirname(ent), e.get('id', ''))
        if not os.path.exists(fp):
            continue
        sz = os.path.getsize(fp)
        if sz == 0:
            continue
        ts = e.get('timestamp', 0)
        if best is None or ts > best['ts']:
            best = {'ts': ts, 'fp': fp, 'sz': sz, 'id': e.get('id'),
                    'src': e.get('source', '-')}
    if best:
        found[key] = best

print('=== 恢复清单（按最新非空版本）===')
ok, miss = 0, []
for key, dst in want.items():
    b = found.get(key)
    if not b:
        miss.append(dst)
        print(f'[缺] {os.path.relpath(dst, ROOT)}')
        continue
    tstr = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(b['ts'] / 1000))
    shutil.copyfile(b['fp'], dst)
    ok += 1
    print(f'[恢复] {os.path.relpath(dst, ROOT):38s} {b["sz"]:>6d}B  版本={b["id"]:12s} '
          f'时间={tstr} 来源={b["src"]}')

print(f'\n共恢复 {ok}/{len(want)} 个文件')
if miss:
    print('未在 History 中找到：')
    for m in miss:
        print('  ', os.path.relpath(m, ROOT))