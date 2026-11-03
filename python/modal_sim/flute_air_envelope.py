#!/usr/bin/env python3
"""Experimental flute breath at the existing envelope multiplier input.

No production RTL changes. LFSR32 + one-pole DC removal + shifts/adds feed
(y_modal + air) into the existing signed64 x signed32 envelope multiplier.
Model arithmetic only: no added multiplier, modal rerender per candidate, EQ,
reverb, or post-envelope noise. Cycle scheduling and PnR remain unverified.
"""
from pathlib import Path
import hashlib
import json
import numpy as np
import soundfile as sf
import eng1_rtl as E
import router_eng1 as R

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'FFT_results/sim/eng1/flute_air_envelope_20261103'
FS = 48000
NOTES = (64, 67, 72, 76)
SECONDS = 7.2
# Long tones, separated attacks, and a short two-voice overlap.
EVENTS = [(.12,64,1.55,100),(1.95,67,.28,100),(2.35,72,.28,100),
          (2.75,76,.55,100),(3.55,72,1.0,80),(3.95,64,.6,80),
          (4.95,67,.30,110),(5.35,64,.95,100)]
SHIFTS = {'baseline': None, 'air_light': 4, 'air_medium': 3, 'air_strong': 2}
SEEDS = (0x13579bdf, 0x2468ace1, 0x3579bdf1, 0x468ace13)


def noise_step(lfsr, dc):
    """One update/voice/audio frame, even when silent. All states signed32.

    Fibonacci x^32+x^22+x^2+x+1, left shift, output signed top24.
    lp_next = lp + ((white-lp) >>> 4); hp = white-lp_next.
    A fixed shift selects breath strength (no gain multiplier).
    """
    bit = ((lfsr >> 31) ^ (lfsr >> 21) ^ (lfsr >> 1) ^ lfsr) & 1
    lfsr = ((lfsr << 1) | bit) & 0xffffffff
    white = R.wrap_signed(lfsr >> 8, 24)
    dc = R.wrap_signed(dc + ((white-dc) >> 4), 32)
    return lfsr, dc, R.wrap_signed(white-dc, 32)


def env_mul(modal, air, envelope):
    """Existing y_mul[94:31]: signed64 input, signed32 E, 96-bit product."""
    operand = R.wrap_signed(int(modal)+int(air), 64)
    product = operand * R.wrap_signed(int(envelope), 32)
    return R.wrap_signed(product >> 31, 64)


