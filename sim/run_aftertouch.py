#!/usr/bin/env python3
"""Standalone Icarus regression for per-slot ENG1 aftertouch (no vendor IP)."""
from pathlib import Path
import argparse,json,os,shutil,struct,subprocess
ROOT=Path(__file__).resolve().parents[1]

def vectors(out):
    tables=json.loads((ROOT/'rtl/router/tools/pitch_tables.json').read_text())
    ratios=tables['pitch_ratio'];words=[0]*1024
    for name,start in [('pitch_ratio',0),('pitch_sine',512),('pitch_depth',768)]:
        values=tables[name];words[start:start+len(values)]=values
    (out/'pitch_tables.mem').write_text(''.join(f'{x:08x}\n' for x in words))
    cents=[];delta=[]
    for p in range(256):
        # Independent oracle: exactly 75 cents per 100 pressure counts in Q8.
        q=max(0,p-102)*75*256//100
        i,f=divmod(q+220*256,256)
        cents.append(q);delta.append(ratios[i]+((ratios[i+1]-ratios[i])*f+128)//256-(1<<24))
    for name,values in [('cents',cents),('delta',delta)]:
        (out/f'aftertouch_{name}.mem').write_text(''.join(f'{x&0xffffffff:08x}\n' for x in values))

def executable(name):
    found=os.environ.get(name.upper()) or shutil.which(name)
    if found:return found
    for directory in sorted((Path.home()/'miniforge3/pkgs').glob('iverilog-*/bin')):
        if (directory/name).is_file():return str(directory/name)
    raise RuntimeError(f'{name} not found')

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/eng1_aftertouch')
    ap.add_argument('--model-python',help='Python with NumPy; also run 40000-clock reference parity')
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True);vectors(out)
    image=out/'aftertouch.vvp'
    commands=[('compile',[executable('iverilog'),'-g2012','-s','tb_eng1_pitch','-o',str(image),
        str(ROOT/'rtl/router/parts/modulation1.sv'),str(ROOT/'sim/unit/audio/tb_eng1_pitch.sv')]),
        ('simulation',[executable('vvp'),str(image)])]
    for name,command in commands:
        p=subprocess.run(command,cwd=out,capture_output=True,text=True,timeout=60)
        output=p.stdout+p.stderr;(out/f'{name}.log').write_text(output)
        if p.returncode:raise RuntimeError(output)
    if 'PASS tb_eng1_pitch' not in output:raise RuntimeError(output)
    result=dict(passed=True,summary=output.strip())
    print(output.strip(),flush=True)
    if args.model_python:
        directory=ROOT/'rtl/router/tools/performance'
        manifest=json.loads((directory/'resources.json').read_text());raw=(directory/'resources.bin').read_bytes()
        rows=sorted((r for r in manifest['entries'] if r['name']=='trumpet' and r['slot']<16),key=lambda r:r['slot'])
        if len(rows)!=16:raise RuntimeError('16 deployed trumpet slots required for parity')
        lines=[]
        for row in rows:
            for m in range(64):
                w=struct.unpack_from('>16i',raw,row['offset']+m*64)
                lines.append(' '.join(str(w[k]) for k in [8,9,10,13,15]))
        (out/'pitch_params.txt').write_text('\n'.join(lines)+'\n')
        trace=out/'trace.vvp'
        subprocess.run([executable('iverilog'),'-g2012','-s','tb_eng1_pitch_trace','-o',str(trace),
            str(ROOT/'rtl/router/parts/modulation1.sv'),str(ROOT/'sim/unit/eng1/tb_eng1_pitch_trace.sv')],cwd=out,check=True,timeout=60)
        p=subprocess.run([executable('vvp'),str(trace)],cwd=out,capture_output=True,text=True,check=True,timeout=60)
        (out/'trace.log').write_text(p.stdout+p.stderr)
        code="import sys,json; from pathlib import Path; sys.path[:0]=sys.argv[1:3]; from run_eng1_model import compare_pitch; print(json.dumps(compare_pitch(Path(sys.argv[3]))))"
        p=subprocess.run([args.model_python,'-c',code,str(ROOT/'sim'),str(ROOT/'python_monotor/modal_sim'),str(out)],capture_output=True,text=True,check=True,timeout=60)
        result['parity']=json.loads(p.stdout)
        print('PASS Python/RTL aftertouch',result['parity'],flush=True)
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
