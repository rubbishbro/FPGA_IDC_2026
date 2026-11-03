#!/usr/bin/env python3
"""Shift/add onset-spectrum experiment inside existing excitation boundary.

No physical air-jet feedback model, production RTL edits or extra multipliers.
Two shift-only one-poles soften the initial periodic drive, then shift/add
crossfade to the unchanged impulse train. Modal G/poles and ADSR stay fixed.
"""
from pathlib import Path
from dataclasses import replace
import json
import os
import numpy as np
import soundfile as sf
from scipy.signal import periodogram
import eng1_rtl as E
import router_eng1 as R
import flute_air_envelope as F

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'FFT_results/sim/eng1/flute_long_diagnosis_20261103'
OUT=ROOT/'FFT_results/sim/eng1/flute_jet_onset_20261103'
FS=48000;ON=round(.12*FS);OFF=round(1.67*FS);N=round(2.1*FS)
CONFIGS={'gentle':dict(lp_shift=5,hold_samples=1536,fade_log2=12),
         'softer':dict(lp_shift=6,hold_samples=2048,fade_log2=12)}


def blend_shift_add(a,b,weight):
    """signed32 lerp, 8-bit fractional weight; no multiply in candidate path."""
    if weight>=256:return int(b)
    delta=int(b)-int(a)
    return R.wrap_signed(int(a)+sum(delta>>(8-bit) for bit in range(8) if (weight>>bit)&1),32)


class OnsetExcitation(E.Excitation):
    def __init__(self,periods,lp_shift,hold_samples,fade_log2):
        self.lp_shift=lp_shift;self.hold=hold_samples;self.fade_log2=fade_log2
        super().__init__(periods)
    def reset(self):
        super().reset()
        self.age=np.zeros(self.slots,dtype=np.int64)
        self.lp1=np.zeros(self.slots,dtype=np.int64)
        self.lp2=np.zeros(self.slots,dtype=np.int64)
    def step(self,gate,level,trigger,clear,delta):
        start=(gate&~self.previous_gate)|trigger
        pulse=super().step(gate,level,trigger,clear,delta)
        result=np.zeros(self.slots,dtype=np.int64)
        for s in range(self.slots):
            if clear[s] or not gate[s]:
                self.age[s]=self.lp1[s]=self.lp2[s]=0
                continue
            if start[s]:self.age[s]=self.lp1[s]=self.lp2[s]=0
            # Nonblocking-register semantics: second pole reads old first pole.
            old1=int(self.lp1[s]);old2=int(self.lp2[s])
            self.lp1[s]=R.wrap_signed(old1+((int(pulse[s])-old1)>>self.lp_shift),32)
            self.lp2[s]=R.wrap_signed(old2+((old1-old2)>>self.lp_shift),32)
            weight=min(256,max(0,int(self.age[s])-self.hold)>>(self.fade_log2-8))
            result[s]=blend_shift_add(int(self.lp2[s]),int(pulse[s]),weight)
            self.age[s]=min(self.hold+(1<<self.fade_log2),int(self.age[s])+1)
        return result


def arithmetic_checks():
    for a,b in [(-16000000,16000000),(16000000,-16000000),(0,1234567)]:
        assert blend_shift_add(a,b,0)==a and blend_shift_add(a,b,256)==b
        for w in range(1,256):
            ideal=a+((b-a)*w>>8)
            assert abs(blend_shift_add(a,b,w)-ideal)<=7
    for cfg in CONFIGS.values():
        periods=[146]*4
        trial=OnsetExcitation(periods,**cfg);reference=E.Excitation(periods)
        gate=np.array([1,0,0,0],bool);zero=np.zeros(4,bool);delta=np.zeros(4,dtype=np.int64)
        level=np.array([201,0,0,0]);end=cfg['hold_samples']+(1<<cfg['fade_log2'])
        for i in range(end+400):
            trigger=gate if i==0 else zero
            a=trial.step(gate,level,trigger,zero,delta)
            b=reference.step(gate,level,trigger,zero,delta)
            if i>=end:assert np.array_equal(a,b)
        assert not np.any(trial.step(zero,level,zero,zero,delta))
        assert not np.any(trial.lp1) and not np.any(trial.lp2)
        trial.reset();fresh=OnsetExcitation(periods,**cfg)
        assert np.array_equal(trial.step(gate,level,gate,zero,delta),fresh.step(gate,level,gate,zero,delta))


