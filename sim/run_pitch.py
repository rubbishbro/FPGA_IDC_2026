#!/usr/bin/env python3
"""ENG1 aftertouch, fractional excitation and real MIDI nominal-pitch integration."""
from pathlib import Path
import argparse,os,json,re,shutil,subprocess,sys,struct,random
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
import pitch_linear as P

def vectors(out):
    from run_aftertouch import vectors as aftertouch_vectors
    aftertouch_vectors(out)
    tables=json.loads((ROOT/'rtl/router/tools/pitch_tables.json').read_text());words=[0]*1024
    for key,base in [('pitch_ratio',0),('pitch_sine',512),('pitch_depth',768)]:words[base:base+len(tables[key])]=tables[key]
    (out/'pitch_tables.mem').write_text(''.join(f'{word:08x}\n' for word in words))
    import router_eng1 as R
    pm=[]
    for slot in range(16):
        table=R.build_b_table(['cello','flute','violin','trumpet'][slot%4],36+slot*2)
        pm.extend(P.modulation_words(table))
    (out/'pitch_params.txt').write_text('\n'.join(' '.join(str(row[i]) for i in [0,1,2,5,7]) for row in pm)+'\n')
    periods=[2,3,7,15,109,511,65535,4096,4,12,57,1000,271,8000,900,300]
    rng=random.Random(260630);phase_state=[0]*16;previous=0;deltas=[0]*16
    with (out/'pitch_phase.txt').open('w') as f:
        f.write(' '.join(map(str,periods))+'\n')
        for n in range(70000):
            gate=65535 if n<69000 else 0
            if 1000<=n<1100:gate&=~3
            clear=0x30 if n==5000 else 0;gate&=~clear
            trigger=65535 if n==0 else (0x104 if n in [200,4000,20000] else 0)
            if n%31==0 and n>100:
                deltas=[rng.randrange(-1800000,2200000) for _ in range(16)]
            # Force a carry beyond 40 bits at the longest period.
            deltas[6]=round((65535/58000.01-1)*(1<<24))
            pulse=0
            for slot,T in enumerate(periods):
                if clear>>slot&1 or not (gate>>slot&1):phase_state[slot]=0;continue
                onset=bool(trigger>>slot&1 or not(previous>>slot&1))
                phase_state[slot],hit=P.advance_phase(phase_state[slot],T,deltas[slot],onset)
                if hit:pulse|=1<<slot
            previous=gate
            f.write(' '.join(map(str,[gate,clear,trigger,pulse,*deltas]))+'\n')

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/eng1_pitch/unit')
    ap.add_argument('--test',action='append',choices=['unit','phase','system'])
    ap.add_argument('--samples',type=int,default=12000)
    ap.add_argument('--core-hz',type=int,default=50_000_000)
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    vectors(out)
    if 'system' in (args.test or ['unit','phase','system']):
        gen=subprocess.run([sys.executable,str(ROOT/'rtl/router/tools/sustain_resources.py'),'--allow-retune','--out',str(out)],cwd=ROOT,capture_output=True,text=True,timeout=120)
        (out/'generate.log').write_text(gen.stdout+gen.stderr)
        if gen.returncode:raise RuntimeError(gen.stderr)
        manifest=json.loads((out/'manifest.json').read_text())
        catalog=json.loads((ROOT/'rtl/router/tools/sustain_profiles.json').read_text())
        rows={(e['instrument'],e['midi']):e for e in catalog['entries']}
        image=(out/'sustain_flash.bin').read_bytes()
        for e in manifest['entries']:
            assert {k:v for k,v in e.items() if k!='coeff_sha256'}=={k:v for k,v in rows[e['instrument'],e['midi']].items() if k!='coeff_sha256'}
        for inst in [2,3,4,5]:
            lines=[]
            for note in range(48,80):
                row=rows[inst,note];lines.append(f'{row["period"]} {row["a_step"]} {row["r_step"]}')
                for m in range(48):
                    words=struct.unpack_from('>16i',image,inst*32*4096+(note-48)*4096+m*64)
                    lines.append(' '.join(str(words[i]) for i in [0,1,2,8,10,13]))
            (out/f'pitch_oracle_{inst}.txt').write_text('\n'.join(lines)+'\n')
    ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    work=out/'work';s=re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M)
    (out/'modelsim.ini').write_text(s);env=os.environ.copy();env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    def run(tool,options,name):
        p=subprocess.run([shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,options)],cwd=out,env=env,capture_output=True,text=True,timeout=1800)
        txt=p.stdout+p.stderr;(out/(name+'.log')).write_text(txt)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',txt):raise RuntimeError(name+'\n'+txt[-5000:])
        return txt
    run('vlib',[work],'vlib')
    sources=re.findall(r"'((?:rtl|tb)/[^']+\.sv)'",(ROOT/'sim/router_sources.list').read_text())
    sources=[ROOT/p for p in sources if not p.endswith('/tb_music.sv') and not p.endswith('/w25q_dut.sv')]
    sources += [ROOT/p for p in ['rtl/midi/midi_note_state.sv','rtl/midi/midi_guide_state.sv','rtl/midi/midi_instrument_map.sv','rtl/router/midi_voice_top.sv','sim/unit/midi/w25q64_read_model.sv','sim/unit/audio/tb_i2s_audio_output.sv','sim/unit/audio/tb_eng1_pitch.sv','sim/unit/audio/tb_pitch_excitation.sv']]
    if (ROOT/'sim/unit/audio/tb_eng1_pitch_system.sv').exists():sources.append(ROOT/'sim/unit/audio/tb_eng1_pitch_system.sv')
    run('vlog',['-sv','-work',work,*sources],'compile')
    results=[]
    for test in args.test or ['unit','phase','system']:
        top={'unit':'tb_eng1_pitch','phase':'tb_pitch_excitation','system':'tb_eng1_pitch_system'}[test]
        options=[] if test!='system' else [f'-gSAMPLES={args.samples}',f'-gCORE_HZ={args.core_hz}']
        txt=run('vsim',['-c','-lib',work,top,*options,'-do','run -all; quit -f'],top)
        summary=[v.lstrip('# ') for v in txt.splitlines() if 'PASS '+top in v]
        if not summary:raise RuntimeError('Missing PASS '+top)
        print('\n'.join(summary),flush=True);results.append(dict(test=top,passed=True,summary=summary))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
