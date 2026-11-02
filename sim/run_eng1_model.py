#!/usr/bin/env python3
"""Current Python ENG1 versus observed production RTL, including pitch clocks."""
from pathlib import Path
import argparse, concurrent.futures, json, os, re, shutil, subprocess, sys
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
import eng1_rtl as E
import router_eng1 as R


def bits(value,n=16):return np.array([(value>>s)&1 for s in range(n)],dtype=bool)

def compare_wave(path, bank, min_checks=2000):
    model=None;epoch=None;pending=None;checks=0;idle_checks=0;last_retired=None
    for line in path.read_text().splitlines():
        kind,*v=line.split();v=list(map(int,v))
        if kind=='I':
            ep,seq,gate,trigger,clear,sources,zero=v[:7]
            notes,level,delta,x,env=[v[7+i*16:7+(i+1)*16] for i in range(5)]
            if ep!=epoch:
                # Initial observation starts after backend ready; later epochs
                # include the load's mandatory first clearing frame.
                model=E.Eng1Synth(bank.instrument,note_map=notes,resources=bank,stereo=False,initialized=seq==1)
                epoch=ep
            assert model.note_map==tuple(notes)
            frame=model.step(gate=bits(gate),level=level,retrigger=bits(trigger),clear=bits(clear),
                             sources=bits(sources).astype(np.int8),committed_delta=delta)
            for name,got,want in [('x',frame.x,x),('envelope',frame.emap,env),('zero',frame.zero,bits(zero))]:
                if not np.array_equal(got,want):
                    raise AssertionError(f'{path.name} epoch={ep} frame={seq} {name}: {got.tolist()} != {list(want)}')
            assert pending is None, 'overlapping frame trace'
            pending=(seq,frame)
        elif kind=='O':
            ep,seq,out,mix,*voices=v
            assert pending is not None and pending[0]==seq
            frame=pending[1]
            assert frame.out==out,(path.name,seq,'out',frame.out,out)
            assert frame.mix==mix,(path.name,seq,'mix',frame.mix,mix)
            assert np.array_equal(frame.y,voices),(path.name,seq,'voices',frame.y,voices)
            pending=None;checks+=1
        elif kind=='R' and model is not None:
            ep,seq,idle=v
            # Older diagnostic traces included repeated maintenance retire
            # levels after the same sample. Only the sample's first retirement
            # corresponds to step(); configuration transactions are external.
            if (ep,seq)==last_retired:continue
            assert np.array_equal(model.idle,bits(idle)),(path.name,seq,'idle',model.idle,bits(idle))
            last_retired=(ep,seq)
            idle_checks+=1
    assert checks>=min_checks and pending is None
    return dict(frames=checks,idle_frames=idle_checks,passed=True)


