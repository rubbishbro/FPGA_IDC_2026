#!/usr/bin/env python3
"""Excitation-side trumpet sensitivity tests with frozen production coefficients.

The lip pulse and transient jitter are phenomenological controls, not a coupled
lip/pressure/bore physical model. Input and output-air paths are kept separate.
"""
from pathlib import Path
import hashlib
import json
import math
import os
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, lfilter, freqz
import eng1_audition as A
import eng1_rtl as E
import router_eng1 as R

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'FFT_results/sim/eng1/trumpet_excitation_experiment'
BASE = ROOT/'FFT_results/sim/eng1/trumpet_body_experiment'
NOTES = (64,66,67,69,72,74,76,77)
FS = 48000
SEED = 20261031


def rms(y): return float(np.sqrt(np.mean(np.asarray(y)**2)))


def lip_kernel(period):
    # Smooth opening lobe, shorter opposite closing lobe; zero area.
    opening, closing = max(3,round(.12*period)), max(2,round(.03*period))
    a = np.sin(np.pi*(np.arange(opening)+.5)/opening); a /= a.sum()
    b = np.sin(np.pi*(np.arange(closing)+.5)/closing); b /= b.sum()
    kernel = np.r_[a,np.zeros(max(1,round(.02*period))),-b]
    h1 = abs(np.sum(kernel*np.exp(-2j*np.pi*np.arange(len(kernel))/period)))
    kernel /= h1
    assert len(kernel)<period and abs(kernel.sum())<1e-10
    assert abs(abs(np.sum(kernel*np.exp(-2j*np.pi*np.arange(len(kernel))/period)))-1)<1e-12
    return kernel


class LipExcitation(E.Excitation):
    def __init__(self, periods, *, shape=False, unstable=False, air=False, noise=None):
        self.shape_on, self.unstable, self.air = shape, unstable, air
        self.noise = noise
        self.kernels = [lip_kernel(int(p)) if shape else np.ones(1) for p in periods]
        super().__init__(periods)

    def reset(self):
        super().reset()
        self.rng = np.random.default_rng(SEED)
        self.age = np.zeros(self.slots,dtype=np.int64)
        self.rate = np.zeros(self.slots,dtype=np.int64)
        self.position = np.full(self.slots,10000,dtype=np.int64)
        self.amplitude = np.zeros(self.slots,dtype=float)
        self.n = 0; self.noise_energy = 0.; self.pulse_energy = 0.
        self.max_rate = 0.; self.min_amp = 1.; self.max_amp = 1.

    def step(self, gate, level, trigger, clear, delta):
        starts = gate & (trigger | ~self.previous_gate)
        self.age[starts|clear|~gate] = 0
        self.rate[starts|clear|~gate] = 0
        self.position[starts|clear|~gate] = 10000
        impulse = super().step(gate,level,trigger,clear,delta+self.rate)
        result = np.zeros(self.slots,dtype=np.int64)
        for s in range(self.slots):
            if not gate[s] or clear[s]: continue
            age = int(self.age[s])
            if impulse[s]:
                fade = math.exp(-age/(FS*.030)) if self.unstable else 0.
                rate = float(np.clip(self.rng.normal(0,.006)*fade,-.018,.018)) if fade else 0.
                amp = float(np.clip(1+self.rng.normal(0,.08)*fade,.76,1.24)) if fade else 1.
                self.rate[s] = round(rate*(1<<24))
                self.max_rate = max(self.max_rate,abs(rate))
                self.min_amp = min(self.min_amp,amp);self.max_amp = max(self.max_amp,amp)
                self.amplitude[s] = int(impulse[s])*amp
                self.position[s] = 0
                self.pulse_energy += float(impulse[s])**2
            pos = int(self.position[s]); kernel = self.kernels[s]
            value = 0
            if pos<len(kernel):
                value = round(self.amplitude[s]*kernel[pos]);self.position[s] += 1
            if self.air:
                # Relative to the RMS of the nominal impulse train, not output.
                strength = .040*math.exp(-age/(FS*.040))+.005
                noise = round((int(level[s])<<16)/math.sqrt(int(self.period[s]))*strength*self.noise[self.n,s])
                value += noise; self.noise_energy += float(noise)**2
            result[s] = value
            self.age[s] += 1
        assert np.all((result>=-(1<<31))&(result<(1<<31)))
        self.n += 1
        return result

    def metrics(self):
        return dict(max_instantaneous_frequency_offset_fraction=self.max_rate,
                    pulse_amplitude_multiplier_range=[self.min_amp,self.max_amp],
                    air_to_nominal_pulse_energy_db=None if not self.noise_energy else 10*math.log10(self.noise_energy/self.pulse_energy))


