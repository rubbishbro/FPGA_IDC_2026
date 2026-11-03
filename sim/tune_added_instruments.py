#!/usr/bin/env python3
"""Current Flash -> integer model PCM -> gain choice -> ENG1/body RTL PCM.

Calibration follows the existing MIDI69 -12 dBFS sliding-20ms reference with
a -1 dBFS reference peak ceiling. MIDI60/72 are separate range probes; drums
use their six GM notes. No per-file audio
normalization is used. Resource generation/flashing is deliberately separate.
"""
from pathlib import Path
import argparse,concurrent.futures,hashlib,json,math,os,re,shutil,struct,subprocess,sys
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'sim'),str(ROOT/'python/modal_sim')]
from calibrate_reference_gains import ReferencePerformance,metrics,STRIKES
import router_eng1 as R
from render_drum_excitation_compare import production_bank

NEW={'oboe':6,'banjo':8,'mandolin':9,'piano_abc':10,'guitar_abc':11}
DIRECTORY=ROOT/'rtl/router/tools/performance'
OUT=ROOT/'build/timbre_tuning_20261104'

def pitched_job(name,note,out):
    out=Path(out);manifest=json.loads((DIRECTORY/'resources.json').read_text());image=(DIRECTORY/'resources.bin').read_bytes()
    synth=ReferencePerformance(name,manifest,image,note)
    hold=384000 if name=='oboe' else 192000;count=hold+48000
    raw=np.empty(count,dtype=np.int64);trace=np.empty((count,4),dtype=np.int64) if note==69 else None
    core_step=synth.core.step;observed={}
    if trace is not None:
        def core_tap(x,zero,**kwargs):
            y,state=core_step(x,zero,**kwargs);observed.update(x=int(x[0]),zero=int(zero[0]),y=int(y[0]));return y,state
        synth.core.step=core_tap
    for n in range(count):
        old=int(synth.env.level[0]);raw[n]=synth.sample(n,hold)
        if trace is not None:
            env=(0 if n==0 else old) if name in STRIKES else int(synth.env.level[0])
            trace[n]=[observed['x'],env,observed['zero'],observed['y']]
    np.save(out/f'{name}_{note}_raw.npy',raw)
    if trace is not None:np.save(out/f'{name}_trace.npy',trace)
    result=metrics(raw);result.update(state_saturations=synth.rails,body_saturations=synth.body.sat_total,samples=count)
    return f'{name}_{note}',result

def drum_job(out):
    out=Path(out);m=json.loads((DIRECTORY/'resources.json').read_text());image=(DIRECTORY/'resources.bin').read_bytes()
    rows=[]
    for row,engine,raw,drive,levels,stats in production_bank(m,image):
        key='drum_'+row['drum'];np.save(out/f'{key}_raw.npy',raw)
        # Keep the un-enveloped engine sum for the independent RTL oracle.
        np.save(out/f'{key}_trace.npy',np.column_stack([drive,levels,np.zeros(len(drive),dtype=np.int64),engine]))
        result=metrics(raw);result.update(stats,samples=len(raw),gm=row['midi']);rows.append((key,result))
    return rows

def prepare(out,workers):
    out.mkdir(parents=True,exist_ok=True);results={}
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
        futures=[pool.submit(pitched_job,name,note,str(out)) for name in NEW for note in (60,69,72)]
        drums=pool.submit(drum_job,str(out))
        for job in concurrent.futures.as_completed(futures):
            key,row=job.result();results[key]=row;print('RENDER',key,json.dumps(row),flush=True)
        for key,row in drums.result():results[key]=row;print('RENDER',key,json.dumps(row),flush=True)
    (out/'measurements.json').write_text(json.dumps({'image_sha256':hashlib.sha256((DIRECTORY/'resources.bin').read_bytes()).hexdigest(),'results':results},indent=2)+'\n')

