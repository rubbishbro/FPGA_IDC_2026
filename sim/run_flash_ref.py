#!/usr/bin/env python3
"""Questa: pristine vendor W25Q128 model + real loader, then real music smoke.

Private model images and working directories; no tracked testbench is rewritten.
"""
from pathlib import Path
import argparse,json,os,re,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/flash_ref')
    ap.add_argument('--samples',type=int,default=512)
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    work=out/'work';ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    text=re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M)
    (out/'modelsim.ini').write_text(text);env=os.environ.copy();env['QSIM_INI']=str(out/'modelsim.ini');env['MODELSIM']=env['QSIM_INI']
    def run(tool,options,cwd,name):
        cmd=[shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*map(str,options)]
        p=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=180)
        txt=p.stdout+p.stderr;(out/(name+'.log')).write_text(txt)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',txt):raise RuntimeError(name+'\n'+txt[-4000:])
        return txt
    run('vlib',[work],out,'vlib')
    paths=re.findall(r"'((?:rtl|tb)/[^']+\.(?:sv|v))'",(ROOT/'sim/router_sources.list').read_text())
    run('vlog',['-sv','-work',work,*[ROOT/p for p in paths],ROOT/'rtl/tb/router/tb_loader_ref.sv'],out,'compile')
    cases=[('loader_piano',0,0,False),('loader_guitar',1,0,False),('loader_blank',0,1,False),
           ('music_piano',0,0,True),('music_guitar',1,0,True)]
    results=[]
    for name,inst,blank,music in cases:
        cwd=out/name;cwd.mkdir(exist_ok=True)
        golden=cwd/'rtl/router/tools';golden.mkdir(parents=True,exist_ok=True)
        for instrument in ['piano','guitar']:
            raw=(ROOT/f'rtl/router/tools/coefficients/eng0_{instrument}.bin').read_bytes()
            (golden/f'{instrument}_flash.mem').write_text(''.join(f'{v:02X}\n' for v in raw))
        for f in ['SECSI.TXT','SFDP.TXT','SREG.TXT']:shutil.copyfile(ROOT/'rtl/tb/router/vendor/w25q128'/f,cwd/f)
        vals=['FF']*65536 if blank else (golden/('guitar_flash.mem' if inst else 'piano_flash.mem')).read_text().split()
        if music:vals=(ROOT/'rtl/router/tools/performance/resources.mem').read_text().split()
        (cwd/'MEM.TXT').write_text('@0\n'+'\n'.join(vals)+'\n')
        if music:
            (cwd/'_analysis').mkdir(exist_ok=True);(cwd/'_analysis/case.txt').write_text(f'{inst}\n0\n{args.samples}\n')
            top='tb_music';params=[f'-gNSAMP={args.samples}',f'-gHOLD={args.samples//2}']
        else:top='tb_loader_ref';params=[f'-gINST={inst}',f'-gBLANK={blank}','-gN_MODES=64']
        txt=run('vsim',['-c','-lib',work,top,*params,'-wlf',cwd/'wave.wlf','-do','run -all; quit -f'],cwd,name)
        if 'RESULT: PASS' not in txt:raise RuntimeError(name+' missing PASS')
        print('PASS '+name,flush=True);results.append(dict(test=name,passed=True,samples=args.samples if music else None))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()
