#!/usr/bin/env python3
"""Arbitrary precision cycle oracle for shared polyphony gain."""
import argparse,json,random,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def vectors(path,enable):
    rng=random.Random(11012026);g=4096;pv=0;product=0;out=0;rows=[]
    counts=[1]*64+[16]*256+[0]*64+[1]*4096
    counts += list(range(32))*20+[rng.randrange(32) for _ in range(10000)]
    for i,k in enumerate(counts+[0]*4):
        clear=i in (0,400,4500) or (i>5000 and rng.randrange(100)==0)
        valid= i%7!=2
        x=[-(1<<63),(1<<63)-1,-1,0,1][i%5] if i%3 else rng.randrange(-(1<<63),1<<63)
        if clear:g=4096;pv=0;product=0;ov=0;out=0
        else:
            ov=pv
            if pv:out=product
            pv=int(valid)
            if valid:
                shift=0 if not enable else 2 if k==1 else 1 if 2<=k<=7 else 0
                g=4096<<shift
                product=x<<shift
        rows.append(f'{int(clear)} {int(valid)} {x&((1<<64)-1):016x} {k} {ov} {out&((1<<64)-1):016x} {g}')
    path.write_text('\n'.join(rows)+'\n');return len(rows)
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--verilator',default='verilator');ap.add_argument('--out',type=Path,default=ROOT/'build/polyphony_gain_verify');a=ap.parse_args()
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);results=[]
    for enable in (0,1):
        vec=out/f'vectors_{enable}.txt';n=vectors(vec,enable);obj=out/f'obj_{enable}'
        cmd=[a.verilator,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal','--top-module','tb_polyphony_gain',f'-GENABLE={enable}','-j','4','--Mdir',str(obj),'-MAKEFLAGS','CFG_CXXFLAGS_PCH_I=-include',*[str(ROOT/p) for p in ['rtl/router/pkg/router_pkg.sv','rtl/router/parts/polyphony_gain.sv','sim/unit/audio/tb_polyphony_gain.sv']]]
        with (out/f'compile_{enable}.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
        p=subprocess.run([str(obj/'Vtb_polyphony_gain'),f'+VECTORS={vec}'],capture_output=True,text=True,check=True)
        (out/f'simulation_{enable}.log').write_text(p.stdout+p.stderr)
        assert f'PASS tb_polyphony_gain enable={enable} rows={n}' in p.stdout
        print(p.stdout,flush=True);results.append(dict(enable=enable,rows=n,passed=True))
    (out/'verification.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