def calibrate(out,apply):
    report=json.loads((out/'measurements.json').read_text());rows=report['results'];pkgpath=ROOT/'rtl/router/pkg/router_pkg.sv';pkg=pkgpath.read_text()
    before=out/'before/router_pkg.sv'
    old={name.lower():int(q) for name,q in re.findall(r"INST_(\w+):\s*return 16'sd(\d+)",before.read_text() if before.exists() else pkg)}
    target=10**(-12/20);peak_limit=10**(-1/20);chosen={}
    for name in NEW:
        reference=rows[f'{name}_69'];worst=reference['raw_peak']
        probe_peak=max(rows[f'{name}_{note}']['raw_peak'] for note in (60,69,72))
        q=min(round(4096*target/reference['max20ms_rms']),math.floor(4096*peak_limit/worst),32767)
        if q<=0:raise RuntimeError(f'Unrepresentable trim {name}')
        chosen[name]={'old_q12':old[name],'new_q12':q,'delta_db':20*math.log10(q/old[name]),'reference_rms_dbfs':20*math.log10(reference['max20ms_rms']*q/4096),'reference_peak_dbfs':20*math.log10(worst*q/4096),'probe_60_69_72_peak_dbfs':20*math.log10(probe_peak*q/4096)}
    drums=[row for key,row in rows.items() if key.startswith('drum_')]
    loudest=max(drums,key=lambda row:row['max20ms_rms']);worst=max(row['raw_peak'] for row in drums)
    q=min(round(4096*target/loudest['max20ms_rms']),math.floor(4096*peak_limit/worst),32767)
    chosen['drums']={'old_q12':old['drums'],'new_q12':q,'delta_db':20*math.log10(q/old['drums']),'reference_rms_dbfs':20*math.log10(loudest['max20ms_rms']*q/4096),'swept_peak_dbfs':20*math.log10(worst*q/4096)}
    if apply:
        for name,row in chosen.items():pkg=re.sub(r"(INST_"+name.upper()+r":\s*return 16'sd)\d+",lambda match:match[1]+str(row['new_q12']),pkg)
        if 'Added instruments: current ADSR' not in pkg:pkg=pkg.replace('    // Reference-note calibration does not guarantee full-range/polyphonic peaks.','    // Added instruments: current ADSR, MIDI69 peak <= -1dBFS;\n    // drum trim uses actual production coefficients/excitation, balance applied once.\n    // Reference-note calibration does not guarantee full-range/polyphonic peaks.')
        pkg=pkg.replace('            // TODO: MIDI69 calibrated peak is about +0.69dBFS at headroom0.\n            // Accepted temporary overshoot; retain the requested RMS target.\n','')
        pkgpath.write_text(pkg)
    for key,row in rows.items():
        name='drums' if key.startswith('drum_') else key.rsplit('_',1)[0]
        gain=chosen[name]['new_q12']/4096;raw=np.load(out/f'{key}_raw.npy')
        audio=raw.astype(float)/(1<<24)*gain
        sf.write(out/f'{key}_model_pcm.wav',audio,48000,subtype='PCM_24')
    (out/'gain_decisions.json').write_text(json.dumps({'target_reference_rms_dbfs':-12,'reference_midi':69,'reference_peak_ceiling_dbfs':-1,'range_probes':[60,69,72],'range_probes_are_not_peak_capped':True,'applied':apply,'gains':chosen},indent=2)+'\n')
    print(json.dumps(chosen,indent=2),flush=True)

