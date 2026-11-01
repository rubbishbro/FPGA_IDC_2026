#!/usr/bin/env python3
"""Reject incomplete pin mapping or any post-route timing violation."""
from pathlib import Path
import argparse, json, re
ROOT=Path(__file__).resolve().parents[2]
SRC=Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser();ap.add_argument('test',type=int,choices=(1,2));args=ap.parse_args()
    name='test1_reference_top' if args.test==1 else 'test2_project_top'
    out=ROOT/f'build/audio_loudness/test{args.test}'
    pnr=out/name/'impl/pnr'
    locs=re.findall(r'IO_LOC\s+"([^"]+)"\s+(\w+);',(SRC/'audio_test.cst').read_text())
    board=dict(re.findall(r'IO_LOC\s+"([^"]+)"\s+(\w+);',(ROOT/'rtl/platform/tang_mega_138k_pro/instrument_board.cst').read_text()))
    expected={'clk','rst_n','key0','key1','amp_bclk','amp_ws','amp_din','amp_sd','dac_bck','dac_ws','dac_din','dac_pa_en'}
    assert len(locs)==len(set(p for p,_ in locs))==len(set(pin for _,pin in locs))==12
    assert set(dict(locs))==expected and all(board[p]==pin for p,pin in locs),'pin mismatch with current board'
    timing=(pnr/(name+'.tr')).read_text()
    counts={k:int(re.search(r'<Numbers of '+k+r' Violated Endpoints>:(\d+)',timing)[1]) for k in ('Setup','Hold')}
    checks={}
    for category,title in {'setup':'3.1.1 Setup Paths Table','hold':'3.1.2 Hold Paths Table',
        'recovery':'3.1.3 Recovery Paths Table','removal':'3.1.4 Removal Paths Table',
        'pulse':'3.2 Minimum Pulse Width Table'}.items():
        section=re.split(r'^'+re.escape(title)+r'\s*$',timing,maxsplit=1,flags=re.M)[1]
        section=re.split(r'\n3\.[1234](?:\.\d+)? ',section,maxsplit=1)[0]
        slacks=[float(x) for x in re.findall(r'^\s*\d+\s+(-?\d+\.\d+)\s',section,re.M)]
        assert slacks or re.search(r'no .*path|no .*check|nothing to report',section,re.I),category
        checks[category]=min(slacks) if slacks else None
    clocks=re.findall(r'^\s*\d+\s+clk50\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)',timing,re.M)
    assert len(clocks)==1 and float(clocks[0][0])==50
    passed=not any(counts.values()) and all(s is None or s>=0 for s in checks.values()) and float(clocks[0][1])>=50
    result=dict(passed=passed,pins=dict(locs),violations=counts,worst_slack_ns=checks,fmax_mhz=float(clocks[0][1]))
    (out/'acceptance.json').write_text(json.dumps(result,indent=2)+'\n')
    if not passed:raise SystemExit('FAIL audio test post-route timing: '+str(result))
    print(f'PASS test{args.test} pins=12 timing={checks} Fmax={clocks[0][1]}MHz')
if __name__=='__main__':main()
