#!/usr/bin/env python3
"""Flute ADSR-only audition using current ENG1 integer arithmetic.

The candidate changes A/D/S/R only. No added breath, EQ or reverb.
Production RTL and deployment resources are not modified.
"""
from pathlib import Path
import hashlib
import json
import numpy as np
import soundfile as sf
import eng1_rtl as E
import router_eng1 as R
import flute_air_envelope as F

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'FFT_results/sim/eng1/flute_envelope_85_20261103'
BASE = ROOT/'FFT_results/sim/eng1/flute_air_envelope_20261103'
A, D, S, RELEASE = 248551, 55924, 1825361100, 380283
FS = F.FS


def envelope_check():
    env = E.Envelope([A], [RELEASE], sustain_level=S, decay_step=D)
    levels = []
    for i in range(FS):
        levels.append(int(env.step([True], [i==0], [False])[0]))
    peak = levels.index(max(levels))
    settled = levels.index(S)
    assert abs(peak/FS-.18) < 2/FS
    assert abs((settled-peak)/FS-.12) < 3/FS
    assert all(v==S for v in levels[settled:])
    release = []
    for i in range(6000):
        release.append(int(env.step([False], [False], [False])[0]))
    end = release.index(0)+1
    assert abs(end/FS-.1) < 2/FS
    assert all(v==0 for v in release[end:])
    return dict(attack_ms=peak*1000/FS, decay_ms=(settled-peak)*1000/FS,
                release_from_sustain_ms=end*1000/FS, sustain_fraction=S/0x7fffffff,
                sustain_db_below_peak=float(20*np.log10(S/0x7fffffff)))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    timing = envelope_check()
    old_report = json.loads((BASE/'results.json').read_text())
    # Cached reference is valid only for the same synthesis code/resources.
    for name in ['python/modal_sim/eng1_rtl.py', 'python/modal_sim/router_eng1.py',
                 'rtl/router/tools/sustain_profiles.json']:
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==old_report['source_hashes'][name]
    old = np.load(BASE/'trace.npz')['production']
    bank = E.ResourceBank.build('flute', F.NOTES)
    synth = E.Eng1Synth('flute', note_map=F.NOTES, resources=bank,
                        stereo=False, reverb='NONE')
    synth.envelope = E.Envelope([A]*4, [RELEASE]*4, sustain_level=S, decay_step=D)
    n = round(F.SECONDS*FS)
    assert len(old) == n
    raw = np.empty(n, dtype=np.int64)
    es = np.empty((n,4), dtype=np.int64)
    ons, offs = {}, {}
    for t,key,dur,vel in F.EVENTS:
        ons.setdefault(round(t*FS), []).append((key,vel))
        offs.setdefault(round((t+dur)*FS), []).append(F.NOTES.index(key))
    rails = 0
    for i in range(n):
        for slot in offs.get(i,[]): synth.note_off(slot)
        for key,vel in ons.get(i,[]): synth.note_on(key,vel)
        frame = synth.step()
        raw[i], es[i] = frame.out, frame.emap
        rails += int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%FS==0: print(f'candidate {i//FS}/{F.SECONDS}s', flush=True)
    assert rails == 0 and not np.any(es[-FS//2:]) and not synth.gate.any()
    assert not np.any(raw[np.all(es==0, axis=1)])
    np.savez_compressed(OUT/'candidate_trace.npz', raw=raw, envelope=es)
    # Same first-note steady window, not whole-phrase RMS or separate peak normalization.
    window = slice(round(.8*FS), round(1.5*FS))
    rms = lambda y: float(np.sqrt(np.mean(np.asarray(y,dtype=float)[window]**2)))
    waves = {'original': old.astype(float), 'gentle_85': raw.astype(float)}
    target = min(.075, *[.88*rms(y)/max(abs(y).max(),1e-30) for y in waves.values()])
    renders = {}
    for name,y in waves.items():
        gain = target/rms(y)
        z = y*gain
        path = OUT/f'{name}.wav'
        sf.write(path, np.repeat(z[:,None],2,axis=1), FS, subtype='PCM_24')
        check, fs = sf.read(path, always_2d=True)
        assert fs==FS and check.shape==(n,2) and np.isfinite(check).all()
        assert abs(check).max() <= .880001
        assert abs(rms(check[:,0])-target) < 1e-6
        assert not np.any(check[-FS//2:])
        renders[name] = dict(file=path.name, playback_gain=gain,
             steady_rms_dbfs=float(20*np.log10(rms(check[:,0]))),
             peak_dbfs=float(20*np.log10(abs(check).max())))
    # Original then candidate, separated by 600ms silence.
    old_wav,_ = sf.read(OUT/'original.wav', always_2d=True)
    new_wav,_ = sf.read(OUT/'gentle_85.wav', always_2d=True)
    sf.write(OUT/'comparison_original_then_gentle.wav',
             np.concatenate([old_wav,np.zeros((round(.6*FS),2)),new_wav]), FS, subtype='PCM_24')
    report = dict(parameters=dict(A_STEP=A,D_STEP=D,S_LEVEL=S,R_STEP=RELEASE),
        timing=timing, sample_rate=FS, seconds=F.SECONDS, events=F.EVENTS,
        renders=renders, steady_match_window_seconds=[.8,1.5], modal_state_rails=rails,
        method='Current ENG1 model rerender, ADSR parameters only. Original cached production reference; source hashes checked. No breath/EQ/reverb. Fixed per-file playback gain matching first-note steady RMS.',
        scope='Sample-frame integer simulation; no production RTL changes or cycle-level RTL verification.',
        sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in [Path(__file__),Path(E.__file__),Path(R.__file__)]})
    (OUT/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    (OUT/'README.md').write_text('''# 长笛轻起音、85%保持包络试听

A_STEP=248551，D_STEP=55924，S_LEVEL=1825361100，R_STEP=380283。
48kHz 下约180ms起音、120ms回落至85%、从85%约100ms释放。
不添加峰值停留阶段，保留原ADSR结构。气息关闭、腔体直通、混响NONE。
使用原ENG1定点模型完整重渲染，非在旧WAV上套曲线；生产RTL未修改。

- gentle_85.wav：新包络。
- original.wav：旧包络，首个长音0.8..1.5秒稳定段响度与新版对齐。
- comparison_original_then_gentle.wav：先旧后新，中间600ms静音。

固定增益，无压缩、EQ或逐段自动增益。短音可能在起音尚未完成时松键。
逐阶段时间、静音、轨限、WAV峰值和响度匹配检查见results.json。
''')
    print(json.dumps(dict(timing=timing,renders=renders),indent=2), flush=True)
    print('PASS envelope stages, stable sustain, release, silence, rails and matched playback',flush=True)

if __name__=='__main__': main()