def verify_rtl(out,workers=4,reuse=False):
    gains=json.loads((out/'gain_decisions.json').read_text())['gains'];manifest=json.loads((DIRECTORY/'resources.json').read_text());image=(DIRECTORY/'resources.bin').read_bytes()
    previous_compile_time=(out/'compile.log').stat().st_mtime if (out/'compile.log').exists() else 0
    work=out/'rtl_work';ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')))
    (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M));env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
    def run(name,tool,args,cwd=None):
        exe=shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
        p=subprocess.run([exe,*map(str,args)],cwd=cwd or out,env=env,capture_output=True,text=True,timeout=1200)
        text=p.stdout+p.stderr;(out/f'{name}.log').write_text(text)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b|Trouble making server|couldn.t open socket',text):raise RuntimeError(text[-5000:])
        return text
    run('vlib','vlib',[work])
    sources=['rtl/math/pkg/fxp_pkg.sv','rtl/router/pkg/modal_step_pkg.sv','rtl/router/pkg/router_pkg.sv','rtl/router/pkg/trumpet_excitation_pkg.sv','rtl/router/parts/envelope.sv','rtl/router/parts/excitation.sv','rtl/router/parts/trumpet_excitation.sv','rtl/router/routers/exc_router.sv','rtl/router/routers/env_router.sv','rtl/router/engines/eng1.sv','rtl/router/parts/body_biquad.sv','rtl/router/routers/body_router.sv','sim/unit/audio/tb_added_instrument_pcm.sv']
    reuse_valid=reuse and all((ROOT/p).stat().st_mtime <= previous_compile_time for p in sources)
    run('compile','vlog',['-sv','-work',work,*[ROOT/p for p in sources]])
    results={};playlist=[]
    cases=[(name,name,69) for name in NEW]+[(f'drum_{r["drum"]}','drums',r['midi']) for r in manifest['entries'] if r['name']=='drums']
    def run_case(case):
        key,name,note=case
        case_dir=out/'rtl_cases'/key;case_dir.mkdir(parents=True,exist_ok=True)
        row=next(r for r in manifest['entries'] if r['name']==name and r['midi']==note);trace=np.load(out/f'{key}_trace.npy')
        cfg=manifest['frontends'][name]
        aa=row.get('a_step',cfg.get('a_step',1));rr=row.get('r_step',cfg.get('r_step',1))
        (case_dir/'pcm_frontend.txt').write_text(f'{row.get("period",2)} {aa} {rr} {len(trace)-48000}\n')
        co=np.frombuffer(image[row['offset']:row['offset']+4096],dtype='>u4').reshape(64,16)
        (case_dir/'pcm_coefficients.mem').write_text(''.join(''.join(f'{int(x):08x}' for x in words[:7])+'\n' for words in co))
        body=R.BodyFilter(instrument=name);q=gains[name]['new_q12'];expected=np.empty(len(trace),dtype=np.int64)
        with (case_dir/'pcm_vectors.txt').open('w') as f:
            for i,(x,envelope,zero,engine) in enumerate(trace):
                mixed=(int(engine)*int(envelope))>>31;scaled=(mixed*q+2048)>>12;wanted=body.step(scaled)[0];expected[i]=wanted
                f.write(f'{int(x)&0xffffffff:08x} {int(envelope)&0xffffffff:08x} {int(zero)} {int(engine)&0xffffffffffffffff:016x} {wanted&0xffffffffffffffff:016x}\n')
        cached=(out/f'{key}.log').read_text() if (out/f'{key}.log').exists() else ''
        if reuse_valid and 'PASS tb_added_instrument_pcm' in cached and (case_dir/'rtl_pcm.txt').exists():
            text=cached
        else:
            text=run(key,'vsim',['-c','-lib',work,'tb_added_instrument_pcm',f'-gINSTRUMENT={row["instrument"]}',f'-gSAMPLES={len(trace)}','-do','run -all; quit -f'],cwd=case_dir)
        if 'PASS tb_added_instrument_pcm' not in text:raise RuntimeError(text)
        actual=np.loadtxt(case_dir/'rtl_pcm.txt',dtype=np.int64)
        if not np.array_equal(actual[:,0],expected):raise RuntimeError(f'{key}: body output differs')
        wanted_pcm=np.clip((expected+256)>>9,-32768,32767)
        if not np.array_equal(actual[:,1],wanted_pcm):raise RuntimeError(f'{key}: PCM conversion differs')
        sf.write(out/f'{key}_rtl_pcm.wav',actual[:,1].astype(np.int16),48000,subtype='PCM_16')
        result=dict(samples=len(trace),gain_q12=q,peak=float(np.max(np.abs(expected)))/(1<<24),rms20_dbfs=metrics(expected)['raw_max20ms_dbfs'],pcm_clipped=int(np.count_nonzero((wanted_pcm==32767)|(wanted_pcm==-32768))),body_saturations=body.sat_total)
        print('RTL PASS',key,json.dumps(result),flush=True)
        return key,result
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for key,result in pool.map(run_case,cases):results[key]=result
    for key,_,_ in cases:
        pcm,_=sf.read(out/f'{key}_rtl_pcm.wav',dtype='int16')
        playlist.extend([pcm,np.zeros(12000,dtype=np.int16)])
    sf.write(out/'added_instruments_rtl_comparison.wav',np.concatenate(playlist),48000,subtype='PCM_16')
    (out/'rtl_verification.json').write_text(json.dumps({'passed':True,'resource_image_sha256':hashlib.sha256(image).hexdigest(),'conditions':{'reference_midi':69,'pressure':255,'polyphony':1,'reverb':'NONE','modulation':'off','pcm_headroom_bits':0,'sliding_rms_samples':960,'pcm_sample_rate':48000},'sources_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},'results':results},indent=2)+'\n')
    if (out/'original_six_reference_model.wav').exists():
        original,_=sf.read(out/'original_six_reference_model.wav',dtype='int16')
        sf.write(out/'original_reference_then_added_rtl.wav',np.concatenate([original,np.zeros(24000,dtype=np.int16),*playlist]),48000,subtype='PCM_16')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,default=OUT);parser.add_argument('--stage',choices=['render','calibrate','rtl'],required=True);parser.add_argument('--workers',type=int,default=4);parser.add_argument('--apply',action='store_true');parser.add_argument('--reuse',action='store_true',help='Recheck completed RTL outputs against freshly computed full vectors');a=parser.parse_args();a.out=a.out.resolve()
    if a.stage=='render':prepare(a.out,a.workers)
    elif a.stage=='calibrate':calibrate(a.out,a.apply)
    else:verify_rtl(a.out,a.workers,a.reuse)
