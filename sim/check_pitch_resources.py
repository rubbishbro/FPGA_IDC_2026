#!/usr/bin/env python3
"""Audit the complete P1T1 catalog and matching diagnostic resource export."""
from pathlib import Path
import sys,json,struct,math
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'rtl/router/tools'))
import sustain_resources as S

def main():
    catalog=json.loads((ROOT/'rtl/router/tools/sustain_profiles.json').read_text())
    diagnostic=json.loads((ROOT/'FFT_results/params/sustain_q24/sustain_profiles_q24.json').read_text())
    rows={(e['instrument'],e['midi']):e for e in catalog['entries']}
    assert catalog['pitch_format']==diagnostic['pitch_format']=='P1T1'
    for e in diagnostic['entries']:assert e['coeff_sha256']==rows[e['instrument'],e['midi']]['coeff_sha256']
    checks=0
    for e in catalog['entries']:
        row=S.make_note(e['name'],e['midi'],True)
        assert row['coeff_sha256']==e['coeff_sha256']
        for m in range(64):
            w=struct.unpack_from('>16i',row['data'],64*m)
            assert w[15]==0x50315431 and w[9]==w[1] and w[8]==-w[10]
            if m>=row['modes']:assert w[:15]==(0,)*15;continue
            bound=math.isqrt(w[2]<<26)-1
            assert w[10]==bound and 0<=w[13]<(1<<24)
            for c in [-220,0,220]:
                delta=round((2**(c/1200)-1)*(1<<24))
                a1=max(w[8],min(w[10],w[1]+((w[13]*delta+(1<<21))>>22)))
                assert 0<=w[2]<(1<<24) and -((1<<24)+w[2])<a1<(1<<24)+w[2]
                checks+=1
    result=dict(entries=len(rows),diagnostic_hashes_matched=len(diagnostic['entries']),static_pitch_checks=checks,pitch_format='P1T1')
    out=ROOT/'build/eng1_pitch/resource_audit.json';out.write_text(json.dumps(result,indent=2)+'\n')
    print('PASS pitch resources',result)
if __name__=='__main__':main()
