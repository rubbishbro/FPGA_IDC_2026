#!/usr/bin/env python3
"""Questa regressions for real eng1 B resources, per-slot drive and release retirement."""
from pathlib import Path
import argparse,json,os,re,shutil,struct,subprocess
ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/sustain/full')
    ap.add_argument('--test',action='append',choices=['frontend','config','system'])
    ap.add_argument('--inst',action='append',type=int,choices=[2,3,4,5])
    ap.add_argument('--samples',type=int,default=48000)
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    py=os.environ.get('SUSTAIN_PYTHON') or str(Path.home()/'micromamba/envs/torch312/bin/python')
    gen=subprocess.run([py,str(ROOT/'rtl/router/tools/sustain_resources.py'),'--allow-retune','--out',str(out)],cwd=ROOT,capture_output=True,text=True,timeout=120)
    (out/'generate.log').write_text(gen.stdout+gen.stderr)
    if gen.returncode:raise RuntimeError(gen.stderr)
    manifest=json.loads((out/'manifest.json').read_text());image=(out/'sustain_flash.bin').read_bytes()
    rows={(e['instrument'],e['midi']):e for e in manifest['entries']}
    catalog=json.loads((ROOT/'rtl/router/tools/sustain_profiles.json').read_text())
    catalog_rows={(e['instrument'],e['midi']):e for e in catalog['entries']}
    for row in manifest['entries']:
        if row!=catalog_rows.get((row['instrument'],row['midi'])):
            raise RuntimeError('generated image and checked-in profile catalog differ; regenerate both')

    text=''
    for inst in [2,3,4,5]:
        text+=f'{inst}\n'
        for note in [69,73,60,76]:
            row=rows[inst,note];text+=f'{note} {row["period"]} {row["a_step"]} {row["r_step"]}\n'
        fields=[]
        for note in range(48,80):
            row=rows[inst,note];fields.append(f'{row["period"]} {row["a_step"]} {row["r_step"]}')
            off=inst*32*4096+(note-48)*4096
            for mode in range(48):
                g,a1,a2=struct.unpack_from('>iii',image,off+mode*64)
                fields.append(f'{g} {a1} {a2}')
        (out/f'oracle_{inst}.txt').write_text('\n'.join(fields)+'\n')
    (out/'frontend_cases.txt').write_text(text)
    ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    s=ini.read_text();work=out/'work';s=re.sub(r'^work\s*=.*$','work = '+str(work),s,flags=re.M)
    (out/'modelsim.ini').write_text(s);env=os.environ.copy();env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    def run(tool,options,name):
        cmd=[shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,options)]
        p=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True,timeout=3600)
        txt=p.stdout+p.stderr;(out/(name+'.log')).write_text(txt)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',txt):raise RuntimeError(name+'\n'+txt[-5000:])
        return txt
    run('vlib',[work],'vlib')
    src=re.findall(r"'(rtl/[^']+\.sv)'",(ROOT/'rtl/router/tools/run_all.ps1').read_text())
    src=[ROOT/p for p in src if not p.endswith('/tb_music.sv') and not p.endswith('/w25q_dut.sv')]
    src += [ROOT/p for p in ['rtl/midi/midi_note_state.sv','rtl/midi/midi_instrument_map.sv','rtl/router/midi_voice_top.sv',
        'rtl/router/pad_voice_top.sv','sim/unit/midi/w25q64_read_model.sv','sim/unit/audio/tb_i2s_audio_output.sv',
        'sim/unit/audio/tb_sustain_frontend.sv','sim/unit/audio/tb_sustain_config.sv']]
    if (ROOT/'sim/unit/audio/tb_sustain_system.sv').exists():src.append(ROOT/'sim/unit/audio/tb_sustain_system.sv')
    run('vlog',['-sv','-work',work,*src],'compile')
    selected=args.test or ['frontend','config','system'];cases=[]
    if 'frontend' in selected:cases.append(('tb_sustain_frontend',{}))
    if 'config' in selected:cases.append(('tb_sustain_config',{}))
    if 'system' in selected:
        for inst in args.inst or [2,3,4,5]:cases.append(('tb_sustain_system',{'INST':inst,'SAMPLES':args.samples}))
    results=[]
    for top,params in cases:
        name=top+''.join(f'_{k}{v}' for k,v in params.items())
        txt=run('vsim',['-c','-lib',work,top,*[f'-g{k}={v}' for k,v in params.items()],'-wlf',out/(name+'.wlf'),'-do','run -all; quit -f'],name)
        summary=[line.lstrip('# ') for line in txt.splitlines() if 'PASS '+top in line]
        if not summary:raise RuntimeError(name+' missing PASS')
        print('\n'.join(summary),flush=True);results.append(dict(test=top,parameters=params,passed=True,summary=summary))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
