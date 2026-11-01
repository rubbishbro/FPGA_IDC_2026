#!/usr/bin/env python3
"""Bit-exact excitation/envelope vectors, including full release and retrigger."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
import eng1_rtl as E
import eng1_audition as A


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'build/performance_frontend_verify')
    parser.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
    args=parser.parse_args();exe=shutil.which(args.verilator)
    if exe is None:parser.error('Verilator required')
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'verification.json').unlink(missing_ok=True)
    m=json.loads((ROOT/'rtl/router/tools/performance/resources.json').read_text())
    samples=0
    with (out/'frontend_expected.txt').open('w') as f:
        for name,ident in [('piano',0),('guitar',1),('trumpet',3),('violin',5)]:
            cfg=m['frontends'][name];row=next(e for e in m['entries'] if e['name']==name)
            if name=='trumpet':aa,rr=row['a_step'],row['r_step'];sustain,decay=0x1fffffff,1048576
            else:aa,rr=cfg['a_step'],cfg['r_step'];sustain,decay=cfg['s_level'],cfg['d_step']
            env=E.Envelope([aa],[rr],sustain_level=sustain,decay_step=decay)
            if name in ('piano','guitar'):
                exc=A.Strike(name,1);exc.rise=cfg['rise_sh'];exc.width=cfg['pw_len'];exc.gap=cfg['gap_len'];exc.pulses=cfg['n_pulse']
            else:exc=E.Excitation([row['period']])
            period=row.get('period',2)
            for n in range(38000):
                gate=np.array([n<4000 or 37000<=n<37500]);trig=np.array([n==2000]);clear=np.array([n==2500])
                level=np.array([255 if n<1000 else 129]);zero=np.zeros(1,dtype=np.int64)
                old=env.level.copy();e=env.step(gate,trig,clear)
                if name in ('piano','guitar'):e=np.where(trig|clear,0,old)
                x=exc.step(level,gate,trig,clear) if name in ('piano','guitar') else exc.step(gate,level,trig,clear,zero)
                f.write(f'{ident} {int(gate[0])} {level[0]} {int(trig[0])} {int(clear[0])} {period} {aa} {rr} {x[0]} {e[0]} {int(env.dead[0])}\n')
                samples+=1
    files=[ROOT/p for p in ['rtl/router/pkg/router_pkg.sv','rtl/router/parts/envelope.sv',
        'rtl/router/parts/excitation.sv','rtl/router/routers/env_router.sv','rtl/router/routers/exc_router.sv',
        'sim/unit/eng1/tb_performance_frontend.sv']]
    cmd=[exe,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal','--top-module',
         'tb_performance_frontend','-j','4','--Mdir',str(out/'obj'),'-MAKEFLAGS',
         'CFG_CXXFLAGS_PCH_I=-include',*map(str,files)]
    with (out/'compile.log').open('w') as log:
        subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
    with (out/'simulation.log').open('w') as log:
        subprocess.run([str(out/'obj/Vtb_performance_frontend')],cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
    summary=(out/'simulation.log').read_text()
    if f'PASS tb_performance_frontend samples={samples}' not in summary:raise RuntimeError(summary)
    (out/'verification.json').write_text(json.dumps(dict(passed=True,samples=samples,summary=summary))+'\n')
    print(summary)


if __name__=='__main__':main()
