#!/usr/bin/env python3
"""Read the sidebar demo's actual Gowin PnR evidence; never treat process exit 0 as success."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/sidebar'
PNR=ROOT/'build/sidebar_board/sidebar_board/impl/pnr'


def main():
    text=(PNR/'sidebar_board.tr').read_text()
    log=(OUT/'gowin.log').read_text()
    if 'SIDEBAR_PNR_DONE' not in log or re.search(r'^ERROR\b',log,re.M):
        raise RuntimeError('Gowin did not complete PnR successfully')
    counts={}
    for kind in ('Setup','Hold'):
        match=re.search(rf'<Numbers of {kind} Violated Endpoints>:(\d+)',text)
        if not match or int(match[1]):raise RuntimeError(f'{kind} timing violations or missing report')
        counts[kind.lower()]=int(match[1])
    for clock,frequency in [('clk50','50.000MHz'),('clk_pix','33.333MHz')]:
        if not re.search(rf'\b{clock}\s+\w+\s+[\d.]+\s+{re.escape(frequency)}',text):
            raise RuntimeError(f'missing expected clock constraint: {clock}/{frequency}')
    slacks={}
    for kind,next_kind in [('Setup','Hold'),('Hold','Recovery')]:
        section=text.split(f'\n3.1.{1 if kind=="Setup" else 2} {kind} Paths Table\n',1)[1]
        section=section.split(f'\n3.1.{2 if kind=="Setup" else 3} {next_kind} Paths Table',1)[0]
        values=re.findall(r'^\s+\d+\s+(-?[\d.]+)\s+',section,re.M)
        if not values:raise RuntimeError(f'missing {kind} path slacks')
        slacks[kind.lower()]=min(map(float,values))
    files=set((ROOT/'sim/ui_sources.f').read_text().splitlines())
    files.update(str(p.relative_to(ROOT)) for p in (ROOT/'rtl_FFT/src').rglob('*') if p.suffix in ('.v','.sv'))
    files.update(str(p.relative_to(ROOT)) for p in (ROOT/'rtl_FFT/board').glob('*.mem'))
    files.update(['rtl_FFT/board/ui_demo_top.v','rtl_FFT/board/ui_demo.gprj',
                  'rtl_FFT/board/timing.sdc','rtl_FFT/board/ui_demo.cst',
                  'rtl_FFT/board/gowin_pll.v'])
    head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    result={'scope':'independent LCD sidebar demo; 50MHz control / 33.333MHz pixel; not audio system signoff',
            'head':head,'violations':counts,'worst_slack_ns':slacks,
            'source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sorted(files)}}
    (OUT/'timing_verified.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'PASS sidebar PnR: setup {slacks["setup"]:+.3f} ns, hold {slacks["hold"]:+.3f} ns')


if __name__=='__main__':main()
