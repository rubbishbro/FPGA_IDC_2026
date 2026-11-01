"""Offline ENG0 matrix note banks and explicit piano matrix -> ABC conversion.

Existing notes retain the current quantized records. Missing low piano notes are
retuned offline from the nearest available ENG0 matrix note, preserving pole
radius; the constant-force equilibrium is retained when changing the input map.
No runtime pitch substitution is performed by the FPGA.
"""
from functools import lru_cache
from pathlib import Path
import math,struct
import numpy as np
from scipy.signal import lfilter
ROOT=Path(__file__).resolve().parents[3]
LEGACY=(40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76)
CO_Q=(28,30,23,28,32,34,29)

@lru_cache(None)
def source_table(name,params=False):
    path=ROOT/'sythsound'/f'{name}_{"param" if params else "coeff_scaled"}.txt'
    notes={};current=None
    for line in path.read_text().splitlines():
        if line.startswith('midi'):
            current=int(line[4:]);notes[current]=[]
        elif line.startswith('mode'):
            notes[current].append([float(v) for v in line.split(':',1)[1].split(',')])
    return notes

def quant(value,q):
    n=round(float(value)*(1<<q))
    if not -(1<<31)<=n<(1<<31):raise ValueError(f'ENG0 Q{q} coefficient overflow: {value}')
    return n

def matrix_note(name,midi):
    source=source_table(name)
    chosen=min(source,key=lambda n:(abs(n-midi),n))
    if midi in LEGACY:
        blob=(Path(__file__).parent/'coefficients'/f'eng0_{name}.bin').read_bytes()
        off=(65536 if name=='guitar' else 0)+LEGACY.index(midi)*4096
        return blob[off:off+4096],dict(source_midi=midi,retuned=False,selection='preserved quantized ENG0 matrix')
    rows=source[chosen]
    ratio=2**((midi-chosen)/12)
    records=[]
    for mode in range(64):
        if mode>=len(rows):records.extend([0]*16);continue
        c=np.array(rows[mode],dtype=float)
        if chosen!=midi:
            matrix=c[:4].reshape(2,2)
            radius=math.sqrt(float(np.linalg.det(matrix)))
            center=float(np.trace(matrix))/2
            theta=math.acos(float(np.clip(center/radius,-1,1)))
            target=theta*ratio
            if not 0<target<math.pi:raise ValueError('retuned matrix pole outside Nyquist')
            adjusted=np.eye(2)*(radius*math.cos(target))+(matrix-np.eye(2)*center)*(math.sin(target)/math.sin(theta))
            c[4:6]=(np.eye(2)-adjusted)@np.linalg.solve(np.eye(2)-matrix,c[4:6])
            c[:4]=adjusted.ravel()
        words=[quant(v,q) for v,q in zip(c,CO_Q)]
        pm=[0]*8
        if name=='guitar':
            # All selected guitar notes have exact source rows, no retuned S terms.
            a11,a12,_a21,a22,wo,s11,s22,s12,_s21,swo=source_table(name,True)[midi][mode]
            pm=[quant(v,q) for v,q in zip([a11,a12,a22,wo,s11,s12,s22,swo],[28,30,28,29,29,29,29,29])]
        records.extend(words+[0]+pm)
    return struct.pack('>1024I',*(n&0xffffffff for n in records)),dict(
        source_midi=chosen,retuned=chosen!=midi,selection='ENG0 matrix; offline pole retune' if chosen!=midi else 'quantized exact ENG0 source')

def piano_abc(midi):
    import router_eng1 as R
    import eng1_audition as A
    data,row=matrix_note('piano',midi)
    words=np.frombuffer(data,dtype='>i4').reshape(64,16)
    strike=A.Strike('piano',1);strike.rise=1;strike.width=2;strike.gap=478;strike.pulses=3
    pulse=np.array([int(strike.step([255],[True],[n==0],[False])[0])/float(255<<16) for n in range(8192)])
    candidates=[]
    for mode,w in enumerate(words):
        c=np.array([int(v)/float(1<<q) for v,q in zip(w[:7],CO_Q)])
        matrix=c[:4].reshape(2,2);trace=float(np.trace(matrix));det=float(np.linalg.det(matrix))
        if not 0<det<1:continue
        a1=round(-trace*(1<<24));a2=round(det*(1<<24))
        if not (1<=a2<(1<<24) and (1<<24)+a1+a2>0 and (1<<24)-a1+a2>0):
            raise ValueError(f'piano {midi} mode {mode}: unstable ABC conversion')
        b=c[4:6];output=np.array([c[6],0.])
        numerator=[0.,float(output@b),float(output@(matrix-np.eye(2)*trace)@b)]
        reference=lfilter(numerator,[1.,-trace,det],pulse)
        unit=lfilter([1.],[1.,a1/(1<<24),a2/(1<<24)],pulse)
        peak=float(np.max(abs(reference)));sign=1 if numerator[1]>=0 else -1
        gain=sign*peak/max(float(np.max(abs(unit))),1e-30)
        g=round(gain*(1<<24))
        if not -(1<<25)<=g<(1<<25):raise ValueError('piano ABC gain overflow')
        candidates.append((peak,mode,g,a1,a2))
    selected=sorted(sorted(candidates,reverse=True)[:48],key=lambda r:r[1])
    table=R.Eng1Coeffs(np.array([r[2] for r in selected]),np.array([r[3] for r in selected]),
        np.array([r[4] for r in selected]),len(selected),label=f'piano:{midi}:matrix-derived')
    return table,dict(row,matrix_source_modes=[r[1] for r in selected],
        selection='ENG0 matrix reference -> ABC poles and short-strike modal peak conversion',
        conversion_limit='ABC single-input resonator matches poles/modal peak, not exact matrix numerator phase')
