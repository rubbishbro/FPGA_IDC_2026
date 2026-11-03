#!/usr/bin/env python3
"""Exact static pole and Flash-ABI audit, including actual aftertouch arithmetic.

Jury tests use integers, no floating-point epsilon. ABC interval endpoints prove
all clamped a1 values strictly stable; actual pressure sweeps also check RTL
rounding/clamping. This is a pole audit, not a nonlinear overflow/listening test.
"""
from pathlib import Path
import argparse,json,struct,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'sim'),str(ROOT/'rtl/router/tools')]
from check_performance_resources import check as check_layout
from pitch_linear import modulation_words
import numpy as np
from router_eng1 import Eng1Coeffs

def matrix_ok(w):
    a,b,c,d=w[0]*4,w[1],w[2]*128,w[3]*4
    det=a*d-b*c;tr=(a+d)*(1<<30);one=1<<60
    return min(one-det,one-tr+det,one+tr+det)>0

def abc_ok(g,a1,a2):
    return (g,a1,a2)==(0,0,0) or (0<a2<(1<<24) and (1<<24)+a1+a2>0 and (1<<24)-a1+a2>0)

def wrap32(n):return (n+(1<<31))%(1<<32)-(1<<31)

def audit(directory):
    directory=Path(directory);layout=check_layout(directory)
    m=json.loads((directory/'resources.json').read_text());raw=(directory/'resources.bin').read_bytes()
    ratios=struct.unpack_from('>512I',raw,m['control_page']['offset'])
    deltas=set()
    for th in [64,102,230]:
        for level in range(256):
            diff=max(0,level-th);cents=(diff*768+2)//5
            index=(cents+56320)>>8;fraction=(cents+56320)&255
            assert index+1<512
            delta=ratios[index]+(((ratios[index+1]-ratios[index])*fraction+128)>>8)-(1<<24)
            assert -(1<<23)<=delta<(1<<23)
            deltas.add(delta)
    failures=[];stats={};mod0_points=mod1_points=0
    for row in m['entries']:
        name=row['name'];w=np.array(struct.unpack_from('>1024i',raw,row['offset']),dtype=np.int64).reshape(64,16)
        st=stats.setdefault(name,dict(notes=0,sounding=0,silent=0,modulated_modes=0));st['notes']+=1
        is_matrix=row['instrument'] in [0,1]
        if not is_matrix:
            modal=w[:48] if name=='drums' else w
            t=Eng1Coeffs(modal[:,0],modal[:,1],modal[:,2],row.get('modal_modes',row['modes']))
            expected=np.array(modulation_words(t))
            assert np.array_equal(w[:48,8:16] if name=='drums' else w[:,8:16],expected[:48] if name=='drums' else expected),f'{name} {row["midi"]}: P1T1 differs from actual coefficients'
        for mode in range(row.get('modal_modes',row['modes'])):
            co=list(map(int,w[mode]));silent=not any(co[:7] if is_matrix else co[:3]);st['silent' if silent else 'sounding']+=1
            if not (matrix_ok(co) if is_matrix else abc_ok(*co[:3])):
                failures.append(dict(name=name,midi=row['midi'],mode=mode,kind='nominal'))
            if name=='guitar' and mode<4:
                for th in [64,102,230]:
                    span=max(1,230-th);step=(37580959+span//2)//span
                    for level in range(256):
                        lam=37580959 if level>=230 else step*max(0,level-th)
                        a=wrap32(co[8]+((lam*co[12])>>31));b=wrap32(co[9]+((lam*co[13])>>29))
                        d=wrap32(co[10]+((lam*co[14])>>31));c=wrap32(-(b>>7))
                        # Matching modulation0's Q28/Q30/Q23 updates.
                        if not matrix_ok([a,b,c,d]):failures.append(dict(name=name,midi=row['midi'],mode=mode,kind='mod0',threshold=th,level=level))
                        mod0_points+=1
                st['modulated_modes']+=1
            elif not is_matrix and name not in ('piano_abc','drums'):
                lo,base,hi,slope=co[8],co[9],co[10],co[13]
                assert lo<=base<=hi
                # Stability is affine in a1, so endpoint checks cover the whole
                # interval, including untested pressure histories.
                for v in [lo,hi]:assert abc_ok(co[0],v,co[2]),f'unsafe clamp {name} {row["midi"]}/{mode}'
                for delta in deltas:
                    value=max(lo,min(hi,base+((delta*slope+(1<<21))>>22)))
                    assert abc_ok(co[0],value,co[2])
                    mod1_points+=1
                st['modulated_modes']+=1
    result=dict(passed=not failures,layout=layout,instruments=stats,mod0_pressure_points=mod0_points,
        mod1_pressure_points=mod1_points,abc_clamp_interval_proven=True,failures=failures,
        scope='exact quantized static poles; mod0 first4, ABC all populated modes (runtime cap6); no overflow or listening proof')
    return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--directory',type=Path,default=ROOT/'rtl/router/tools/performance');p.add_argument('--out',type=Path,default=ROOT/'build/production_stability.json');a=p.parse_args()
    r=audit(a.directory);a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps(dict(passed=r['passed'],mod0_pressure_points=r['mod0_pressure_points'],mod1_pressure_points=r['mod1_pressure_points'],failure_count=len(r['failures']),instruments=r['instruments']),ensure_ascii=False))
    sys.exit(0 if r['passed'] else 1)