def compare_pitch(out):
    rows=np.loadtxt(out/'pitch_params.txt',dtype=np.int64).reshape(16,64,5)
    resources=[]
    for s in range(16):
        w=np.zeros((64,8),dtype=np.int64);w[:,:3]=rows[s,:,:3];w[:,5]=rows[s,:,3];w[:,7]=rows[s,:,4]
        co=R.Eng1Coeffs(np.zeros(64,dtype=np.int64),w[:,1],np.zeros(64,dtype=np.int64),48)
        resources.append(E.NoteResource(s,co,100,100,100,w))
    engine=E.PitchEngine(resources);writes=commits=acks=rejects=0
    nominal_words=engine.words.copy()
    for line in (out/'pitch_clock_trace.txt').read_text().splitlines():
        values=list(map(int,line.split()))
        c,tick,ok,cv,src,data,cancel,cleanup,sources,bad,ready,reject,cw,addr,a1=values[:15]
        enabled,gates=values[15:17];levels=values[17:33]
        bank,busy,commit,sready=values[33:37];delta=values[37:]
        # Decode the physical signed24 lanes. Verilator 5.49's decimal display
        # of a dynamic packed part-select can retain adjacent upper word bits.
        delta=[R.wrap_signed(value,24) for value in delta]
        control=None
        if cv:
            kind=data>>28
            value=(((data>>10)&127)<<7)|((data>>17)&127) if kind==4 else (data>>10)&127
            control=('bend' if kind==4 else 'cc1',src,value)
        engine.words[:,:,7]=0 if bad else nominal_words[:,:,7]
        can_write=engine.state=='CO_OUT' and cleanup==0
        assert bool(cw)==can_write,(c,'co_we',engine.state,cw)
        if cw:
            value=max(engine.lower,min(engine.upper,engine.base+((engine.product+2097152)>>22)))
            assert addr==engine.slot*64+engine.mode and a1==value,(c,'coefficient',addr,a1,value)
            writes+=1
        old_commits=engine.commits
        ack,rejected=engine.clock(sample_tick=bool(tick),commit_ok=bool(ok),sources=bits(sources).astype(np.int8),
                                  control=control,cancel=bool(cancel),cleanup=bits(cleanup,2),
                                  pressure_enable=bool(enabled),pressure_gate=bits(gates),pressure_level=levels)
        assert (ack,rejected)==(bool(ready),bool(reject)),(c,'control',engine.state,ack,rejected,ready,reject)
        assert engine.bank==bank and (engine.state!='IDLE')==bool(busy),(c,'bank/busy',engine.state)
        assert (engine.commits!=old_commits)==bool(commit),(c,'commit')
        assert engine.sources_ready(bits(sources).astype(np.int8))==bool(sready),(c,'source barrier')
        assert np.array_equal(engine.active_delta,delta),(c,'delta')
        commits+=commit;acks+=ready;rejects+=reject
    assert writes>2000 and commits>2 and rejects>0
    return dict(cycles=40000,coefficient_writes=writes,commits=commits,control_acks=acks,rejections=rejects,passed=True)