def render(name,bank,params):
    synth=E.Eng1Synth('flute',note_map=F.NOTES,resources=bank,stereo=False,reverb='NONE')
    synth.envelope=E.Envelope([params['A_STEP']]*4,[params['R_STEP']]*4,
                             sustain_level=params['S_LEVEL'],decay_step=params['D_STEP'])
    synth.excitation=OnsetExcitation([r.period for r in synth.rows],**CONFIGS[name])
    y=np.empty(N,dtype=np.int64);rails=0
    drive=np.empty(N,dtype=np.int32)
    for i in range(N):
        if i==ON:synth.note_on(64,100)
        if i==OFF:synth.note_off(0)
        frame=synth.step();y[i]=frame.out;drive[i]=frame.x[0]
        rails+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%FS==0:print(name,f'{i//FS}/2.1s',flush=True)
    assert rails==0 and not np.any(y[:ON]) and not np.any(y[-round(.2*FS):])
    return y.astype(float),drive


def harmonic_frames(x):
    frames=[]
    for start in [.02,.08,.14,.20,.26,.45]:
        end=start+.06 if start<.4 else 1.05
        z=x[ON+round(start*FS):ON+round(end*FS)]
        f,p=periodogram(z,FS,window='hann',nfft=32768)
        use=(f>315)&(f<345);f0=f[use][np.argmax(p[use])]
        amp=np.array([np.sqrt(p[abs(f-k*f0)<max(35,.02*k*f0)].sum()) for k in range(1,6)])
        frames.append(dict(start_seconds=start,end_seconds=end,
                           harmonics_db=(20*np.log10(np.maximum(amp/max(amp[0],1e-30),1e-12))).tolist()))
    return frames


