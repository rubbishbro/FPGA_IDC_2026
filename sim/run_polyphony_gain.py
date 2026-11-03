#!/usr/bin/env python3
"""Arbitrary precision cycle oracle for shared polyphony gain."""
import argparse,json,os,random,re,shutil,subprocess
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
                shift=0 if not enable else 2 if k==4 else 1 if 2<=k<=7 else 0
                g=4096<<shift
                product=x<<shift
        rows.append(f'{int(clear)} {int(valid)} {x&((1<<64)-1):016x} {k} {ov} {out&((1<<64)-1):016x} {g}')
    path.write_text('\n'.join(rows)+'\n');return len(rows)
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--verilator',help='Verilator executable (selects that backend in auto mode)')
    ap.add_argument('--simulator',choices=['auto','questa','verilator'],default='auto')
    ap.add_argument('--out',type=Path,default=ROOT/'build/polyphony_gain_verify')
    a=ap.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);results=[]
    (out/'verification.json').unlink(missing_ok=True)
    def executable(name):
        return shutil.which(name) or (str(Path.home()/'.local/bin'/name)
               if (Path.home()/'.local/bin'/name).is_file() else None)
    tools={name:executable(name) for name in ('vlib','vlog','vsim')}
    simulator=a.simulator
    verilator=a.verilator or os.environ.get('VERILATOR')
    if simulator=='auto':
        simulator='verilator' if verilator else 'questa' if all(tools.values()) else 'verilator'
    env=os.environ.copy();work=out/'work'
    def run(name,command):
        p=subprocess.run(list(map(str,command)),cwd=out,env=env,capture_output=True,text=True,timeout=600)
        text=p.stdout+p.stderr;(out/(name+'.log')).write_text(text)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|%Error|Trouble making server|\bFAIL\b',text):
            raise RuntimeError(text[-5000:])
        return text
    sources=[ROOT/p for p in ['rtl/router/pkg/router_pkg.sv','rtl/router/parts/polyphony_gain.sv',
                             'sim/unit/audio/tb_polyphony_gain.sv']]
    if simulator=='questa':
        if not all(tools.values()):raise RuntimeError('Questa vlib/vlog/vsim not found')
        ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')))
        (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M))
        env.update(QSIM_INI=str(out/'modelsim.ini'),MODELSIM=str(out/'modelsim.ini'))
        run('vlib',[tools['vlib'],work]);run('compile',[tools['vlog'],'-sv','-work',work,*sources])
    else:
        verilator=verilator or executable('verilator')
        if not verilator:raise RuntimeError('Verilator not found; use --simulator questa or set VERILATOR')
    for enable in (0,1):
        vec=out/f'vectors_{enable}.txt';n=vectors(vec,enable)
        if simulator=='questa':
            output=run(f'simulation_{enable}',[tools['vsim'],'-c','-lib',work,'tb_polyphony_gain',
                f'-gENABLE={enable}',f'+VECTORS={vec}','-do','run -all; quit -f'])
        else:
            obj=out/f'obj_{enable}'
            run(f'compile_{enable}',[verilator,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal',
                '--top-module','tb_polyphony_gain',f'-GENABLE={enable}','-j','4','--Mdir',obj,
                '-MAKEFLAGS','CFG_CXXFLAGS_PCH_I=-include',*sources])
            output=run(f'simulation_{enable}',[obj/'Vtb_polyphony_gain',f'+VECTORS={vec}'])
        assert f'PASS tb_polyphony_gain enable={enable} rows={n}' in output,output[-3000:]
        summary=[line.lstrip('# ') for line in output.splitlines() if 'PASS tb_polyphony_gain' in line]
        print('\n'.join(summary),flush=True);results.append(dict(enable=enable,rows=n,simulator=simulator,passed=True))
    (out/'verification.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
