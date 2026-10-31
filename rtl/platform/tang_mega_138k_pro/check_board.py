#!/usr/bin/env python3
"""Check complete, unique pin assignments and production source dependencies."""
from pathlib import Path
import re,json,argparse
ROOT=Path(__file__).resolve().parents[3]
BOARD=Path(__file__).resolve().parent
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path)
    ap.add_argument('--timing',type=Path,help='Require a post-route timing report with no violated endpoints')
    args=ap.parse_args();source=(BOARD/'instrument_board_top.sv').read_text()
    ports=[]
    for line in source.splitlines():
        m=re.match(r'\s*(?:input|output|inout) wire\s*(?:\[(\d+):(\d+)\])?\s*(.*)',line)
        if not m:continue
        names=m[3].rstrip(',').split(',')
        for name in names:
            name=name.strip()
            ports += [f'{name}[{n}]' for n in range(int(m[2]),int(m[1])+1)] if m[1] else [name]
    locs=re.findall(r'IO_LOC\s+"([^"]+)"\s+(\w+);',(BOARD/'instrument_board.cst').read_text())
    assert len(ports)==len(set(ports))
    assert len(locs)==len(set(p for p,_ in locs))==len(set(pin for _,pin in locs)),'duplicate port or package pin'
    assert set(ports)==set(p for p,_ in locs),f'port mapping mismatch: {set(ports)^set(p for p,_ in locs)}'
    files=(BOARD/'sources.f').read_text().splitlines()
    assert len(files)==len(set(files))
    assert all((ROOT/f).is_file() for f in files),'missing source dependency'
    assert not any('/sim/' in '/'+f or f.startswith('history/') or '/tb/' in f for f in files),'nonproduction source'
    build=(BOARD/'build.tcl').read_text()
    assert 'set_option -use_sspi_as_gpio 1' in build and 'set_option -use_cpu_as_gpio 1' in build
    result=dict(status='passed',ports=len(ports),production_sources=len(files),pins=dict(locs),
                adc='Dedicated ADCV_P=N12 / ADCV_N=P11; not a regular IO_LOC',
                audio_reference_hz=12500000,actual_sample_hz=48828.125)
    if args.timing:
        timing=args.timing.read_text()
        setup=re.search(r'<Numbers of Setup Violated Endpoints>:(\d+)',timing)
        hold=re.search(r'<Numbers of Hold Violated Endpoints>:(\d+)',timing)
        assert setup and hold,'missing authoritative post-route violation counts'
        setup,hold=int(setup[1]),int(hold[1])
        # Summary hold counts do not cover every clock check. Recovery/removal
        # and minimum pulse width must independently pass, including DSP clocks.
        categories={'setup':'3.1.1 Setup Paths Table','hold':'3.1.2 Hold Paths Table',
                    'recovery':'3.1.3 Recovery Paths Table','removal':'3.1.4 Removal Paths Table',
                    'min_pulse_width':'3.2 Minimum Pulse Width Table'}
        checks={}
        for name,title in categories.items():
            assert title in timing, f'missing {name} timing section'
            parts=re.split(r'^'+re.escape(title)+r'\s*$',timing,maxsplit=1,flags=re.M)
            assert len(parts)==2, f'missing actual {name} timing table'
            section=parts[1]
            section=re.split(r'\n3\.[1234](?:\.\d+)? ',section,maxsplit=1)[0]
            slacks=[float(v) for v in re.findall(r'^\s*\d+\s+(-?\d+\.\d+)\s',section,re.M)]
            assert slacks or re.search(r'no .*path|no .*check|nothing to report',section,re.I), f'empty/unrecognized {name} timing table'
            checks[name]=dict(worst_slack_ns=min(slacks) if slacks else None,
                              reported_violations=sum(v<0 for v in slacks))
        clocks={name:dict(target_mhz=float(target),fmax_mhz=float(actual)) for name,target,actual in
                re.findall(r'^\s*\d+\s+(\S+)\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)',timing,re.M)}
        expected_clocks={'clk50':50.0,'clk_core':50.0,'clk_audio':12.5,'clk_pix':33.333}
        for name,target in expected_clocks.items():
            assert name in clocks and abs(clocks[name]['target_mhz']-target)<0.002, f'missing/changed target clock {name}'
        result['timing']=dict(report=str(args.timing),setup_violations=setup,hold_violations=hold,checks=checks,clocks=clocks)
        result['status']='failed' if setup or hold or any(c['reported_violations'] for c in checks.values()) or any(c['fmax_mhz']<c['target_mhz'] for c in clocks.values()) else 'passed'
    if args.out:args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,indent=2)+'\n')
    print(f'PASS board source/pin preflight: {len(ports)} ports, {len(files)} production files')
    if result['status']=='failed':
        raise SystemExit(f'FAIL board timing: {result["timing"]}; bitstream is not accepted')
if __name__=='__main__':main()
