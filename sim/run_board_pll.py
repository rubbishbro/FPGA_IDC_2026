#!/usr/bin/env python3
"""Validate the production three-output PLL/PLL_INIT with the vendor GW5A model."""
import argparse,json,os,re,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/board_pll')
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    ini=Path(os.environ.get('QSIM_INI') or str(Path.home()/'gowin/simlib_questa/modelsim.ini'))
    work=out/'work'
    (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M))
    env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
    sources=['rtl/platform/tang_mega_138k_pro/ip/'+s for s in ['gowin_pll_core_100m.v','gowin_pll_core_100m_mod.v','pll_init.v']]
    sources+=['sim/unit/board/tb_board_pll.sv']
    for tool,opts,name in [('vlib',[str(work)],'vlib'),('vlog',['-sv','-work',str(work),*[str(ROOT/s) for s in sources]],'compile'),
                          ('vsim',['-c','-L','gw5a','-lib',str(work),'tb_board_pll','-wlf',str(out/'pll.wlf'),'-do','run -all; quit -f'],'run')]:
        cmd=[shutil.which(tool) or str(Path.home()/'.local/bin'/tool),*opts]
        run=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True,timeout=120)
        output=run.stdout+run.stderr;(out/(name+'.log')).write_text(output)
        if run.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',output):
            raise RuntimeError(output[-5000:])
        if name=='run':
            summary=[line.lstrip('# ') for line in output.splitlines() if 'PASS tb_board_pll' in line]
            if not summary:raise RuntimeError('vendor PLL test did not complete')
            (out/'results.json').write_text(json.dumps(dict(test='tb_board_pll',passed=True,summary=summary),indent=2)+'\n')
            print('\n'.join(summary))
if __name__=='__main__':main()
