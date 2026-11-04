#!/usr/bin/env python3
"""LFSR drum reference and compact RAM-slot proposal. No RTL changes.
Reference: old 257-tap Hamming FIR spectral shape + old noise/attack decays,
with bipolar LFSR replacing Gaussian noise (causal 128-sample FIR latency).
Compact: two one-pole lowpass states form a bandpass fitted to the old curve;
Q24 filter/envelope updates, each noise branch occupies two 2-word state slots.
"""
from array import array
import bisect
import cmath
import hashlib
import json
import math
import struct
import sys
import wave
import zipfile
import zlib
import drum_pad_audition as D

OUT = D.ROOT / 'python_monotor/results/sim/eng1/drum_lfsr_audition'
FS, Q = D.FS, 1 << 24
MASK = 0x80200003


def step(s):
    return (s >> 1) ^ (MASK if s & 1 else 0)


def advance(s, n):
    basis = [step(1 << i) for i in range(32)]
    def apply(x, b):
        y = 0
        while x:
            bit = x & -x
            y ^= b[bit.bit_length()-1]
            x ^= bit
        return y
    while n:
        if n & 1: s = apply(s, basis)
        basis = [apply(x,basis) for x in basis]
        n >>= 1
    return s


def validate_lfsr():
    period = (1 << 32)-1
    assert advance(1,period)==1
    for factor in (3,5,17,257,65537):
        assert advance(1,period//factor)!=1
    s=1; total=0; lag=0; prev=0
    for _ in range(200000):
        value=1 if s&1 else -1
        total+=value; lag+=value*prev; prev=value; s=step(s)
        assert s
    return dict(mask=hex(MASK),period=period,period_proven=True,
                mean=total/200000,lag1=lag/199999,
                output='one bipolar bit per audio sample; one Galois right-shift per sample')


def curve(edges, db):
    centers=[math.sqrt(a*b) for a,b in zip(edges,edges[1:])]
    freqs=[0.]+centers+[FS/2]
    mags=[10**(db[0]/20)]+[10**(x/20) for x in db]+[10**(db[-1]/20)]
    def interp(f):
        i=max(0,min(len(freqs)-2,bisect.bisect_right(freqs,f)-1))
        u=(f-freqs[i])/(freqs[i+1]-freqs[i])
        return mags[i]*(1-u)+mags[i+1]*u
    return centers, interp


def fir_shape(edges, db):
    _, interpolate=curve(edges,db)
    gains=[interpolate(j*FS/1024) for j in range(513)]
    h=[]
    for k in range(257):
        m=k-128
        v=(.5*gains[0]+sum(gains[j]*math.cos(math.pi*j*m/512) for j in range(1,512))
            +.5*gains[512]*math.cos(math.pi*m))/512
        h.append(v*(.54-.46*math.cos(2*math.pi*k/256)))
    norm=math.sqrt(sum(x*x for x in h))
    return [x/norm for x in h]


def pole_rms(lo, hi):
    # Impulse energy of H_hi-H_lo; normalise stationary bipolar-noise RMS.
    a,b=1-lo,1-hi
    return math.sqrt(max(1e-20,hi/(2-hi)+lo/(2-lo)-2*hi*lo/(1-a*b)))


def fit_band(edges, db):
    centers,_=curve(edges,db)
    target=[10**(x/20) for x in db]
    best=None
    candidates=(30,60,100,180,300,500,800,1200,1800,2600,3800,5500,8000,12000,18000,23000)
    for low in candidates:
        for high in candidates:
            if high<=low: continue
            lo=1-math.exp(-2*math.pi*low/FS)
            hi=1-math.exp(-2*math.pi*high/FS)
            response=[]
            for f in centers:
                z=cmath.exp(-2j*math.pi*f/FS)
                response.append(abs(hi/(1-(1-hi)*z)-lo/(1-(1-lo)*z)))
            # Amplitude-domain shape fit prioritises bands with audible energy.
            scale=sum(t*r for t,r in zip(target,response))/sum(r*r for r in response)
            loss=sum((t-scale*r)**2 for t,r in zip(target,response))
            if best is None or loss<best[0]: best=(loss,low,high,lo,hi)
    loss,low,high,lo,hi=best
    return dict(low_hz=low,high_hz=high,lo_q=round(lo*Q),hi_q=round(hi*Q),
                inverse_rms=1/pole_rms(round(lo*Q)/Q,round(hi*Q)/Q),shape_fit_loss=loss)


def descriptors(z,key):
    meta=D.read_array(z,key+'__meta')
    edges=D.read_array(z,key+'__band_edges'); db=D.read_array(z,key+'__band_db')
    gain,gamma,_,attack,agamma,gl,gh,ah=meta
    # This checked-in NPZ has single-band tails for all six pieces.
    assert gl==0 and gh==0, 'LF/HF split needs two tail branches'
    branches=[dict(name='tail',gain=gain,gamma=max(gamma,.5),db=db)]
    if attack>0 and agamma>0:
        branches.append(dict(name='attack',gain=gain*attack,gamma=max(agamma,.5),
                             db=D.read_array(z,key+'__att_band_db')))
    for b in branches:
        b['seed']=(zlib.crc32((key+':'+b['name']).encode()) or 1)
        b['decay_q']=round(math.exp(-b['gamma']/FS)*Q)
        b['band']=fit_band(edges,b['db'])
        b['fir']=fir_shape(edges,b['db'])
    return branches


def noise(branches,n,compact):
    out=array('d',[0.])*n
    for b in branches:
        s=b['seed']; env=Q; decay=b['decay_q']
        if compact:
            lo=hi=0; band=b['band']; lc,hc=band['lo_q'],band['hi_q']
            gain=b['gain']*band['inverse_rms']
            for i in range(n):
                x=Q if s&1 else -Q; s=step(s)
                lo+=((x-lo)*lc+(Q>>1))>>24
                hi+=((x-hi)*hc+(Q>>1))>>24
                assert -2**31<=lo<2**31 and -2**31<=hi<2**31
                out[i]+=(hi-lo)/Q*(env/Q)*gain
                env=(env*decay+(Q>>1))>>24
        else:
            # Finite FIR reference, intentionally offline; no 257-word RTL state claim.
            h=b['fir']; ring=[0.]*257; at=0
            for i in range(n):
                ring[at]=1. if s&1 else -1.; s=step(s)
                # h is symmetric: oldest->newest dot product is equivalent here.
                at=(at+1)%257
                seq=ring[at:]+ring[:at]
                y=sum(v*c for v,c in zip(seq,h))
                out[i]+=y*b['gain']*math.exp(-b['gamma']*i/FS)
        assert s!=0
    return out


def mix_score(events,seconds,clips):
    out=array('d',[0.])*round(seconds*FS); fade=round(.005*FS)
    for idx,e in enumerate(events):
        clip=clips[e['key'],e['velocity']]; at=round(e['time']*FS)
        next_hit=next((x for x in events[idx+1:] if x['pad']==e['pad']),None)
        cut=round((next_hit['time']-e['time'])*FS) if next_hit else len(clip)
        for j in range(min(len(clip),len(out)-at,cut+fade)):
            w=.5*(1+math.cos(math.pi*(j-cut+1)/fade)) if j>=cut else 1.
            out[at+j]+=clip[j]*w
    return out


def write(name,y,gain):
    pcm=array('h',(round(x*gain*32767) for x in y))
    clipped=sum(abs(x)>=32767 for x in pcm)
    assert not clipped
    peak=max(map(abs,pcm)); rms=math.sqrt(sum(x*x for x in pcm)/len(pcm))/32768
    if sys.byteorder!='little': pcm.byteswap()
    with wave.open(str(OUT/name),'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS); w.writeframes(pcm.tobytes())
    return dict(seconds=len(y)/FS,peak=peak/32768,rms=rms,clipped=clipped)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    lfsr=validate_lfsr(); events,seconds=D.score()
    clips={k:{} for k in ('dry','fir','compact')}; tables={}; modes={}
    with zipfile.ZipFile(D.SOURCE) as z:
        for key in D.KEYS:
            desc=descriptors(z,key)
            variants=sorted({e['velocity'] for e in events if e['key']==key})
            dry,m=D.render_hit(z,key,variants[0]); modes[key]=m
            n=len(dry); tail=round(.005*FS); begin=n-tail
            noises={name:noise(desc,n,name=='compact') for name in ('fir','compact')}
            for v in variants:
                modal,mm=(dry,m) if v==variants[0] else D.render_hit(z,key,v)
                assert mm['saturated_states']==0
                clips['dry'][key,v]=modal
                for name,nz in noises.items():
                    y=array('d',modal)
                    for i in range(n):
                        fade=.5*(1+math.cos(math.pi*(i-begin+1)/tail)) if i>=begin else 1.
                        y[i]+=nz[i]*v*D.GAIN[key]*fade
                    clips[name][key,v]=y
            tables[key]=[dict(name=b['name'],seed=b['seed'],decay_q=b['decay_q'],
                initial_envelope_q=Q,gain=b['gain'],band=b['band'],
                slots=[48+2*i,49+2*i],state_words=['lfsr_u32','envelope_uq24','lowpass_lo_q24','lowpass_hi_q24'])
                for i,b in enumerate(desc)]
            print('rendered',key,'noise branches',len(desc),'extra state slots',len(desc)*2,flush=True)
    mixes={name:mix_score(events,seconds,bank) for name,bank in clips.items()}
    gain=.85/max(abs(x) for y in mixes.values() for x in y)
    files={}
    for name,y in mixes.items():
        files[f'full_{name}.wav']=write(f'full_{name}.wav',y,gain)
        files[f'groove_{name}.wav']=write(f'groove_{name}.wav',y[round(19.2*FS):],gain)
    ab=array('d',mixes['dry'][round(19.2*FS):])+array('d',[0.])*FS+mixes['compact'][round(19.2*FS):]
    files['groove_AB_dry_compact.wav']=write('groove_AB_dry_compact.wav',ab,gain)
    report=dict(sample_rate=FS,source_sha256=hashlib.sha256(D.SOURCE.read_bytes()).hexdigest(),
        source=str(D.SOURCE),lfsr=lfsr,shared_output_gain=gain,files=files,events=events,
        compact_tables=tables,modal_metrics=modes,
        scope='Proposal Python audition, not production RTL. Same modal waveforms/events/gains across variants.',
        fir_reference='Old 257-tap frequency-sampled Hamming shape, unit-RMS filter; bipolar LFSR instead of Gaussian, causal delay 128 samples.',
        compact='Q24 two-lowpass difference approximates each old spectral curve; Q24 exponential envelope. Floating branch gain/output mix. Max 4 spare slots for current NPZ.',
        limitations=['No noise-shape equivalence claim for compact vs FIR','No body/reverb/ADC/scheduling or board gain',
                     '5ms retrigger overlap retains old tail outside one lane; RTL needs temporary fade state or a non-overlap fade/restart',
                     'Resetting branch seed per hit makes identical hits repeat; continuous or varying nonzero seeds can be added later'])
    (OUT/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(output=str(OUT),files=files,lfsr=lfsr)),flush=True)

if __name__=='__main__': main()
