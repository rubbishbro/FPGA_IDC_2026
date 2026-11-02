#!/usr/bin/env python3
"""Sidebar functional regression and unchanged visualization regression (Icarus)."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from run_control_loop import executable

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/sidebar'
BOARD=ROOT/'rtl_FFT/board'
BASE=(ROOT/'sim/ui_sources.f').read_text().splitlines()


def run(name,top,sources,parameters=(),args=(),cwd=BOARD):
    image=OUT/f'{name}.vvp'
    cmd=[executable('iverilog','IVERILOG'),'-g2012','-s',top,
         *[f'-P{top}.{k}={v}' for k,v in parameters],'-o',str(image),
         *[str(ROOT/s) for s in dict.fromkeys(sources)]]
    compiled=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
    (OUT/f'{name}.compile.log').write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode:raise RuntimeError(compiled.stdout+compiled.stderr)
    result=subprocess.run([executable('vvp','VVP'),str(image),*args],cwd=cwd,capture_output=True,text=True,timeout=90)
    output=result.stdout+result.stderr
    (OUT/f'{name}.log').write_text(output)
    print(output.strip()[-1000:])
    if result.returncode or ('PASS ' not in output and 'TEST PASSED' not in output):
        raise RuntimeError(f'{name} failed: {output}')
    return {'test':name,'pass':True}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--legacy',action='store_true');args=p.parse_args()
    OUT.mkdir(parents=True,exist_ok=True);results=[]
    (OUT/'results.json').unlink(missing_ok=True)
    for half in (7,11):
        results.append(run(f'system_{half}','tb_sidebar_system',BASE+['sim/unit/control/tb_sidebar_system.sv'],[('PIX_HALF',half)]))
    results.append(run('render','tb_sidebar_render',BASE+['sim/unit/control/tb_sidebar_render.sv'],args=[f'+image={OUT}/sidebar.ppm']))
    for line in (ROOT/'sim/unit/control/sidebar_render.sha256').read_text().splitlines():
        if not line or line.startswith('#'):continue
        expected,name=line.split()
        actual=hashlib.sha256((OUT/name).read_bytes()).hexdigest()
        if actual!=expected:raise RuntimeError(f'{name} changed golden pixels: {actual}')
    print('PASS sidebar golden pixels: both images unchanged')
    results.append(run('guide_render','tb_guide_render',BASE+['sim/unit/control/tb_guide_render.sv'],args=[f'+image={OUT}/guide.ppm']))
    if args.legacy:
        packages=[s for s in BASE if s.endswith('pkg.sv')]
        src=packages+[str(path.relative_to(ROOT)) for path in sorted((ROOT/'rtl_FFT/src').rglob('*'))
                      if path.suffix in ('.v','.sv') and not path.name.endswith('pkg.sv')]
        src+=['rtl/control_loop.sv','rtl/config_dispatch.sv','rtl/drivers/joystick_adapter.sv']
        tests=['sweep_source_tb','spectrum_map_tb','wave_capture_tb','waterfall_tb','trail_calc_tb','curve_calc_tb',
               'lcd_curve_spectrum_tb','lcd_ui_tb','lcd_effects_tb','ui_key_ctrl_tb','ui_dual_key_tb',
               'lcd_fft_tb','lcd_fft_align_tb','chain_tb']
        for top in tests:
            tb=ROOT/'rtl_FFT/sim'/f'{top}.sv'
            if not tb.exists():tb=tb.with_suffix('.v')
            results.append(run(top,top,src+[str(tb.relative_to(ROOT))],cwd=ROOT/'rtl_FFT/sim'))
    (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(f'PASS {len(results)} UI/visualization cases')


if __name__=='__main__':main()
