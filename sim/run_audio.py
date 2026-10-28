#!/usr/bin/env python3
"""Questa: eng1 integer oracle and production I2S-clocked synthesis integration."""
import argparse,json,os,random,re,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def vectors(path):
    rng=random.Random(20261028)
    def signed(x,b):
        x &= (1<<b)-1
        return x-(1<<b) if x>>(b-1) else x
    rows=[]
    for case in range(256):
        n=([0,1,2,20,48,64,65,127][case] if case<8 else rng.randrange(65))
        z=case%3==0
        x=rng.randrange(-(1<<31),1<<31)
        modes=[];total=0
        for i in range(64):
            g,a1,a2=[signed(rng.getrandbits(32),32) for _ in range(3)]
            q,v=[rng.randrange(-(1<<31),1<<31) for _ in range(2)]
            eq,ev=q,v
            if i<min(n,64):
                oldq,oldv=(0,0) if z else (q,v)
                acc=signed(signed(g,26)*x-(signed(a1,22)<<4)*oldq-(a2&0xffffff)*oldv,64)
                result=signed(acc+(1<<23),64)>>24
                eq=max(-(1<<31),min((1<<31)-1,result));ev=oldq;total+=eq
            modes.append((g,a1,a2,q,v,eq,ev))
        rows.append(f'{n} {int(z)} {x} {total}\n'+'\n'.join(' '.join(map(str,row)) for row in modes))
    path.write_text('\n'.join(rows)+'\n')

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/i2s_pipeline/audio')
    ap.add_argument('--pad-only',action='store_true',help='only the two PAD integration cases')
    ap.add_argument('--test',action='append',choices=['eng1','bridge','integration'])
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    vectors(out/'eng1_cases.txt')
    ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    text=ini.read_text();work=out/'work'
    text=re.sub(r'^work\s*=.*$','work = '+str(work),text,flags=re.M)
    (out/'modelsim.ini').write_text(text)
    env=os.environ.copy();env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    def run(tool,options,name):
        cmd=[shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,options)]
        p=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True,timeout=180)
        text=p.stdout+p.stderr;(out/(name+'.log')).write_text(text)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',text):
            raise RuntimeError(name+'\n'+text[-6000:])
        return text
    run('vlib',[work],'vlib')
    sources=re.findall(r"'(rtl/[^']+\.sv)'",(ROOT/'rtl/router/tools/run_all.ps1').read_text())
    sources=[ROOT/s for s in sources if not s.endswith('/tb_music.sv')]
    sources += [ROOT/p for p in ['rtl/midi/midi_note_state.sv','rtl/midi/midi_instrument_map.sv',
        'rtl/router/midi_voice_top.sv','rtl/router/pad_voice_top.sv','sim/unit/midi/w25q64_read_model.sv']]
    sources += sorted((ROOT/'sim/unit/audio').glob('tb_*.sv'))
    run('vlog',['-sv','-work',work,*sources],'compile')
    tests=args.test or ['eng1','bridge','integration'];results=[]
    configs=[]
    if 'eng1' in tests:configs.append(('tb_eng1_pipeline',{}))
    if 'bridge' in tests:configs.append(('tb_i2s_audio_output',{}))
    if 'integration' in tests:
        for engine in [0,1]:
            for exact in [0,1]:
                configs.append(('tb_i2s_synthesis',dict(ENG1=engine,EXACT_48K=exact)))
        for engine in [0,1]:
            configs.append(('tb_i2s_synthesis',dict(ENG1=engine,EXACT_48K=0,PAD_TOP=1)))
    if args.pad_only:configs=[c for c in configs if c[1].get('PAD_TOP')==1]
    for top,params in configs:
        name=top+''.join(f'_{k}{v}' for k,v in params.items())
        text=run('vsim',['-c','-lib',work,top,*[f'-g{k}={v}' for k,v in params.items()],
            '-wlf',out/(name+'.wlf'),'-do','run -all; quit -f'],name)
        if 'PASS '+top not in text:raise RuntimeError(name+' missing PASS')
        summary=[line.lstrip('# ') for line in text.splitlines() if 'PASS '+top in line]
        print('\n'.join(summary),flush=True);results.append(dict(test=top,parameters=params,passed=True,summary=summary))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')

if __name__=='__main__':main()
