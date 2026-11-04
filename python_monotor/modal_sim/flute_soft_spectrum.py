#!/usr/bin/env python3
"""Steady spectral shape: fitted E4 model vs its mezzo-piano reference.

Same fitting window as diagnosis: an in-sample fit check, not validation.
"""
from pathlib import Path
import os
import json
import numpy as np
from scipy.signal import welch

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'python_monotor/results/sim/eng1/flute_long_diagnosis_20261103'
FS = 48000


def main():
    traces = np.load(OUT/'raw_traces.npz')
    diagnosis = json.loads((OUT/'results.json').read_text())
    names = ['source_mezzo_piano','soft_weights']
    labels = ['Source: mezzo-piano recording','Model: fitted modal weights']
    colors = ['#197b9b','#d15a34']
    start,end = round(.57*FS),round(1.17*FS)
    spectra, metrics, harmonics = {}, {}, {}
    for name in names:
        x = traces[name][start:end].astype(float)
        f,p = welch(x,FS,nperseg=16384,noverlap=8192,detrend='constant')
        df=f[1]-f[0]
        band=(f>=80)&(f<=8000)
        p /= p[band].sum()*df
        use=(f>310)&(f<345)
        j=np.flatnonzero(use)[np.argmax(p[use])]
        logp=np.log(np.maximum(p,1e-300))
        delta=.5*(logp[j-1]-logp[j+1])/(logp[j-1]-2*logp[j]+logp[j+1])
        f0=float((j+delta)*df)
        widths=[15,30,60,100]
        residual={}
        for width in widths:
            mask=band.copy()
            for k in range(1,int(8000/f0)+2):
                mask &= abs(f-k*f0)>min(.4*f0,max(width,.02*k*f0))
            residual[str(width)]=float(p[mask].sum()/p[band].sum())
        metrics[name]=dict(f0_hz=f0,centroid_80_8000_hz=float((p[band]*f[band]).sum()/p[band].sum()),
                          off_harmonic_power_fraction_by_exclusion_hz=residual)
        spectra[name]=(f,p)
        harmonics[name]=np.array(diagnosis['metrics'][name]['steady_harmonics_db_relative_H1'])
    err=harmonics['soft_weights']-harmonics['source_mezzo_piano']
    result=dict(window_seconds=[.57,1.17],window_after_aligned_onset_seconds=[.45,1.05],
        normalization='Each PSD normalized to its own integrated 80..8000Hz power. Harmonic shapes relative to H1.',
        metrics=metrics, harmonic_error_model_minus_source_db=err.tolist(),
        median_abs_error_H2_H8_db=float(np.median(abs(err[1:8]))),
        median_abs_error_H2_H12_db=float(np.median(abs(err[1:12]))),
        notes=['Same source/window used to fit weights; near-zero harmonic error is expected, not independent validation.',
               'Off-harmonic energy includes recording noise/room, vibrato sidebands, window leakage and codec effects; not a calibrated breath-noise measurement.',
               'Narrow model lines may have higher PSD peaks despite matched harmonic band energy.'])
    (OUT/'soft_spectrum_comparison.json').write_text(json.dumps(result,indent=2)+'\n')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(2,2,figsize=(14,8),layout='constrained')
    for name,label,color in zip(names,labels,colors):
        f,p=spectra[name]
        db=10*np.log10(np.maximum(p,1e-15))
        axes[0,0].semilogx(f,db,color=color,label=label,lw=1,alpha=.85)
        axes[0,1].plot(range(1,17),harmonics[name][:16],'.-',color=color,label=label,lw=1.6)
        axes[1,0].plot(f,db,color=color,label=label,lw=1.1,alpha=.85)
    axes[0,0].set(xlim=(80,10000),ylim=(-110,-12),xlabel='Frequency (Hz)',ylabel='Normalized PSD (dB/Hz)',title='Full steady spectrum: equal 80 Hz-8 kHz band power')
    axes[0,1].set(xlim=(.7,16.3),ylim=(-65,5),xticks=range(1,17),xlabel='Harmonic number',ylabel='Band amplitude relative to H1 (dB)',title='Harmonic shape: fitted on this same reference window')
    axes[1,0].set(xlim=(550,1750),ylim=(-100,-12),xlabel='Frequency (Hz)',ylabel='Normalized PSD (dB/Hz)',title='Between harmonics: source has broader skirts and residual')
    x=np.arange(2,13)
    axes[1,1].bar(x,err[1:12],color='#7153a4',width=.65)
    axes[1,1].axhline(0,color='#555555',lw=.7)
    axes[1,1].set(xticks=x,xlabel='Harmonic number',ylabel='Model minus source (dB)',ylim=(-.35,.35),title=f'H2-H12 median absolute error: {result["median_abs_error_H2_H12_db"]:.3f} dB')
    for ax in axes.flat:
        ax.grid(alpha=.2)
    for ax in [axes[0,0],axes[0,1],axes[1,0]]:
        ax.legend(fontsize=8,loc='lower left')
    fig.suptitle('E4 flute: source vs fitted model | model body bypass, no added breath',fontsize=15)
    fig.savefig(OUT/'soft_spectrum_comparison.png',dpi=170)
    plt.close(fig)
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