def verify_unmodified_scheduler(periods):
    a=E.Excitation(periods);b=LipExcitation(periods)
    gate=np.zeros(len(periods),bool);trig=gate.copy();zero=gate.copy()
    level=np.full(len(periods),201,dtype=np.int64);delta=np.zeros(len(periods),dtype=np.int64)
    for n in range(12000):
        gate[:]=(100<=n<6000) or (6500<=n<11000)
        trig[:]=n in [100,3000,6500]
        assert np.array_equal(a.step(gate,level,trig,zero,delta),b.step(gate,level,trig,zero,delta))


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    bank=E.ResourceBank.build('trumpet',NOTES)
    periods=[bank.notes[m].period for m in NOTES]
    verify_unmodified_scheduler(periods)
    config=dict(pulse_shape=dict(shape=True),onset_instability=dict(unstable=True),
                drive_air=dict(air=True),combined_drive=dict(shape=True,unstable=True,air=True))
    scene_records=[];traces={}
    for scene in ['phrase','single']:
        reference=np.load(BASE/f'baseline_{scene}.npy');n=len(reference)
        random=np.random.default_rng(SEED+(scene=='single')).standard_normal((n,8))
        sos=butter(2,[500,10000],btype='bandpass',fs=FS,output='sos')
        noise=sosfilt(sos,random,axis=0);noise/=np.sqrt(np.mean(noise**2,axis=0))[None,:]
        synths={};outputs={};rails={};native_rails={}
        for name,cfg in config.items():
            s=E.Eng1Synth('trumpet',note_map=NOTES,resources=bank,stereo=False)
            s.excitation=LipExcitation(periods,noise=noise,**cfg)
            synths[name]=s;outputs[name]=np.empty(n,dtype=np.int64);rails[name]=native_rails[name]=0
            if scene=='single':traces[name]=np.empty(n,dtype=np.int64)
        events=A.score() if scene=='phrase' else [dict(time=.12,midi=64,duration=1.5,velocity=100)]
        ons={};offs={}
        for e in events:
            ons.setdefault(round(e['time']*FS),[]).append(e)
            offs.setdefault(round((e['time']+e['duration'])*FS),[]).append(e['midi'])
        delta=np.zeros(8,dtype=np.int64)
        for i in range(n):
            for m in offs.get(i,[]):
                for s in synths.values():s.note_off(NOTES.index(m))
            for e in ons.get(i,[]):
                for s in synths.values():s.note_on(e['midi'],e['velocity'])
            for name,s in synths.items():
                f=s.step(committed_delta=delta);s.trigger[:]=False;outputs[name][i]=f.out
                rails[name]+=int(np.count_nonzero((s.core.y1==R.Y_MAX)|(s.core.y1==R.Y_MIN)))
                native_rails[name]+=int(f.pcm[0] in [-32768,32767])
                if scene=='single':traces[name][i]=f.x[0]
            if i and i%(FS*3)==0:print(scene,f'{i/FS:.0f}/{n/FS:.2f}s',flush=True)
        assert not any(rails.values()) and not any(native_rails.values())
        signals={name:y.astype(float)/(1<<24)/8 for name,y in outputs.items()}
        signals['baseline']=reference.astype(float)/(1<<24)/8
        active=slice(5760,466560 if scene=='phrase' else 77760)
        # An explicit parallel breath path checks what the resonator bank removes.
        env=np.sqrt(np.maximum(lfilter(np.ones(480)/480,[1.],signals['baseline']**2),0))
        breath=noise[:,0]*env*(reference!=0)
        breath*=rms(signals['baseline'][active])*10**(-36/20)/max(rms(breath[active]),1e-30)
        signals['combined_parallel_breath']=signals['combined_drive']+breath
        target=min(.075,*[.88*rms(y[active])/max(abs(y).max(),1e-30) for y in signals.values()])
        rows={}
        for name,y in signals.items():
            gain=target/rms(y[active]);z=y*gain;z[-960:]*=np.linspace(1,0,960)
            path=OUT/f'{name}_{scene}.wav';sf.write(path,np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
            check,fs=sf.read(path,always_2d=True)
            assert fs==FS and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<=.880001
            assert abs(20*math.log10(rms(check[active,0])/target))<.00002
            assert not np.any(check[:4800])
            rows[name]=dict(file=path.name,frames=n,gain_db=20*math.log10(gain),
                active_rms_dbfs=20*math.log10(rms(check[active,0])),peak_dbfs=20*math.log10(abs(check).max()),
                excitation=synths[name].excitation.metrics() if name in synths else None,
                state_rail_hits=rails.get(name),native_mono_pcm_rail_samples=native_rails.get(name),
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            np.save(OUT/f'{name}_{scene}.npy',y)
        scene_records.append(dict(scene=scene,active_samples=[active.start,active.stop],variants=rows))
        print('PASS',scene,'RMS/peak/state rails',flush=True)
    for name,x in traces.items():np.save(OUT/f'{name}_excitation_E4.npy',x)
    summary=dict(sample_rate=FS,seed=SEED,scenes=scene_records,baseline_excitation_scheduler_bit_exact=True,
        coefficients='Production G/a1/a2 unchanged. Original envelope/release retained. No modal gain boost.',
        pulse='Opposite half-sine lobes: opening12%period, gap2%, closing3%; zero-area; fundamental magnitude normalized to unit impulse, phase not matched.',
        instability='Per-cycle frequency offset std0.6%, clipped1.8%; amplitude std8%, clipped0.76..1.24. Both decay exponentially with30ms time constant after each note-on.',
        drive_air='500..10000Hz bandpassed Gaussian drive; RMS ratio to nominal impulse train =0.040*exp(-age/40ms)+0.005 while gated. Resonator filtering affects audible noise level.',
        parallel_air='combined_parallel_breath adds separate500..10000Hz breath to combined_drive at-36dB active RMS relative to production baseline, following baseline envelope. Other variants have no parallel path.',
        limitations='Phenomenological excitation controls, not a coupled lips/breath-pressure/bore simulation. Pulse/table co-design would be required for production. Input noise level is not output noise level.',
        normalization='Matched active RMS per scene; constant gain, peak<=.88,20ms file-end fade.',
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [Path(__file__),Path(E.__file__),ROOT/'FFT_results/params/trumpet_sustain.npz',BASE/'baseline_phrase.npy',BASE/'baseline_single.npy']})
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib;matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(1,2,figsize=(12,4))
    p=periods[0];k=lip_kernel(p)
    base=np.zeros(p);base[0]=1;wave=np.zeros(p);wave[:len(k)]=k
    axes[0].plot(np.arange(p)/48,base,label='production impulse');axes[0].plot(np.arange(p)/48,wave,label='bipolar lip-like control')
    axes[0].set(xlabel='Time(ms)',ylabel='Input/unit pulse',title='One E4 period')
    orders=np.arange(1,25);h=np.array([abs(np.sum(k*np.exp(-2j*np.pi*np.arange(len(k))*order/p))) for order in orders])
    axes[1].plot(orders,20*np.log10(np.maximum(h,1e-15)),'.-');axes[1].axhline(0,color='gray',linestyle='--')
    axes[1].set(xlabel='Harmonic order',ylabel='Input gain vs impulse(dB)',title='Pulse changes modal driving spectrum')
    for ax in axes:ax.grid(alpha=.2)
    axes[0].legend();fig.tight_layout();fig.savefig(OUT/'excitation.png',dpi=150);plt.close(fig)
    lines=['# Trumpet excitation controls','','All candidates retain production modal coefficients, envelope and release. These are experimental excitation models.',
           '',summary['pulse'],'',summary['instability'],'',summary['drive_air'],'',summary['parallel_air'],'',summary['limitations'],'',
           '| Candidate | Phrase | Single |','|---|---|---|']
    for name in scene_records[0]['variants']:lines.append(f'| {name} | [play]({name}_phrase.wav) | [play]({name}_single.wav) |')
    lines+=['','[Results](results.json)','','![Excitation](excitation.png)','','Run: `python python/modal_sim/trumpet_excitation_experiment.py`']
    (OUT/'README.md').write_text('\n'.join(lines)+'\n')
    print('PASS all excitation candidates',flush=True)


if __name__=='__main__':main()
