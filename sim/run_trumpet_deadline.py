#!/usr/bin/env python3
"""Production Flash/router scheduling budget for 16 shared-datapath trumpet voices."""
import argparse,json,os,re,shutil,subprocess,sys
from pathlib import Path
from check_performance_resources import check,ROOT

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--out',type=Path,default=ROOT/'build/trumpet_tdm_20261102/deadline')
 p.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
 args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
 (out/'verification.json').unlink(missing_ok=True)
 contract=check(ROOT/'rtl/router/tools/performance')
 shutil.copyfile(ROOT/'rtl/router/tools/performance/resources.mem',out/'resources.mem')
 sources=re.findall(r"'((?:rtl|tb)/[^']+\.sv)'",(ROOT/'sim/router_sources.list').read_text())
 sources=[ROOT/x for x in sources if not x.endswith(('/tb_music.sv','/w25q_dut.sv'))]
 sources += [ROOT/'sim/unit/midi/w25q64_read_model.sv',ROOT/'sim/unit/audio/tb_trumpet_deadline.sv']
 with (out/'compile.log').open('w') as log:
  subprocess.run([args.verilator,'--binary','--timing','--timescale','1ns/1ps','-Wno-fatal',
   '--top-module','tb_trumpet_deadline','--Mdir',str(out/'obj'),'-j','4',*map(str,sources)],stdout=log,stderr=subprocess.STDOUT,check=True)
 r=subprocess.run([str(out/'obj/Vtb_trumpet_deadline')],cwd=out,capture_output=True,text=True,timeout=180)
 output=r.stdout+r.stderr;(out/'simulation.log').write_text(output);print(output);r.check_returncode()
 if 'PASS tb_trumpet_deadline' not in output:raise RuntimeError('missing PASS')
 sys.path.insert(0,str(ROOT/'python/modal_sim'))
 import eng1_rtl as E
 from run_eng1_model import compare_wave
 directory=ROOT/'rtl/router/tools/performance'
 manifest=json.loads((directory/'resources.json').read_text());raw=(directory/'resources.bin').read_bytes()
 notes={r['midi']:E.NoteResource.decode(r['midi'],raw[r['offset']:r['offset']+4096],r)
        for r in manifest['entries'] if r['name']=='trumpet' and r['slot']<16}
 parity=compare_wave(out/'trumpet_trace.txt',E.ResourceBank('trumpet',notes),min_checks=640,reverb='HALL')
 print('PASS deployed trumpet full-path integer parity',parity)
 (out/'verification.json').write_text(json.dumps({'passed':True,'contract':contract,'parity':parity,'summary':output},indent=2)+'\n')

if __name__=='__main__':main()