def compare_post(path, headroom):
    rev=E.Reverb();spatial=E.Spatializer();checks=0
    for line in path.read_text().splitlines():
        p,n,x,pan,itd,clear,y,left,right,mono,pcm_l,pcm_r=map(int,line.split())
        rev.configure(['NONE','HALL','BATHROOM'][p])
        got_y=rev.step(x);got_l,got_r=spatial.step(got_y,pan,bool(itd),bool(clear))
        assert (got_y,got_l,got_r)==(y,left,right),(p,n,'post',got_y,y,got_l,left,got_r,right)
        got_pcm=(E.pcm16(got_y,headroom),E.pcm16(got_l,headroom,18),E.pcm16(got_r,headroom,18))
        assert got_pcm==(mono,pcm_l,pcm_r),(p,n,'pcm',got_pcm,(mono,pcm_l,pcm_r))
        checks+=1
    assert checks==12600
    return dict(samples=checks,headroom=headroom,passed=True)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/eng1_py_sync')
    ap.add_argument('--samples',type=int,default=2048)
    ap.add_argument('--test',action='append',choices=['pitch','wave','post'])
    a=ap.parse_args();out=a.out.resolve()
    executables={}
    for tool in ('vlib','vlog','vsim'):
        candidate=shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
        if Path(candidate).is_file() and os.access(candidate,os.X_OK):
            executables[tool]=candidate
    ini=Path(os.environ.get('QSIM_INI') or Path.home()/'gowin/simlib_questa/modelsim.ini')
    missing=[tool for tool in ('vlib','vlog','vsim') if tool not in executables]
    if not ini.is_file():missing.append(str(ini))
    if missing:
        ap.error('RTL verification unavailable; missing: '+', '.join(missing)+
                 '. No simulation was run and no RTL equivalence result is available.')
    out.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy()
    work=out/'work';(out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M))
    env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    def run(tool,opts,name):
        exe=executables[tool]
        p=subprocess.run([exe,*map(str,opts)],cwd=out,env=env,capture_output=True,text=True,timeout=1800)
        s=p.stdout+p.stderr;(out/(name+'.log')).write_text(s)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b|Trouble making server|Error:',s):
            raise RuntimeError(name+'\n'+s[-4000:])
        return s
    selected=a.test or ['pitch','wave','post']
    # Generate, never overwrite the production/board images.
    p=subprocess.run([sys.executable,str(ROOT/'rtl/router/tools/sustain_resources.py'),'--allow-retune','--out',str(out)],cwd=ROOT,capture_output=True,text=True)
    (out/'generate.log').write_text(p.stdout+p.stderr);p.check_returncode()
    import run_pitch
    run_pitch.vectors(out)
    manifest=json.loads((out/'manifest.json').read_text());image=(out/'sustain_flash.bin').read_bytes()
    profiles={(e['instrument'],e['midi']):e for e in manifest['entries']}
    import struct
    for inst in [2,3,4,5]:
        lines=[]
        for note in range(48,80):
            e=profiles[inst,note];lines.append(f'{e["period"]} {e["a_step"]} {e["r_step"]}')
            for mode in range(48):
                w=struct.unpack_from('>16i',image,inst*32*4096+(note-48)*4096+mode*64)
                lines.append(' '.join(str(w[i]) for i in [0,1,2,8,10,13]))
        (out/f'pitch_oracle_{inst}.txt').write_text('\n'.join(lines)+'\n')
    run('vlib',[work],'vlib')
    sources=re.findall(r"'((?:rtl|tb)/[^']+\.sv)'",(ROOT/'sim/router_sources.list').read_text())
    sources=[ROOT/p for p in sources if not p.endswith(('/tb_music.sv','/w25q_dut.sv'))]
    sources += [ROOT/p for p in ['rtl/midi/midi_note_state.sv','rtl/midi/midi_guide_state.sv','rtl/midi/midi_instrument_map.sv',
        'rtl/router/midi_voice_top.sv','sim/unit/midi/w25q64_read_model.sv','sim/unit/audio/tb_i2s_audio_output.sv',
        'sim/unit/audio/tb_eng1_pitch_system.sv','sim/unit/eng1/tb_eng1_model_trace.sv','sim/unit/eng1/tb_eng1_pitch_trace.sv',
        'sim/unit/eng1/tb_eng1_post_trace.sv']]
    run('vlog',['-sv','-work',work,*sources],'compile')
    results={}
    if 'post' in selected:
        results['post']=[]
        for h in [0,3,53]:
            run('vsim',['-c','-lib',work,'tb_eng1_post_trace',f'-gHEADROOM={h}',
                        '-l',out/f'post_{h}.transcript','-do','run -all; quit -f'],f'post_{h}')
            results['post'].append(compare_post(out/f'post_trace_{h}.txt',h))
        print('PASS Python/RTL post',results['post'],flush=True)
    if 'pitch' in selected:
        run('vsim',['-c','-lib',work,'tb_eng1_pitch_trace','-l',out/'pitch.transcript','-do','run -all; quit -f'],'pitch')
        results['pitch']=compare_pitch(out);print('PASS Python/RTL pitch',results['pitch'],flush=True)
    if 'wave' in selected:
        def wave(inst):
            run('vsim',['-c','-lib',work,'tb_eng1_model_trace',f'-gINST={inst}',f'-gSAMPLES={a.samples}',
                        '-l',out/f'wave_{inst}.transcript','-do','run -all; quit -f'],f'wave_{inst}')
            name=next(k for k,v in E.INSTRUMENTS.items() if v==inst)
            result=compare_wave(out/f'eng1_trace_{inst}.txt',E.ResourceBank.from_directory(out,name))
            print('PASS Python/RTL wave',name,result,flush=True)
            return name,result
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results['wave']=dict(pool.map(wave,[2,3,4,5]))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
