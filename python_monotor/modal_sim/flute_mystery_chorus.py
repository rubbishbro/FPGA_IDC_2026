#!/usr/bin/env python3
"""Mystery of Love first chorus: current experimental flute ENG1 audition.

Community melody from Hooktheory's visible Copy Melody export (2026-11-03).
Uses per-note mezzo-piano reference weights, current poles, onset excitation
morph,240ms attack/85% sustain/180ms release. No production RTL modifications.
"""
from pathlib import Path
from dataclasses import replace
import hashlib
import json
import sys
import numpy as np
import soundfile as sf
from scipy.signal import welch
import eng1_rtl as E
import router_eng1 as R
from sustain_engine import SustainPatch
from flute_jet_onset_audition import OnsetExcitation, CONFIGS
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fft_analysis'))
import core as C
import sustain as S

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'python_monotor/results/sim/eng1/flute_mystery_chorus_20261103'
BASE=ROOT/'python_monotor/results/sim/eng1/flute_long_diagnosis_20261103'
URL='https://www.hooktheory.com/theorytab/view/sufjan-stevens/mystery-of-love#chorus'
FS=48000;BPM=108;LEAD=.2;TAIL=.5
# beat (1-based), duration in quarter notes, minor-scale degree, tonic-relative octave.
MELODY=[(1,1.5,1,1),(2.5,.5,7,0),(3,.25,1,1),(3.25,.5,7,0),(3.75,.5,6,0),
 (4.25,.75,5,0),(5,.75,4,0),(8.75,.25,7,-1),(9,1,3,0),(10,1,4,0),
 (11,1,5,0),(12,1,7,0),(13,2,5,0),(15,.75,4,0),
 (17,1.5,1,1),(18.5,.5,7,0),(19,.5,1,1),(19.5,.25,7,0),(19.75,.5,6,0),
 (20.25,.75,5,0),(21,1,4,0),(25,1,3,0),(26,1,4,0),(27,1,5,0),(28,1,7,0),
 (29,2,5,0),(31,1,4,0),(32.25,.25,5,0),(32.5,.5,4,0),(33,.25,3,0),(33.25,.75,1,0)]
MINOR=[0,2,3,5,7,8,10]
EVENTS=[dict(time=LEAD+(beat-1)*60/BPM,duration=duration*60/BPM,
             midi=64+MINOR[degree-1]+12*octave,velocity=100)
        for beat,duration,degree,octave in MELODY]
NOTES=tuple(sorted({e['midi'] for e in EVENTS}))


def response(table,period):
    # Exact linear response of the quantized mode bank at drive harmonics.
    # Used only to design static resource coefficients, not in audio processing.
    w=2*np.pi*np.arange(1,49)/period
    z=np.exp(-1j*w)[:,None]
    h=np.sum((table.G/2**24)[None,:]/(1+(table.a1/2**24)[None,:]*z+(table.a2/2**24)[None,:]*z*z),axis=1)
    h[np.arange(1,49)*FS/period>=FS/2]=0
    return h


def measured_target(midi):
    note=C.midi_to_note(midi) if hasattr(C,'midi_to_note') else None
    names=['C','Cs','D','Ds','E','F','Fs','G','Gs','A','As','B']
    note=names[midi%12]+str(midi//12-1)
    path=ROOT/f'music_resources/flute/flute_{note}_15_mezzo-piano_normal.mp3'
    x=C.load_audio(str(path));on,off=S.note_region(x,FS)
    x=x[on+round(.35*(off-on)):on+round(.75*(off-on))]
    freq,p=welch(x,FS,nperseg=min(16384,len(x)))
    nominal=440*2**((midi-69)/12)
    use=abs(freq-nominal)<nominal*.04
    f0=float(freq[use][np.argmax(p[use])])
    a=np.array([np.sqrt(p[abs(freq-k*f0)<min(.4*f0,max(18,.02*k*f0))].sum()) for k in range(1,49)])
    return a/max(a[0],1e-30),dict(file=str(path.relative_to(ROOT)),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),f0=f0)


