#!/usr/bin/env python3
"""Exercise the LED wire protocol and the targeted storage/snapshot testbenches.

tb_led_pixel_ram checks the pixel-addressed synchronous RAM read with the
tightest enable spacing; tb_led_ram_scan checks the BSRAM wave-record write/read/scan path and the
framebuffer prefetch. Both replace the old prefetch-vs-direct comparison,
which became degenerate once every PIPELINED_READ setting mapped to the same
hardware.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess

ROOT=Path(__file__).resolve().parents[1]
TESTS={'protocol':'tb_led_protocol','pixel_ram':'tb_led_pixel_ram',
       'ram':'tb_led_ram_scan','effects':'tb_pad_led_effects'}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--verilator',default='verilator')
    ap.add_argument('--out',type=Path,default=ROOT/'build/led_protocol_verify')
    ap.add_argument('--test',action='append',choices=TESTS)
    a=ap.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'verification.json').unlink(missing_ok=True)
    production=['rtl/drivers/pkg/clk_rst_pkg.sv','rtl/drivers/pkg/pad_driver_pkg.sv',
                'rtl/drivers/pad_driver.sv','rtl/drivers/pad_led_effects.sv']
    results=[];sources=set(production)
    for name in a.test or TESTS:
        top=TESTS[name];tb=f'sim/unit/board/{top}.sv';sources.add(tb);obj=out/f'obj_{name}'
        command=[a.verilator,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal',
                 '--top-module',top,'-j','4','--Mdir',str(obj),
                 '-MAKEFLAGS','CXX=g++ LINK=g++ AR=ar CFG_CXXFLAGS_PCH_I=-include',
                 *[str(ROOT/p) for p in production+[tb]]]
        with (out/f'compile_{name}.log').open('w') as log:
            subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        p=subprocess.run([str(obj/f'V{top}')],cwd=ROOT,capture_output=True,text=True,timeout=120)
        output=p.stdout+p.stderr;(out/f'{name}.log').write_text(output)
        assert p.returncode==0 and f'PASS {top}' in output,output
        summary=[line for line in output.splitlines() if f'PASS {top}' in line]
        print('\n'.join(summary),flush=True);results.append(dict(test=top,passed=True,summary=summary))
    sources.update(str(p.relative_to(ROOT)) for p in (ROOT/'rtl/drivers/pad_led_tables').glob('*.mem'))
    report=dict(passed=True,tests=results,physical_programming_performed=False,
                source_hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sorted(sources)})
    (out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':main()