def source_hashes():
    files = [Path(__file__), Path(E.__file__), Path(R.__file__),
             ROOT/'rtl/router/voice_router.sv', ROOT/'rtl/router/routers/body_router.sv',
             ROOT/'rtl/router/tools/sustain_profiles.json']
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def trace():
    bank = E.ResourceBank.build('flute', NOTES)
    synth = E.Eng1Synth('flute', note_map=NOTES, resources=bank, stereo=False, reverb='NONE')
    n = round(SECONDS*FS)
    ys = np.empty((n,4), dtype=np.int64)
    es = ys.copy()
    out = np.empty(n, dtype=np.int64)
    shifts = np.empty(n, dtype=np.int8)
    ons, offs = {}, {}
    for t, key, dur, vel in EVENTS:
        ons.setdefault(round(t*FS), []).append((key, vel))
        offs.setdefault(round((t+dur)*FS), []).append(NOTES.index(key))
    rails = 0
    for i in range(n):
        for slot in offs.get(i, []): synth.note_off(slot)
        for key, vel in ons.get(i, []): synth.note_on(key, vel)
        f = synth.step()
        ys[i], es[i], out[i] = f.y, f.emap, f.out
        shifts[i] = (synth.poly_gain//4096).bit_length()-1
        rails += int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i % FS == 0: print(f'production trace {i//FS}/{SECONDS}s', flush=True)
    assert not synth.gate.any() and not np.any(es[-1])
    np.savez_compressed(OUT/'trace.npz', modal=ys, envelope=es, production=out, poly_shift=shifts)
    return ys, es, out, shifts, rails


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ys, es, native, shifts, rails = trace()
    n = len(ys)
    signals = {name: np.empty(n, dtype=np.int64) for name in SHIFTS}
    lfsr, dc = list(SEEDS), [0]*4
    overflow = 0
    for i in range(n):
        air = []
        for s in range(4):
            lfsr[s], dc[s], hp = noise_step(lfsr[s], dc[s])
            assert lfsr[s] != 0
            air.append(hp)
        for name, amount in SHIFTS.items():
            total = 0
            for s in range(4):
                addition = 0 if amount is None else air[s] >> amount
                operand = int(ys[i,s])+addition
                overflow += int(not -(1 << 63) <= operand < (1 << 63))
                total += env_mul(ys[i,s], addition, es[i,s])
            signals[name][i] = R.wrap_signed(R.wrap_signed(total,64) << int(shifts[i]),64)
    assert np.array_equal(signals['baseline'], native), 'production baseline mismatch'
    silent = np.all(es == 0, axis=1)
    assert all(not np.any(y[silent]) for y in signals.values())
    assert overflow == 0 and rails == 0
    active = np.any(es > 0, axis=1)
    rms = lambda y: float(np.sqrt(np.mean(np.asarray(y,dtype=float)[active]**2)))
    # Common playback gain: candidate strengths are not individually normalized.
    gain = min(.09/rms(native), .88/max(float(abs(y).max()) for y in signals.values()))
    report = {}
    for name, y in signals.items():
        z = y.astype(float)*gain
        path = OUT/f'{name}.wav'
        sf.write(path, np.repeat(z[:,None],2,axis=1), FS, subtype='PCM_24')
        check, fs = sf.read(path, always_2d=True)
        assert fs==FS and check.shape==(n,2) and np.isfinite(check).all()
        assert abs(check).max() <= .880001 and not np.any(check[silent])
        addition = y-native
        report[name] = dict(file=path.name, shift=SHIFTS[name],
            peak_dbfs=float(20*np.log10(abs(check).max())),
            rms_dbfs=float(20*np.log10(rms(check[:,0]))),
            air_to_tone_rms_db=None if name=='baseline' else float(20*np.log10(rms(addition)/rms(native))))
    result = dict(sample_rate=FS, seconds=SECONDS, notes=NOTES, events=EVENTS,
        seeds=SEEDS, variants=report, common_playback_gain=gain,
        baseline_bit_exact=True, silent_frames=int(silent.sum()), operand_overflows=overflow,
        modal_state_rails=rails, source_hashes=source_hashes(),
        method='signed64(modal+(HP_LFSR24 >>> strength)) * signed32(envelope), product[94:31]; original polyphony gain; body passthrough; no reverb',
        scope='Framework-constrained arithmetic simulation; production RTL unchanged. No new multiplier or hardware module; requires LFSR/DC registers, shifts and pre-multiply adder in a future RTL implementation. Cycle timing, synthesis and PnR not verified.',
        limitation='Fixed breath level before ADSR: follows ADSR and release, but is not separately scaled by MIDI velocity/pressure. Levels are audition choices, not source-calibrated airflow.')
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    (OUT/'README.md').write_text('''# 长笛气息：复用包络乘法器的定点仿真

输入：现有 ENG1 模态输出。气息在包络乘法器前相加，不进入模态库。
公式：`y_env = signed64((signed64(y_modal + (air >>> shift)) * E) >>> 31)`。
复用 64×32 包络乘法；新增运算仅为 LFSR、单极点去直流的移位加减、乘前加法。
每声部独立固定种子，每音频帧推进一次；用旧 ADSR 控制起音和释放，E=0 时严格静音。
腔体保持生产直通，无额外 EQ、混响、压缩或后包络噪声。

baseline / air_light / air_medium / air_strong 使用同一固定播放增益。
含长音、短音、双音重叠和松键尾部。强度是试听选择，并非实测标定。
气息目前仅随 ADSR，不单独随 MIDI velocity/压力缩放。

这是算术结构实验；未改生产 RTL，未验证时钟调度、资源和 PnR。
原版逐样本复现检查、零包络静音、状态轨限、乘前加法溢出和 WAV 有限值/峰值检查见 results.json。
''')
    print(json.dumps(report, indent=2), flush=True)
    print('PASS baseline parity, envelope silence, modal rails, operand overflow and PCM checks', flush=True)

if __name__ == '__main__': main()
