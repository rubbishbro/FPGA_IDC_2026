#!/usr/bin/env python3
"""Questa: all production Flash regions/banks and modulation route contracts."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess
from check_performance_resources import check,ROOT

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'build/production_flash');p.add_argument('--test',nargs='+',default=['map','channels','flash'],choices=['map','channels','flash']);a=p.parse_args()
    directory=ROOT/'rtl/router/tools/performance';contract=check(directory)
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);work=out/'work'
    ini=Path(os.environ.get('QSIM_INI',str(Path.home()/'gowin/simlib_questa/modelsim.ini')))
    (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$',f'work = {work}',ini.read_text(),flags=re.M))
    env=os.environ.copy();env['QSIM_INI']=env['MODELSIM']=str(out/'modelsim.ini')
    def run(name,tool,args):
        exe=shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
        r=subprocess.run([exe,*map(str,args)],cwd=out,env=env,capture_output=True,text=True,timeout=1200)
        text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
        if r.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-4000:])
        return text
    run('vlib','vlib',[work])
    sources=[ROOT/s.strip("'") for s in (ROOT/'sim/router_sources.list').read_text().splitlines() if s.startswith("'") and '/tb/' not in s]
    sources += [ROOT/'rtl/midi/midi_instrument_map.sv',ROOT/'sim/unit/midi/w25q64_read_model.sv',ROOT/'sim/unit/eng1/tb_performance_flash.sv',ROOT/'sim/unit/audio/tb_mod_router_channels.sv',ROOT/'sim/unit/midi/tb_production_instrument_map.sv']
    run('compile','vlog',['-sv','-work',work,*sources]);shutil.copyfile(directory/'resources.mem',out/'resources.mem')
    tests={'map':'tb_production_instrument_map','channels':'tb_mod_router_channels','flash':'tb_performance_flash'};results={}
    for name in a.test:
        top=tests[name];text=run(name,'vsim',['-c','-lib',work,top,'-do','run -all; quit -f'])
        assert 'PASS '+top in text
        results[name]=[s.lstrip('# ') for s in text.splitlines() if 'PASS ' in s]
        print('\n'.join(results[name]),flush=True)
    (out/'results.json').write_text(json.dumps(dict(passed=True,contract=contract,tests=results,source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}),indent=2))
if __name__=='__main__':main()