def build_bank():
    production=E.ResourceBank.build('flute',NOTES)
    selected=json.loads((BASE/'E4_soft_weights_attack240_release180_coefficients.json').read_text())
    e4=production.notes[64].coeffs.padded(64)
    e4=replace(e4,G=np.array([c['G'] for c in selected['coefficients']],dtype=np.int64))
    reference_norm=np.linalg.norm(response(e4,production.notes[64].period))/production.notes[64].period
    patch=SustainPatch('flute');notes={};audit=[]
    for midi in NOTES:
        row=production.notes[midi];table=row.coeffs.padded(64)
        target,info=measured_target(midi)
        kk,*_=patch.modes(midi,'forte')
        g=table.G.copy()
        if midi==64:
            g=e4.G.copy()
        else:
            # Iterative diagonal amplitude fit; poles and pitch metadata unchanged.
            for _ in range(3):
                h=abs(response(replace(table,G=g),row.period))
                shape=h/max(h[0],1e-30)
                factors=np.clip(target/np.maximum(shape,1e-12),.02,4)
                for i,k in enumerate(kk[:48]):g[i]=round(int(g[i])*factors[int(k)-1])
            power=np.linalg.norm(response(replace(table,G=g),row.period))/row.period
            scale=reference_norm/max(power,1e-30)
            g=np.rint(g*scale).astype(np.int64)
        assert np.all((g>=-(1<<25))&(g<(1<<25)))
        new=replace(table,G=g,label=f'flute:{midi}:mezzo-piano-shape')
        notes[midi]=replace(row,coeffs=new)
        audit.append(dict(midi=midi,reference=info,period=row.period,
            method='Exact selected E4 fit' if midi==64 else 'Measured soft spectral shape fitted using quantized-bank transfer response; RMS equalized to selected E4',
            G=g.tolist(),a1=table.a1.tolist(),a2=table.a2.tolist()))
    return E.ResourceBank('flute',notes),selected['envelope'],audit


