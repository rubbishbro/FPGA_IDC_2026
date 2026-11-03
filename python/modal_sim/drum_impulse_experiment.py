#!/usr/bin/env python3
"""Compare C seed and zero-state impulse with production Q24 recurrence.
Modal-only isolation: no noise, body, envelope, or output limiter. No RTL changes.
"""
from pathlib import Path
import hashlib, json
import numpy as np
from scipy.io import wavfile
from scipy.signal import stft
from eng1_bc import build_c_table, KIT_GAIN

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/drum_impulse_experiment'
SR=48000; Q=1<<24
KEYS=['kick','snare','tom','hat','ride','crash']

def render(a1,a2,g,s1,s2,n,x=Q):
    y1=s1.copy(); y2=s2.copy(); out=np.empty(n); clips=0
    for i in range(n):
        acc=-a1*y1-a2*y2
        if i==0: acc=acc+g*x
        raw=(acc+(1<<23))>>24
        clips+=int(np.count_nonzero((raw<-(1<<31))|(raw>((1<<31)-1))))
        y=np.clip(raw,-(1<<31),(1<<31)-1)
        out[i]=y.sum()/Q; y2,y1=y1,y
    return out,clips

def metrics(ref,y):
    rms=lambda x:float(np.sqrt(np.mean(x*x)))
    db=lambda x:float(20*np.log10(max(x,1e-15)))
    _,_,r=stft(ref,SR,nperseg=2048,noverlap=1536)
    _,_,s=stft(y,SR,nperseg=2048,noverlap=1536)
    pr=np.sum(abs(r)**2,axis=1); ps=np.sum(abs(s)**2,axis=1)
    mask=pr>pr.max()*1e-5
    spectral=float(np.sqrt(np.mean((10*np.log10(np.maximum(ps[mask],1e-30)/pr[mask]))**2)))
    return dict(rms_delta_db=db(rms(y)/max(rms(ref),1e-15)),
        peak_delta_db=db(max(abs(y))/max(max(abs(ref)),1e-15)),
        first_10ms_peak_delta_db=db(max(abs(y[:480]))/max(max(abs(ref[:480])),1e-15)),
        correlation=float(np.corrcoef(ref,y)[0,1]),
        waveform_relative_error=float(np.linalg.norm(y-ref)/np.linalg.norm(ref)),
        active_spectrum_rmse_db=spectral)

def main():
    OUT.mkdir(parents=True,exist_ok=True); rows=[]; sounds={}; coeff={}
    for key in KEYS:
        t=build_c_table(key,48); a1=t.coeffs.a1; a2=t.coeffs.a2
        # Legacy seed generator stores Q30: convert to production Q24 first.
        s1=(t.seed_y1+32)>>6; s2=(t.seed_y2+32)>>6
        radius=np.sqrt(a2/Q); theta=np.arccos(np.clip(-a1/Q/(2*radius),-1,1))
        # Recover amplitude from quantized seed pair, without random-phase re-generation.
        b=s1/Q; c=(b*np.cos(theta)-radius*s2/Q)/np.maximum(np.sin(theta),1e-12)
        amplitude=radius*np.sqrt(b*b+c*c)
        # h[n]=G*r**n*sin((n+1)*theta)/sin(theta). Preserve modal amplitude.
        gm=np.floor(amplitude*np.sin(theta)*Q+.5).astype(np.int64)
        # Sign chosen from least-squares projection onto impulse basis over hit length.
        n=t.length+2400; times=np.arange(t.length)
        dot=np.zeros(len(a1))
        for j in range(len(a1)):
            h=radius[j]**times*np.sin((times+1)*theta[j])/max(np.sin(theta[j]),1e-12)
            ref=radius[j]**(times+1)*(b[j]*np.cos((times+1)*theta[j])+c[j]*np.sin((times+1)*theta[j]))
            dot[j]=np.dot(h,ref)
        gs=gm*np.where(dot>=0,1,-1)
        assert np.all(abs(gm)<(1<<25)), 'G exceeds production signed26'
        coeff[key]=dict(a1=a1.tolist(),a2=a2.tolist(),G_positive=gm.tolist(),G_signed=gs.tolist())
        for velocity in [.25,.8,1.0]:
            gain=velocity*KIT_GAIN[key]
            seed1=np.floor(s1*gain+.5).astype(np.int64); seed2=np.floor(s2*gain+.5).astype(np.int64)
            ref,cl=render(a1,a2,np.zeros_like(a1),seed1,seed2,n)
            fade=np.ones(n); fade[t.length:]=np.exp(-np.arange(n-t.length)/240)
            ref*=fade
            for name,g in [('positive',gm),('signed',gs)]:
                # Velocity is a Q24 input; stored coefficients stay constant.
                x=int(np.floor(gain*Q+.5))
                y,clip=render(a1,a2,g,np.zeros_like(s1),np.zeros_like(s2),n,x); y*=fade
                rows.append(dict(drum=key,velocity=velocity,variant=name,seed_clips=cl,impulse_clips=clip,**metrics(ref,y)))
                if velocity==.8:sounds[key,name]=y
            if velocity==.8:sounds[key,'seed']=ref
        print(key,flush=True)
    # One global gain for every file; never normalize A and B independently.
    peak=max(float(max(abs(y))) for y in sounds.values()); scale=.9/max(peak,1e-12)
    gap=np.zeros(SR//3); montage=[]
    for key in KEYS:
        for name in ['seed','positive','signed']:
            y=sounds[key,name]; wavfile.write(OUT/f'{key}_{name}.wav',SR,(y*scale).astype(np.float32)); montage.extend([y,gap])
    wavfile.write(OUT/'comparison.wav',SR,(np.concatenate(montage)*scale).astype(np.float32))
    (OUT/'results.json').write_text(json.dumps(dict(sample_rate=SR,state_format='Q24',modes=48,
        scope='modal only; no noise, body, hardware output chain; common audio gain',
        source_sha256=hashlib.sha256((ROOT/'FFT_results/params/drums.npz').read_bytes()).hexdigest(),
        audio_gain=scale,results=rows),indent=2))
    (OUT/'coefficients.json').write_text(json.dumps(coeff,indent=2))
if __name__=='__main__': main()
