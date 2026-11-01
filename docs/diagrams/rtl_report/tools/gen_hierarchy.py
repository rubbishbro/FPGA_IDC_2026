#!/usr/bin/env python3
"""Generate instance-hierarchy DOT files from the RTL sources.

env: HIER_ROOT (module), HIER_DEPTH (max depth), HIER_OUT (path)
"""
import os, re, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from hierarchy import modules

ROOT = os.environ.get('HIER_ROOT', 'instrument_board_top')
MAXDEPTH = int(os.environ.get('HIER_DEPTH', '99'))

# 相对根节点的路径 -> 允许再下钻的层数（不写=只受 MAXDEPTH 限制）
LIMITS = {
    'u_clocks': 0, 'u_system/u_pad': 0, 'u_system/u_pad_leds': 0,
    'u_system/u_comm': 0, 'u_system/u_ui': 0, 'u_system/u_fft_chain': 0,
    'u_system/u_sound/u_voice': 0, 'u_system/u_sound/u_audio': 0,
}
CLUSTERS = [
    ('u_clocks',                 'clock', '时钟与复位 · 50MHz → 单PLL三输出'),
    ('u_system/u_pad',           'pad',   '压力垫 / 摇杆采集与 LED'),
    ('u_system/u_pad_leds',      'pad',   '压力垫 / 摇杆采集与 LED'),
    ('u_system/u_comm',          'comm',  '通信与协议栈'),
    ('u_system/u_sound/u_voice', 'voice', 'voice_router 合成核心'),
    ('u_system/u_sound/u_audio', 'audio', '音频输出与采样时基'),
    ('u_system/u_sound',         'sound', '演奏前端 midi_voice_top'),
    ('u_system/u_fft_chain',     'disp',  '显示与可视化（pix 域）'),
    ('u_system/u_ui',            'ui',    '配置与侧栏（core → pix 提交）'),
    ('u_system/u_timing',        'disp',  '显示与可视化（pix 域）'),
    ('u_system/u_key',           'ui',    '配置与侧栏（core → pix 提交）'),
    ('u_system/u_visualizer_fifo','disp', '显示与可视化（pix 域）'),
    ('u_system',                 'top',   '统一板级系统 instrument_system'),
    ('u_voice',                  'voice', 'voice_router 合成核心'),
    ('u_input',                  'voice', 'voice_router 合成核心'),
    ('u_exc',                    'voice', 'voice_router 合成核心'),
    ('u_env',                    'voice', 'voice_router 合成核心'),
    ('u_modr',                   'voice', 'voice_router 合成核心'),
    ('u_pitch',                  'voice', 'voice_router 合成核心'),
    ('u_ld',                     'voice', 'voice_router 合成核心'),
    ('u_era',                    'voice', 'voice_router 合成核心'),
    ('u_erb',                    'voice', 'voice_router 合成核心'),
    ('u_body',                   'voice', 'voice_router 合成核心'),
    ('u_rev',                    'voice', 'voice_router 合成核心'),
]
NAMES = {'clock': '时钟与复位 · 50MHz → 单PLL三输出',
         'pad': '压力垫 / 摇杆采集与 LED', 'comm': '通信与协议栈',
         'sound': '演奏前端 midi_voice_top', 'voice': 'voice_router 合成核心',
         'audio': '音频输出与采样时基', 'disp': '显示与可视化（pix 域）',
         'ui': '配置与侧栏（core → pix 提交）', 'top': '统一板级系统 instrument_system',
         'other': '其他'}
FILL = {'clock': '#fef3c7', 'pad': '#dbeafe', 'comm': '#ede9fe', 'sound': '#cffafe',
        'voice': '#bfdbfe', 'audio': '#fce7f3', 'disp': '#dcfce7', 'ui': '#dcfce7',
        'top': '#f1f5f9', 'other': '#f1f5f9'}
ORDER = ['top', 'clock', 'pad', 'comm', 'sound', 'voice', 'audio', 'disp', 'ui', 'other']

def cluster_of(rel):
    for pref, key, _ in CLUSTERS:
        if rel == pref or rel.startswith(pref + '/'):
            return key
    return 'other'

nodes, edges, ids = {}, [], {}

def nid(path):
    if path in ids:
        return ids[path]
    base = 'n_' + re.sub(r'[^A-Za-z0-9_]', '_', path)
    i, cand = 1, base
    while cand in ids.values():
        i += 1
        cand = f'{base}_x{i}'
    ids[path] = cand
    return cand

def limit_rel(rel):
    best = None
    for pref, lv in LIMITS.items():
        if rel == pref or rel.startswith(pref + '/'):
            if best is None or len(pref) > best[0]:
                best = (len(pref), lv)
    return None if best is None else best[1]

def walk(path, mod, depth, rel):
    key = cluster_of(rel) if rel else 'top'
    info = modules.get(mod, {})
    src = info['file'].split('/')[-1] if info else '?'
    inst = path.split('/')[-1]
    if depth == 0:
        label = f'{mod}\\n统一板级入口 · {src}'
        nodes[nid(path)] = (key, label, 'box3d', 11, '#f1f5f9')
    else:
        label = f'{mod}\\n{inst} · {src}'
        nodes[nid(path)] = (key, label, 'box', 8, FILL.get(key, '#f1f5f9'))
    stop = depth >= MAXDEPTH
    if not stop and rel:
        lim = limit_rel(rel)
        stop = lim is not None and lim == 0
    if stop:
        return
    for child, cinst in info.get('children', []):
        cpath = f'{path}/{cinst}'
        crel = f'{rel}/{cinst}' if rel else cinst
        edges.append((nid(path), walk(cpath, child, depth + 1, crel)))

walk(ROOT, ROOT, 0, '')

out = ['digraph hierarchy {',
       'graph [fontname="Noto Sans CJK SC",fontsize=14,rankdir=LR,nodesep=0.28,ranksep=0.6,bgcolor="white",pad=0.2,newrank=true];',
       'node [shape=box,style="rounded,filled",fontname="Noto Sans CJK SC",fontsize=8,margin="0.10,0.05",color="#64748b"];',
       'edge [color="#94a3b8",arrowsize=0.55,penwidth=0.8];',
       f'label="{ROOT} 实例树（自动提取自 RTL 源码）";labelloc=t;']
for key in ORDER:
    members = [i for i, v in nodes.items() if v[0] == key]
    if not members:
        continue
    out.append(f'  subgraph cluster_{key} {{')
    out.append(f'    label="{NAMES[key]}"; fontsize=12; fontcolor="#334155"; color="#cbd5e1"; style="rounded,dashed";')
    for i in members:
        _, label, shape, fs, fill = nodes[i]
        out.append(f'    {i} [label="{label}",shape={shape},fontsize={fs},fillcolor="{fill}"];')
    out.append('  }')
out += [f'  {a} -> {b};' for a, b in edges]
out.append('}')
dst = os.environ.get('HIER_OUT', 'hierarchy.dot')
open(dst, 'w').write('\n'.join(out) + '\n')
print(f'{dst}: nodes={len(nodes)} edges={len(edges)}')
