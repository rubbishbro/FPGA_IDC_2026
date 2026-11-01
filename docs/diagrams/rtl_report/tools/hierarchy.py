#!/usr/bin/env python3
"""Extract module instantiation hierarchy from the RTL tree."""
import re, sys, os, json
from pathlib import Path

ROOT = Path('/home/rubbishbro/Projects/FPGA_IDC_2026')
RTL_DIRS = [ROOT/'rtl', ROOT/'FFT_spectrumshow'/'src']

def sv_files():
    for d in RTL_DIRS:
        for p in sorted(d.rglob('*')):
            if p.suffix in ('.sv', '.v') and 'tb' not in p.name and 'vendor' not in str(p):
                yield p

# strip comments and strings
def clean(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', ' ', text)
    text = re.sub(r'"[^"\n]*"', '""', text)
    return text

def parse_module_header(text, pos):
    # handle optional lifetime + parameter port list
    m = re.match(r'\s*module\s+([A-Za-z_]\w*)', text[pos:])
    if not m: return None
    name = m.group(1)
    i = pos + m.end()
    depth = 0
    # skip parameter list / port list until we find ');' at depth 0
    while i < len(text):
        c = text[i]
        if c in '([': depth += 1
        elif c in ')]': depth -= 1
        elif c == ';' and depth <= 0:
            i += 1
            break
        i += 1
    # body: until matching 'endmodule'
    end = text.find('endmodule', i)
    body = text[i:end] if end > 0 else text[i:]
    return name, body

KEYWORDS = {'if','else','for','case','casez','casex','begin','end','assign','always','always_ff','always_comb',
            'generate','function','task','module','input','output','inout','wire','logic','reg','parameter','localparam',
            'typedef','struct','enum','return','initial','assert','property','sequence','covergroup','interface','package','import','type'}

def find_instances(body):
    """module_name inst_name ( ... );  -- allow parameter overrides #(...)"""
    out = []
    # remove generate/if constructs is unnecessary; regex over cleaned body
    for m in re.finditer(r'\b([A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\))?\s+([A-Za-z_]\w*)\s*\(', body, flags=re.S):
        mod, inst = m.group(1), m.group(2)
        if mod in KEYWORDS or inst in KEYWORDS: continue
        if mod in ('signed','unsigned','int','bit','byte','shortint','longint','string'): continue
        # must not be a declaration like "logic [7:0] foo (" -- handled by keyword filter
        out.append((mod, inst, m.start()))
    return out

modules = {}
for f in sv_files():
    raw = f.read_text(errors='ignore')
    text = clean(raw)
    pos = 0
    while True:
        m = re.search(r'\bmodule\s+([A-Za-z_]\w*)', text[pos:])
        if not m: break
        start = pos + m.start()
        parsed = parse_module_header(text, start)
        if not parsed: break
        name, body = parsed
        insts = find_instances(body)
        if name in modules:
            modules[name]['insts'] += insts
            modules[name]['files'].append(str(f.relative_to(ROOT)))
        else:
            modules[name] = {'file': str(f.relative_to(ROOT)), 'files': [str(f.relative_to(ROOT))], 'insts': insts}
        pos = text.find('endmodule', start)
        if pos < 0: break
        pos += len('endmodule')

# filter instantiations to known modules
for name, info in modules.items():
    seen = []
    for mod, inst, p in info['insts']:
        if mod in modules and mod != name:
            if (mod, inst) not in [(a,b) for a,b,_ in seen]:
                seen.append((mod, inst, p))
    info['children'] = [(a,b) for a,b,_ in sorted(seen, key=lambda x: x[2])]

def tree(name, depth=0, maxdepth=8, seen=()):
    lines = []
    info = modules.get(name)
    if not info:
        return [f"{'  '*depth}{name} (未在当前树中找到源码)"]
    for child, inst in info['children']:
        lines.append(f"{'  '*depth}├─ {inst} : {child}")
        if depth < maxdepth and child not in seen:
            lines += tree(child, depth+1, maxdepth, seen + (name,))
    return lines

if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else 'instrument_board_top'
    print(f"# hierarchy from {target}\n{target}")
    print('\n'.join(tree(target)))
    if len(sys.argv) > 2 and sys.argv[2] == '--all':
        print()
        for n in sorted(modules):
            print(n, '->', ', '.join(c for c,_ in modules[n]['children']))