def replay_parity(bank,params):
    # Compare normal frame scheduling and zero-pitch replay before rendering.
    a=E.Eng1Synth('flute',note_map=NOTES,resources=bank,stereo=False,reverb='NONE')
    b=E.Eng1Synth('flute',note_map=NOTES,resources=bank,stereo=False,reverb='NONE')
    for s in [a,b]:
        s.envelope=E.Envelope([params['A_STEP']]*len(NOTES),[params['R_STEP']]*len(NOTES),sustain_level=params['S_LEVEL'],decay_step=params['D_STEP'])
        s.excitation=OnsetExcitation([r.period for r in s.rows],**CONFIGS['gentle'])
    gates=np.zeros(len(NOTES),bool);levels=np.zeros(len(NOTES),dtype=np.int64);trig=np.zeros(len(NOTES),bool)
    for i in range(1600):
        trig[:]=False
        if i==20:gates[0]=True;levels[0]=201;trig[0]=True
        if i==1000:gates[0]=False
        x=a.step(gate=gates,level=levels,retrigger=trig)
        y=b.step(gate=gates,level=levels,retrigger=trig,committed_delta=np.zeros(len(NOTES),dtype=np.int64))
        assert x.out==y.out and np.array_equal(x.emap,y.emap) and np.array_equal(x.x,y.x)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    bank,params,resources=build_bank();replay_parity(bank,params)
    (OUT/'note_resources.json').write_text(json.dumps(resources,indent=2)+'\n')
    synth=E.Eng1Synth('flute',note_map=NOTES,resources=bank,stereo=False,reverb='NONE')
    synth.envelope=E.Envelope([params['A_STEP']]*len(NOTES),[params['R_STEP']]*len(NOTES),sustain_level=params['S_LEVEL'],decay_step=params['D_STEP'])
    synth.excitation=OnsetExcitation([r.period for r in synth.rows],**CONFIGS['gentle'])
    end=max(e['time']+e['duration'] for e in EVENTS);n=round((end+TAIL)*FS)
    ons,offs={},{}
    for e in EVENTS:
        ons.setdefault(round(e['time']*FS),[]).append(e)
        offs.setdefault(round((e['time']+e['duration'])*FS),[]).append(NOTES.index(e['midi']))
    gate=np.zeros(len(NOTES),bool);level=np.zeros(len(NOTES),dtype=np.int64);trig=np.zeros(len(NOTES),bool)
    zero=np.zeros(len(NOTES),dtype=np.int64)
    raw=np.empty(n,dtype=np.int64);pcm=np.empty(n,dtype=np.int16);rails=0;attacks=0
    for i in range(n):
        trig[:]=False
        for slot in offs.get(i,[]):gate[slot]=False
        for e in ons.get(i,[]):
            slot=NOTES.index(e['midi'])
            assert not gate[slot]
            gate[slot]=trig[slot]=True
            level[slot]=(e['velocity']<<1)|(e['velocity']>>6)
            attacks+=1
        f=synth.step(gate=gate,level=level,retrigger=trig,committed_delta=zero)
        raw[i]=f.out;pcm[i]=f.pcm[0]
        rails+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%(2*FS)==0:print(f'chorus {i/FS:.0f}/{n/FS:.2f}s',flush=True)
    assert attacks==len(EVENTS)==31 and not gate.any() and rails==0
    assert not np.any(raw[:round(LEAD*FS)]) and not np.any(raw[-round(.2*FS):])
    active=raw[round(LEAD*FS):round(end*FS)].astype(float)
    rms=float(np.sqrt(np.mean(active**2)));peak=float(abs(raw).max())
    gain=min(.09/max(rms,1e-30),.88/max(peak,1e-30))
    y=raw.astype(float)*gain
    path=OUT/'mystery_of_love_chorus_flute.wav'
    sf.write(path,np.repeat(y[:,None],2,axis=1),FS,subtype='PCM_24')
    sf.write(OUT/'mystery_of_love_chorus_flute_native.wav',np.repeat(pcm[:,None],2,axis=1),FS,subtype='PCM_16')
    np.save(OUT/'chorus_raw_q24.npy',raw)
    check,sr=sf.read(path,always_2d=True)
    assert sr==FS and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<.881
    assert not np.any(check[-round(.2*FS):])
    manifest=dict(title='Mystery of Love - first chorus flute audition',composer='Sufjan Stevens',
        melody_source=URL,melody_provenance='Hooktheory visible Chorus / Copy / Copy Melody clipboard export, accessed2026-11-03; community transcription, not an official score.',
        tempo_bpm=BPM,key='E minor',notes=NOTES,note_events=len(EVENTS),seconds=n/FS,
        envelope=params,onset_excitation=CONFIGS['gentle'],body='identity',reverb='NONE',added_breath=False,
        coefficient_method='Per-note mezzo-piano source shape; original production poles retained. E4 uses previously auditioned coefficients; other notes fitted offline and transfer RMS matched to E4.',
        replay_check='1600 sample parity check against normal frame path; zero-pitch committed-frame replay. MIDI parser, loading and core-clock pitch scheduling not rendered.',
        modal_state_rail_hits=rails,native_pcm_rail_samples=int(np.count_nonzero((pcm==-32768)|(pcm==32767))),
        playback_gain=gain,peak_dbfs=float(20*np.log10(abs(check).max())),file=path.name,
        limitations='Experimental timbre extension from E4 to other notes, not production deployed; source melody community transcription. Fixed240ms attack on every note may soften short notes. No legato-specific envelope mode.',
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),Path(E.__file__),Path(R.__file__),ROOT/'python_monotor/modal_sim/flute_jet_onset_audition.py']})
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (OUT/'events.json').write_text(json.dumps(EVENTS,indent=2)+'\n')
    (OUT/'README.md').write_text('''# Mystery of Love 第一段副歌：实验长笛音色

旋律来源：'''+URL+''' 。使用页面 Chorus 的公开 Copy Melody 导出；社区转录，并非官方总谱。
E小调、108BPM，31个音符，保留原旋律节奏和休止。无伴奏。

当前音色：240ms起音、120ms回落至85%、180ms释放；gentle起音激励渐变。
每音高中弱奏谐波权重、生产模态极点、腔体直通、无混响、无新增气息。
E4沿用已经试听的权重；其他音高用各自mezzo-piano采样的谐波比例离线拟合，传递函数RMS向E4对齐。

mystery_of_love_chorus_flute.wav：固定增益PCM24试听版。
mystery_of_love_chorus_flute_native.wav：不调整音量的原生PCM16版。
note_resources.json：逐音高G/a1/a2和参考音源。

使用现有ENG1采样帧定点模型；零变调回放先与正常帧路径对照1600采样。
未模拟MIDI解析/加载/时钟级调度；未修改生产RTL或部署资源。
固定240ms Attack对短音也生效；没有新增连奏包络行为。
检查31次起音、模态轨限、前后静音、有限值和WAV峰值通过；见manifest.json。
''')
    print(json.dumps({k:manifest[k] for k in ['seconds','note_events','modal_state_rail_hits','native_pcm_rail_samples','peak_dbfs']},indent=2),flush=True)
    print('PASS first chorus flute render',flush=True)

if __name__=='__main__':main()