def main():
    OUT.mkdir(parents=True,exist_ok=True);arithmetic_checks()
    data=json.loads((BASE/'E4_soft_weights_attack240_release180_coefficients.json').read_text())
    bank=E.ResourceBank.build('flute',F.NOTES);notes=dict(bank.notes);row=notes[64]
    table=row.coeffs.padded(64)
    for key in ['a1','a2']:assert np.array_equal(getattr(table,key),[r[key] for r in data['coefficients']])
    notes[64]=replace(row,coeffs=replace(table,G=np.array([r['G'] for r in data['coefficients']],dtype=np.int64)))
    bank=E.ResourceBank('flute',notes)
    signals={'baseline':np.load(BASE/'soft_weights_attack240_release180_raw.npy').astype(float)}
    drives={}
    for name in CONFIGS:signals[name],drives[name]=render(name,bank,data['envelope'])
    reference,sr=sf.read(BASE/'soft_weights_attack240_release180.wav',always_2d=True)
    window=slice(round(.8*FS),round(1.2*FS))
    rms=lambda x:float(np.sqrt(np.mean(np.asarray(x,dtype=float)**2)))
    gain=rms(reference[window,0])/rms(signals['baseline'][window])
    clips={};report={}
    for name,y in signals.items():
        z=y*gain
        sf.write(OUT/f'{name}.wav',np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
        check,fs=sf.read(OUT/f'{name}.wav',always_2d=True)
        assert fs==FS and np.isfinite(check).all() and abs(check).max()<1
        clips[name]=check
        late_error=rms(y[window]-signals['baseline'][window])/rms(signals['baseline'][window])
        report[name]=dict(harmonic_frames=harmonic_frames(y),late_relative_rms_error=float(late_error),peak=float(abs(check).max()))
    source=np.load(BASE/'raw_traces.npz')['source_mezzo_piano']
    sourceframes=harmonic_frames(source)
    srcwav,sr=sf.read(BASE/'source_mezzo_piano.wav',always_2d=True)
    # Comparison source clip plus same model note, retaining genuine onset and tail.
    parts=[srcwav,np.zeros((round(.4*FS),2)),clips['baseline'],np.zeros((round(.4*FS),2)),clips['gentle'],np.zeros((round(.4*FS),2)),clips['softer']]
    sf.write(OUT/'source_then_baseline_gentle_softer.wav',np.concatenate(parts),FS,subtype='PCM_24')
    sf.write(OUT/'baseline_then_gentle.wav',np.concatenate([clips['baseline'],np.zeros((round(.4*FS),2)),clips['gentle']]),FS,subtype='PCM_24')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(1,3,figsize=(14,4.5),layout='constrained')
    for frames,label in [(sourceframes,'source recording')]+[(v['harmonic_frames'],k) for k,v in report.items()]:
        times=[(r['start_seconds']+r['end_seconds'])*500 for r in frames[:5]]
        for ax,k in zip(axes,[2,3,4]):
            ax.plot(times,[r['harmonics_db'][k-1] for r in frames[:5]],'.-',label=label)
            ax.set(xlabel='Time after aligned onset (ms)',ylabel=f'H{k}/H1 (dB)',title=f'Onset harmonic ratio H{k}/H1')
    for ax in axes:ax.grid(alpha=.2);ax.legend(fontsize=8)
    fig.suptitle('E4 onset: same modal poles/weights and ADSR, excitation only varies')
    fig.savefig(OUT/'onset_harmonics.png',dpi=160);plt.close(fig)
    for name,v in report.items():
        v['early_H2_H5_mean_abs_error_vs_source_db']=float(np.mean(abs(np.array(v['harmonic_frames'][0]['harmonics_db'][1:])-np.array(sourceframes[0]['harmonics_db'][1:]))))
    result=dict(configurations=CONFIGS,envelope=data['envelope'],source_frames=sourceframes,variants=report,
        method='2 cascaded signed32 one-poles, shifts5 or6, then 8-bit shift/add crossfade to original pulse. Second pole reads old first pole. Same modal coefficients, ADSR and fixed model playback gain. No added breath or body filter.',
        arithmetic_checks='PASS: signed shift-add endpoints and rounding bounds, exact excitation return, silence, gate reset and deterministic reset; model rails and WAV checks passed.',
        limitations='Onset-spectrum surrogate, not physical jet-delay/nonlinear feedback. Source 10%-RMS onset alignment approximate. Model and reference envelope remain different. Not full RTL cycle/area/timing verification; production RTL unchanged.')
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    np.savez_compressed(OUT/'raw_traces.npz',**signals,**{k+'_drive':v for k,v in drives.items()})
    (OUT/'README.md').write_text('''# 长笛起音音色：激励渐变实验

固定E4轻奏模态权重、240ms Attack、85% Sustain、180ms Release，腔体直通、无新增气息。
在现有激励运算边界内，用两个移位一阶低通，使起音更接近基频主导，再渐变回原周期脉冲。
不增加硬件模块或乘法器；需要在已有模块内部加入状态/移位加减。此处只有Python定点实验，未改生产RTL。

gentle：低通右移5位，保持32ms，85.33ms渐变；约117.33ms后恢复原激励。
softer：低通右移6位，保持42.67ms，85.33ms渐变；约128ms后恢复原激励。
两极寄存器更新使用旧值，交叉混合使用8位权重的移位加法，不用乘法。

baseline_then_gentle.wav：先原版、后gentle。
source_then_baseline_gentle_softer.wav：真实中弱奏音源→原版→gentle→softer，间隔0.4秒。
模型使用完全相同的固定试听增益；真实音源仍沿用先前稳定段响度对齐值。

这不是完整吹口气动模型。源录音自身的起音包络并未拟合；短窗谐波分析受泄漏、频率变化与起点选择影响。
结果、算术检查和限制见results.json；谐波变化图见onset_harmonics.png。
''')
    print(json.dumps({k:dict(early_error_db=v['early_H2_H5_mean_abs_error_vs_source_db'],late_relative_rms_error=v['late_relative_rms_error']) for k,v in report.items()},indent=2),flush=True)
    print('PASS excitation-only onset controls',flush=True)

if __name__=='__main__':main()
