#!/usr/bin/env python3
"""Compare production recording transport in RTL and an actual Gowin netlist.

Checks descriptor acceptance through both comm_top/transport_link boundaries,
then independently decodes UART, SLIP, TYPE82, every payload byte and CRC.
Requires Gowin and Questa; never accesses or programs hardware.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess

ROOT=Path(__file__).resolve().parents[1]
TB=ROOT/'sim/unit/comm/tb_record_stream_gate.sv'
PROBE=ROOT/'sim/synth/record_stream_probe.sv'

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/record_stream_gate')
    ap.add_argument('--reuse-synthesis',action='store_true')
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    files=[ROOT/x for x in (ROOT/'rtl/platform/tang_mega_138k_pro/sources.f').read_text().splitlines()
           if x.strip() and not x.startswith('//')]+[PROBE]
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files+[TB]}
    env=os.environ.copy();env['QT_QPA_PLATFORM']='minimal';env['QT_OPENGL']='software'
    result={'passed':False,'scope':'production communication RTL vs Gowin synthesis; synthetic descriptor; no hardware','source_sha256':hashes}
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    def tool(name):
        return shutil.which(name) or str(Path('/opt/modelsim/questa_fse/bin')/name)
    def run(name,cmd,passed_text=None):
        p=subprocess.run(list(map(str,cmd)),cwd=out,env=env,capture_output=True,text=True,timeout=300)
        text=p.stdout+p.stderr;(out/(name+'.log')).write_text(text)
        failed=p.returncode!=0 or re.search(r'\*\* (?:Error|Fatal)|%Error|\bFAIL\b',text)
        if failed or (passed_text and passed_text not in text):
            print(text[-4500:]);return False
        print('PASS '+name,flush=True);return True
    if not args.reuse_synthesis:
        tcl=out/'run.tcl'
        tcl.write_text(f'create_project -name record_stream_probe -dir "{out}/synthesis" -pn GW5AST-LV138FPG676AES -device_version B -force\n'
                       'set_option -verilog_std sysv2017\nset_option -top_module record_stream_probe\n'+
                       ''.join(f'add_file "{p}"\n' for p in files)+'run syn\n')
        gowin=os.environ.get('GOWIN_BIN') or shutil.which('gw_sh') or str(Path.home()/'gowin/IDE/bin/gw_sh')
        if not run('synthesis',[gowin,tcl],'GowinSynthesis finish'):return 1
    for kind in ['rtl','gate']:
        work=out/(kind+'_work')
        if not run(kind+'_vlib',[tool('vlib'),work]):return 1
        if kind=='rtl':sources=files+[TB];defines=[]
        else:
            prim=Path(os.environ.get('GOWIN_PRIMITIVES',str(Path.home()/'gowin/IDE/simlib/gw5a/prim_sim.v')))
            sources=[prim,out/'synthesis/record_stream_probe/impl/gwsynthesis/record_stream_probe.vg',TB]
            defines=['+define+GATE']
        if not run(kind+'_compile',[tool('vlog'),'-sv','-work',work,*defines,*sources]):return 1
        if not run(kind+'_run',[tool('vsim'),'-c','-suppress','14408,16154','-lib',work,'tb_record_stream_gate','-do','run -all; quit -f'],'PASS tb_record_stream_gate'):return 1
    assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in hashes.items()),'sources changed during run'
    result.update(passed=True,rtl=True,gate=True,sources_unchanged=True)
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    return 0

if __name__=='__main__':raise SystemExit(main())
