#!/usr/bin/env python3
"""Compare LED storage/shared-radius changes to immutable production RTL.

Period 1 (one clk_en per core clock) is deliberately excluded: the synchronous
pixel RAM read in led8x8 needs at least two core clocks per enable, and the
board pad tick is one enable per 20 core clocks. The targeted tests in
run_led_protocol.py cover the new mechanics directly.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess

ROOT = Path(__file__).resolve().parents[1]
# LED source hashes match the archived, programmed led_joy_board build.
# This predates reset removal and pixel-RAM changes, but already fixes bit order.
BASELINE = "1da4a41afd176599dd50edaea64f1a33dea36288"

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=ROOT/'build/led_storage_tests')
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out/'results.json').unlink(missing_ok=True)
    tables = out/'rtl/drivers/pad_led_tables'
    tables.mkdir(parents=True, exist_ok=True)
    for memory in (ROOT/'rtl/drivers/pad_led_tables').glob('*.mem'):
        shutil.copyfile(memory,tables/memory.name)
    ini = Path.home()/'gowin/simlib_questa/modelsim.ini'
    work = out/'work'
    (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$', 'work = '+str(work), ini.read_text(), flags=re.M))
    env = dict(os.environ, QSIM_INI=str(out/'modelsim.ini'), MODELSIM=str(out/'modelsim.ini'))
    def run(tool, argv, name):
        result = subprocess.run([shutil.which(tool) or str(Path.home()/'.local/bin'/tool), *map(str,argv)],
            cwd=out, env=env, capture_output=True, text=True, timeout=300)
        text = result.stdout+result.stderr
        (out/(name+'.log')).write_text(text)
        if result.returncode or re.search(r'\*\* (?:Error|Fatal)|\b(?:FAIL|FATAL)\b',text):
            raise RuntimeError(name+'\n'+text[-5000:])
        return text
    def module(source, name):
        return re.search(r'\bmodule '+name+r'\b.*?\bendmodule\b',source,re.S)[0]
    paths = ['rtl/drivers/pad_driver.sv','rtl/drivers/pad_led_effects.sv']
    originals = {p:subprocess.check_output(['git','show',BASELINE+':'+p],cwd=ROOT,text=True) for p in paths}
    current_driver = (ROOT/paths[0]).read_text()
    generated = out/'driver_modules.sv'
    generated.write_text('import clk_rst_pkg::*;\nimport pad_driver_pkg::*;\n'+
        module(current_driver,'led8x8')+'\n'+module(current_driver,'shift_timer')+'\n'+
        module(originals[paths[0]],'led8x8').replace('module led8x8 ', 'module led8x8_reference ',1))
    reference = out/'effects_reference.sv'
    reference.write_text(originals[paths[1]].replace('module pad_led_effects ', 'module pad_led_effects_reference ',1))
    run('vlib',[work],'vlib')
    run('vlog',['-sv','-work',work,ROOT/'rtl/drivers/pkg/clk_rst_pkg.sv',
        ROOT/'rtl/drivers/pkg/pad_driver_pkg.sv',generated,ROOT/paths[1],reference,
        ROOT/'sim/unit/board/tb_led_storage_equivalence.sv'],'compile')
    results=[]
    for period in (2,4,20):
        text=run('vsim',['-c','-lib',work,'tb_led_storage_equivalence',f'-gCE_PERIOD={period}',
            '-wlf',out/f'ce{period}.wlf','-do','run -all; quit -f'],f'ce{period}')
        summary=[line for line in text.splitlines() if 'PASS tb_led_storage_equivalence' in line]
        if not summary:raise RuntimeError('simulation missing PASS: '+text[-2000:])
        print('\n'.join(summary),flush=True)
        results.append(dict(ce_period=period,passed=True,summary=summary))
    hashes={p:dict(baseline=hashlib.sha256(originals[p].encode()).hexdigest(),
        current=hashlib.sha256((ROOT/p).read_bytes()).hexdigest()) for p in paths}
    (out/'results.json').write_text(json.dumps(dict(baseline=BASELINE,inputs=hashes,tests=results),indent=2)+'\n')

if __name__=='__main__':main()
