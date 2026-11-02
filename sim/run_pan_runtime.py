#!/usr/bin/env python3
"""Exercise runtime pan through the production control loop and board backend (Verilator)."""
import os
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/pan_runtime'

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    compiler=os.environ.get('VERILATOR') or shutil.which('verilator')
    if not compiler:raise RuntimeError('set VERILATOR or install Verilator')
    sources=[ROOT/x for x in (ROOT/'rtl/platform/tang_mega_138k_pro/sources.f').read_text().splitlines()
             if '/ip/' not in x and x!='rtl/drivers/gowin_adc/gowin_adc.v']
    sources += [ROOT/x for x in ['rtl/router/parts/trumpet_excitation.sv',
                'sim/unit/board/board_ip_models.sv','sim/unit/board/tb_pan_runtime.sv']]
    with (OUT/'compile.log').open('w') as log:
        subprocess.run([compiler,'--binary','--timing','-Wno-fatal','--top-module','tb_instrument_board',
                        '--Mdir',str(OUT/'obj'),'-j','4',*map(str,dict.fromkeys(sources))],
                       stdout=log,stderr=subprocess.STDOUT,check=True)
    for memory in (ROOT/'rtl_FFT/board').glob('*.mem'):
        shutil.copyfile(memory,OUT/memory.name)
    tables=OUT/'rtl/drivers/pad_led_tables';tables.mkdir(parents=True,exist_ok=True)
    for memory in (ROOT/'rtl/drivers/pad_led_tables').glob('*.mem'):
        shutil.copyfile(memory,tables/memory.name)
    result=subprocess.run([str(OUT/'obj/Vtb_instrument_board')],cwd=OUT,
                          capture_output=True,text=True,timeout=60)
    (OUT/'run.log').write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr)
    result.check_returncode()
    if 'PASS runtime pan' not in result.stdout:raise RuntimeError('missing PASS')

if __name__=='__main__':main()
