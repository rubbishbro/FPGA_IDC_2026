#!/usr/bin/env python3
"""Independent arbitrary-precision oracle, stereo wire decoding and DSP-free synthesis inputs."""
import argparse,json,math,os,random,re,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def generate(path,max_itd):
    rng=random.Random(20261029)
    knots=[round(256*(32-i)/max(32-i,i)) for i in range(33)]
    def gain(pos):
        i,f=divmod(pos,16)
        return knots[i]*16 if i==32 else knots[i]*(16-f)+knots[i+1]*f
    def slew(value,target,step=1):
        return value+max(-step,min(step,target-value))
    cases=[(16,False,False)]*32
    # Entire table, every interpolated position, both directions, then clamp input.
    cases += [(0,True,False)]*272
    for pan in range(33):cases += [(pan,True,False)]*16
    for pan in range(32,-1,-1):cases += [(pan,True,False)]*16
    cases += [(63,True,False)]*520
    cases += [(8,False,False)]*400+[(8,True,False)]*300
    cases += [(24,True,False)]*400+[(24,False,False)]*300
    cases += [(rng.randrange(64),bool(rng.getrandbits(1)),i%23<3) for i in range(300)]
    # Leave dirty nonzero history for the reset/replay test.
    cases += [(32,True,False)]*200
    pos=256;dl=dr=0;hl=[];hr=[];rows=[]
    probes=[0,1,-1,255,-256,512,-512,1<<24,-(1<<24),(1<<63)-1,-(1<<63)]
    max_power=0.0;max_ild=0.0
    for index,(pan,itd,clear) in enumerate(cases):
        # Mostly audible ordinary samples, plus full-range and sub-PCM boundary values.
        x=(probes[index%len(probes)] if index%4==0 else rng.randrange(-(1<<28),1<<28))
        if index%29==0:x=rng.randrange(-(1<<63),1<<63)
        pos=slew(pos,min(32,pan)*16)
        gl,gr=gain(pos),gain(512-pos)
        dl=slew(dl,((max(0,pos-256)*max_itd)//4) if itd else 0,2 if max_itd==8 else 1)
        dr=slew(dr,((max(0,256-pos)*max_itd)//4) if itd else 0,2 if max_itd==8 else 1)
        if clear:hl=[];hr=[];sample=0
        else:sample=x
        hl=[sample*gl,*hl][:max_itd+1];hr=[sample*gr,*hr][:max_itd+1]
        def delayed(hist,d):
            q,f=divmod(d,64)
            return (hist[q] if q<len(hist) else 0)*(64-f)+(hist[q+1] if q+1<len(hist) else 0)*f
        yl,yr=delayed(hl,dl),delayed(hr,dr)
        rows.append(f'{x&((1<<64)-1):016x} {pan:02x} {int(itd):x} {int(clear):x} '
                    f'{yl&((1<<84)-1):021x} {yr&((1<<84)-1):021x} '
                    f'{pos:03x} {gl:04x} {gr:04x} {dl:03x} {dr:03x}')
    path.write_text('\n'.join(rows)+'\n')
    for i,k in enumerate(knots):
        other=knots[32-i]
        max_power=max(max_power,abs(10*math.log10((k*k+other*other)/256**2)))
        if k and other:max_ild=max(max_ild,abs(20*math.log10((k/other)/((32-i)/i))))
    assert knots==sorted(knots,reverse=True)
    assert all(gain(p)>=gain(p+1) for p in range(512))
    assert gain(0)==4096 and gain(256)==4096 and gain(512)==0
    assert all(max(gain(p),gain(512-p))==4096 for p in range(513))
    return dict(rows=len(rows),max_itd=max_itd,knots=knots,max_total_power_increase_db=max_power,max_knot_ild_error_db=max_ild)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/stereo')
    ap.add_argument('--test',action='append',choices=['unit','bridge'])
    ap.add_argument('--verilator',help='Use Verilator instead of Questa')
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    metrics=[generate(out/f'vectors_{m}.txt',m) for m in (0,1,2,4,8)]
    if args.verilator:
        sources=['rtl/audio/audio_async_fifo.sv','rtl/audio/i2s_amp_tx.sv','rtl/audio/stereo_spatializer.sv',
                 'rtl/audio/i2s_audio_output.sv','sim/unit/audio/tb_stereo_spatializer.sv','sim/unit/audio/tb_i2s_stereo.sv']
        cases=[];tests=args.test or ['unit','bridge']
        if 'unit' in tests:cases += [('tb_stereo_spatializer',dict(MAX_ITD=m)) for m in (0,1,2,4,8)]
        if 'bridge' in tests:
            cases += [('tb_i2s_stereo',dict(HEADROOM=h,MAX_ITD=4,EXACT_48K=e)) for h in (0,3,53) for e in (0,1)]
            cases += [('tb_i2s_stereo',dict(HEADROOM=3,MAX_ITD=m,EXACT_48K=0)) for m in (0,8)]
        results=[]
        for top,params in cases:
            name=top+''.join(f'_{k}{v}' for k,v in params.items());obj=out/name
            cmd=[args.verilator,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal',
                 '--top-module',top,'-j','4','--Mdir',str(obj),'-MAKEFLAGS','CFG_CXXFLAGS_PCH_I=-include',
                 *[f'-G{k}={v}' for k,v in params.items()],*[str(ROOT/s) for s in sources]]
            with (out/(name+'_compile.log')).open('w') as log:
                subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
            p=subprocess.run([str(obj/('V'+top)),f'+VECTORS={out}/vectors_{params["MAX_ITD"]}.txt'],cwd=out,capture_output=True,text=True,timeout=180)
            (out/(name+'.log')).write_text(p.stdout+p.stderr)
            if p.returncode or 'PASS '+top not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
            summary=[line for line in p.stdout.splitlines() if 'PASS '+top in line]
            print('\n'.join(summary),flush=True);results.append(dict(test=top,parameters=params,passed=True,summary=summary))
        (out/'results.json').write_text(json.dumps(dict(metrics=metrics,tests=results),indent=2)+'\n')
        return
    ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    work=out/'work';s=re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M)
    (out/'modelsim.ini').write_text(s);env=os.environ.copy();env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    def run(tool,opts,name):
        cmd=[shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,opts)]
        p=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True,timeout=180)
        text=p.stdout+p.stderr;(out/(name+'.log')).write_text(text)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b|Trouble making server|Error:',text):
            raise RuntimeError(name+'\n'+text[-6000:])
        return text
    run('vlib',[work],'vlib')
    sources=['rtl/audio/audio_async_fifo.sv','rtl/audio/i2s_amp_tx.sv','rtl/audio/stereo_spatializer.sv',
             'rtl/audio/i2s_audio_output.sv','sim/unit/audio/tb_stereo_spatializer.sv','sim/unit/audio/tb_i2s_stereo.sv']
    run('vlog',['-sv','-work',work,*[ROOT/s for s in sources]],'compile')
    cases=[];tests=args.test or ['unit','bridge']
    if 'unit' in tests:
        cases += [('tb_stereo_spatializer',dict(MAX_ITD=m)) for m in (0,1,2,4,8)]
    if 'bridge' in tests:
        cases += [('tb_i2s_stereo',dict(HEADROOM=h,MAX_ITD=4,EXACT_48K=e)) for h in (0,3,53) for e in (0,1)]
        cases += [('tb_i2s_stereo',dict(HEADROOM=3,MAX_ITD=m,EXACT_48K=0)) for m in (0,8)]
    results=[]
    for top,params in cases:
        name=top+''.join(f'_{k}{v}' for k,v in params.items())
        txt=run('vsim',['-c','-lib',work,top,*[f'-g{k}={v}' for k,v in params.items()],
            f'+VECTORS={out}/vectors_{params["MAX_ITD"]}.txt','-wlf',out/(name+'.wlf'),'-do','run -all; quit -f'],name)
        summary=[s.lstrip('# ') for s in txt.splitlines() if 'PASS '+top in s]
        if not summary:raise RuntimeError(name+' missing PASS')
        print('\n'.join(summary),flush=True);results.append(dict(test=top,parameters=params,passed=True,summary=summary))
    (out/'results.json').write_text(json.dumps(dict(metrics=metrics,tests=results),indent=2)+'\n')
if __name__=='__main__':main()
