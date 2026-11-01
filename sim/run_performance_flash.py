#!/usr/bin/env python3
"""Validate deployment contract and four real Flash->router paths with Verilator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from check_performance_resources import check, ROOT


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'build/performance_flash_verify')
    parser.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
    args=parser.parse_args()
    exe=shutil.which(args.verilator)
    if exe is None:parser.error('Verilator is required for this optional RTL regression')
    contract=check(ROOT/'rtl/router/tools/performance')
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'verification.json').unlink(missing_ok=True)
    shutil.copyfile(ROOT/'rtl/router/tools/performance/resources.mem',out/'resources.mem')
    sources=re.findall(r"'(rtl/[^']+\.sv)'",(ROOT/'rtl/router/tools/run_all.ps1').read_text())
    sources=[ROOT/p for p in sources if not p.endswith(('/tb_music.sv','/w25q_dut.sv'))]
    sources += [ROOT/'sim/unit/midi/w25q64_read_model.sv',ROOT/'sim/unit/eng1/tb_performance_flash.sv']
    command=[exe,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal',
        '--top-module','tb_performance_flash','-j','4','--Mdir',str(out/'obj'),
        '-MAKEFLAGS','CFG_CXXFLAGS_PCH_I=-include',*map(str,sources)]
    (out/'compile_command.json').write_text(json.dumps(command,indent=2)+'\n')
    with (out/'compile.log').open('w') as log:
        subprocess.run(command,cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
    with (out/'simulation.log').open('w') as log:
        subprocess.run([str(out/'obj/Vtb_performance_flash')],cwd=out,stdout=log,
                       stderr=subprocess.STDOUT,check=True,timeout=600)
    output=(out/'simulation.log').read_text()
    if 'PASS tb_performance_flash loads=4 records=4096' not in output or 'FAIL' in output:
        raise RuntimeError(output)
    result=dict(passed=True,contract=contract,summary=output.splitlines(),
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(output)


if __name__=='__main__':main()
