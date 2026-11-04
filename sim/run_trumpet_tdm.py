#!/usr/bin/env python3
"""16-slot shared trumpet pipeline against the independent sample-level integer model."""
import argparse,json,os,random,shutil,subprocess,sys
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python_monotor/modal_sim'))
from trumpet_lip import TrumpetExcitation,configs

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,default=ROOT/'build/trumpet_tdm_20261102/unit')
    p.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
    args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'verification.json').unlink(missing_ok=True)
    rng=random.Random(20261102);periods=list(configs());model=TrumpetExcitation(periods[:16])
    frames=6500
    with (out/'vectors.txt').open('w') as f:
        for frame in range(frames):
            action={700:1,1600:2,3100:3,5100:1}.get(frame,0)
            if action:model.reset()
            # Every nominal period is exercised at every slot; also invalid period.
            ps=[periods[(s+frame//192)%32] for s in range(16)]
            if frame%97==0:ps[frame%16]=2
            model.period=np.array(ps,dtype=np.int64)
            gate=65535 if frame%1000<850 else rng.getrandbits(16)
            trigger=rng.getrandbits(16) if frame%83==0 else 0
            clear=rng.getrandbits(16) if frame%127==0 else 0
            # Long holds exercise faded noise, mixed lifetimes and persistent per-slot state.
            levels=[rng.randrange(256) if frame%1000>=700 else 255-s*7 for s in range(16)]
            delta=[rng.randrange(-1800000,2200000) for s in range(16)]
            gate_a=np.array([bool(gate>>s&1) for s in range(16)])
            trigger_a=np.array([bool(trigger>>s&1) for s in range(16)])
            clear_a=np.array([bool(clear>>s&1) for s in range(16)])
            expected=model.step(gate_a,np.array(levels),trigger_a,clear_a,np.array(delta))
            f.write(' '.join(map(str,[action,gate,trigger,clear,*ps,*levels,*delta,*expected]))+'\n')
    cmd=[args.verilator,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal',
         '--top-module','tb_trumpet_tdm','--Mdir',str(out/'obj'),'-j','4',
         *[str(ROOT/s) for s in ['rtl/router/pkg/trumpet_excitation_pkg.sv',
          'rtl/router/parts/trumpet_excitation.sv','sim/unit/audio/tb_trumpet_tdm.sv']]]
    with (out/'compile.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
    result=subprocess.run([str(out/'obj/Vtb_trumpet_tdm')],cwd=out,capture_output=True,text=True,timeout=120)
    output=result.stdout+result.stderr;(out/'simulation.log').write_text(output);print(output)
    result.check_returncode()
    if 'PASS tb_trumpet_tdm' not in output:raise RuntimeError('missing PASS')
    (out/'verification.json').write_text(json.dumps({'passed':True,'frames':frames,'slots':16,'summary':output},indent=2)+'\n')

if __name__=='__main__':main()
