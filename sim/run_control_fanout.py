#!/usr/bin/env python3
"""Verilator reset/CE parity against a pinned pre-change source snapshot."""
from pathlib import Path
import argparse,json,re,subprocess,shutil
ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'build/high_fanout_20261103/equivalence')
    ap.add_argument('--baseline-dir',type=Path,default=ROOT/'build/high_fanout_20261103/baseline/source')
    ap.add_argument('--test',action='append',choices=['parts','play_table'])
    args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    tool=shutil.which('verilator') or str(ROOT/'build/verilator_env/bin/verilator')
    baseline=args.baseline_dir.resolve()
    changed=['rtl/router/parts/envelope.sv','rtl/router/parts/excitation.sv','rtl/router/routers/env_router.sv','rtl/router/routers/exc_router.sv','rtl/router/routers/mod_router.sv','rtl/router/routers/eng_router.sv','rtl/router/voice_router.sv']
    legacy=out/'legacy';legacy.mkdir(exist_ok=True)
    modules=['envelope_ADSR','envelope_dyn0','excitation_gen','env_router','exc_router','mod_router','eng_router','voice_router']
    for name in changed:
        text=(baseline/name).read_text()
        for mod in modules:text=re.sub(r'\b'+mod+r'\b',mod+'_legacy',text)
        if name.endswith('/voice_router.sv'):text=text.replace('voice_router_legacy','voice_router_reference')
        (legacy/Path(name).name).write_text(text)
    for memory in (ROOT/'rtl_FFT/board').glob('*.mem'):shutil.copyfile(memory,out/memory.name)
    sources=re.findall(r"'((?:rtl|tb)/[^']+\.sv)'",(ROOT/'sim/router_sources.list').read_text())
    sources=[ROOT/s for s in sources if not s.startswith(('rtl/tb/','rtl/audio/'))]
    sources += [ROOT/s for s in ['rtl/midi/midi_note_state.sv','rtl/midi/midi_guide_state.sv','rtl/midi/midi_instrument_map.sv','rtl/router/midi_voice_top.sv','rtl/router/pad_voice_top.sv','sim/unit/midi/w25q64_read_model.sv']]
    tops={'parts':('tb_control_fanout',[*legacy.glob('*.sv'),ROOT/'sim/unit/audio/tb_control_fanout.sv']),
          'play_table':('tb_router_play_table',[*legacy.glob('*.sv'),ROOT/'sim/unit/midi/tb_router_play_table.sv'])}
    results=[]
    (out/'play_table.mem').write_text('00\n'*(12*4*64*64+4096))
    # Exercise the real voice-router copies, in addition to the leaf parts.
    probe=(ROOT/'sim/unit/midi/tb_router_play_table.sv').read_text()
    probe=probe.replace('    integer stage=0;', '    integer stage=0,nonzero_audio_frames=0;')
    probe=probe.replace('        cycles++;', '        cycles++;\n        if(rst_n && yv && y!=0)nonzero_audio_frames++;')
    probe=probe.replace('        if(rst_n)begin\n            if({valid', '        if(rst_n)begin\n            if(dut.part_tick!==dut.part_tick_exc || dut.part_tick!==dut.part_tick_env)\n                $fatal(1,"FAIL actual router tick copies");\n            for(int g=0;g<dut.CHILD_RESETS;g++)\n                if(dut.child_reset[2*g +:2]!==dut.child_reset[1:0])$fatal(1,"FAIL actual reset leaves");\n            if({valid')
    probe=probe.replace('        $display("PASS tb_router_play_table', '        if(nonzero_audio_frames==0)$fatal(1,"FAIL missing nonzero audio coverage");\n        $display("PASS tb_router_play_table')
    probe_path=out/'tb_router_play_table_control.sv';probe_path.write_text(probe)
    tops['play_table']=('tb_router_play_table',[*legacy.glob('*.sv'),probe_path])
    for key in args.test or ['parts','play_table']:
        top,extra=tops[key];obj=out/key
        cmd=[tool,'-MAKEFLAGS','CXX=g++ LINK=g++ AR=ar','--binary','--timing','--assert','-Wno-fatal','--top-module',top,'--Mdir',str(obj),'-j','4',*map(str,sources+extra)]
        with (out/(key+'.compile.log')).open('w') as log:p=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        if p.returncode:raise RuntimeError(f'{key} compile failed: {out/(key+".compile.log")}')
        with (out/(key+'.run.log')).open('w') as log:p=subprocess.run([str(obj/('V'+top))],cwd=out,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        text=(out/(key+'.run.log')).read_text()
        passed=p.returncode==0 and 'PASS '+top in text
        results.append(dict(test=key,passed=passed,summary=[line for line in text.splitlines() if 'PASS' in line]))
        (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
        print(key,'PASS' if passed else 'FAIL',flush=True)
        if not passed:raise RuntimeError(text[-3000:])
if __name__=='__main__':main()
