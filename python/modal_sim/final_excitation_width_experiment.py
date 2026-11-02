#!/usr/bin/env python3
"""Audition rise widths using the actual final guitar2/piano2 Flash tables.

Only excitation rise/width changes. Piano width+gap remains 480 samples;
the existing sequencer's extra inter-pulse counts are deliberately preserved.
This is an offline integer audio model, not RTL simulation or a deployment.
"""
from pathlib import Path
import argparse
import hashlib
import html
import json
import math
import os
import shutil
import time

import numpy as np
import soundfile as sf
from scipy.signal import welch

import eng1_audition as A
import eng1_rtl as E
import router_eng1 as R
from performance_chain import RawPerformance

ROOT = Path(__file__).resolve().parents[2]
FS = 48000
WIDTHS = (2, 4, 8, 16, 32)
DEFAULT_OUT = ROOT/'FFT_results/sim/eng1/final_excitation_width'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rms(x):
    return float(np.sqrt(np.mean(np.asarray(x, dtype=float)**2)))


def db(x):
    return float(20*np.log10(max(float(x), 1e-30)))


def events_for(name, scene):
    if scene == 'phrase':
        notes = [57, 60, 64, 62, 60, 59, 57, 57]
        if name == 'piano_abc':
            notes = [n-12 for n in notes]
        return [dict(time=.12+i*.32, midi=n, duration=.26,
                     velocity=[100, 88, 100, 92, 88, 94, 100, 85][i])
                for i, n in enumerate(notes)]
    notes = [57, 64, 70] if name == 'guitar_abc' else [40, 45, 52]
    return [dict(time=.12+i*1.6, midi=n, duration=.45, velocity=100)
            for i, n in enumerate(notes)]


def audit_excitation(name, cfg):
    """Measure the actual generator, including its subsequent-pulse count quirk."""
    rows = []
    for width in WIDTHS:
        s = A.Strike('piano' if name == 'piano_abc' else 'guitar', 1)
        s.rise, s.width = int(math.log2(width)), width
        s.gap = 480-width if name == 'piano_abc' else 0
        s.pulses = cfg['n_pulse']
        x = np.array([int(s.step([128], [True], [n == 0], [False])[0])
                      for n in range(2200)], dtype=float)/(128 << 16)
        starts = np.flatnonzero((x[1:] > 0) & (x[:-1] == 0))+1
        peaks = [float(np.max(x[a:a+width+1])) for a in starts]
        rows.append(dict(width=width, positive_pulse_starts=starts.tolist(),
                         pulse_start_intervals=np.diff(starts).tolist(),
                         actual_peaks_over_target=peaks,
                         excitation_area_over_target=float(x.sum())))
    return rows


class Batch:
    """Widths are independent groups of the same fixed-point modal voices."""
    def __init__(self, name, manifest, image, notes):
        self.name = name
        self.notes = notes
        self.count = len(notes)
        self.cfg = manifest['frontends'][name]
        self.rows = [next(e for e in manifest['entries']
                          if e['name'] == name and e['midi'] == midi)
                     for midi in notes]
        slots = len(WIDTHS)*self.count
        self.core = R.Eng1Core(slots=slots, n_modes=64)
        for group in range(len(WIDTHS)):
            for slot, row in enumerate(self.rows):
                w = np.frombuffer(image[row['offset']:row['offset']+4096],
                                  dtype='>i4').astype(np.int64).reshape(64, 16)
                self.core.load_slot(group*self.count+slot,
                                    R.Eng1Coeffs(w[:, 0], w[:, 1], w[:, 2], row['modes']))
        c = self.cfg
        self.envelope = E.Envelope([c['a_step']]*slots, [c['r_step']]*slots,
                                   sustain_level=c['s_level'], decay_step=c['d_step'])
        self.strikes = []
        for width in WIDTHS:
            strike = A.Strike('piano' if name == 'piano_abc' else 'guitar', self.count)
            strike.rise = int(math.log2(width))
            strike.width = width
            strike.gap = 480-width if name == 'piano_abc' else 0
            strike.pulses = c['n_pulse']
            self.strikes.append(strike)
        self.body = [R.BodyFilter(coeffs=c['body_q27']) for _ in WIDTHS]
        self.previous_gate = np.zeros(slots, dtype=bool)
        self.previous_dead = np.ones(slots, dtype=bool)
        self.pending_dead = np.zeros(slots, dtype=bool)
        self.rails = np.zeros(len(WIDTHS), dtype=np.int64)
        self.clear = np.zeros(self.count, dtype=bool)

    def step(self, gate, level, trigger):
        gates, triggers = np.tile(gate, len(WIDTHS)), np.tile(trigger, len(WIDTHS))
        old = self.envelope.level.copy()
        self.envelope.step(gates, triggers, np.zeros(len(gates), dtype=bool))
        emap = np.where(triggers, 0, old)
        zero = triggers | (gates & ~self.previous_gate) | self.pending_dead
        excitation = np.concatenate([s.step(level, gate, trigger, self.clear)
                                      for s in self.strikes])
        y, yn = self.core.step(excitation, zero, active_modes=48)
        self.rails += np.count_nonzero(
            ((yn == R.Y_MIN) | (yn == R.Y_MAX)).reshape(len(WIDTHS), -1), axis=1)
        mixed = ((y*emap) >> 31).reshape(len(WIDTHS), self.count).sum(axis=1)
        speaking = ((~self.envelope.dead) & (emap > 0)).reshape(len(WIDTHS), self.count).sum(axis=1)
        if not np.all(speaking == speaking[0]):
            raise ValueError('Envelope/voice-count differs between widths')
        self.pending_dead = self.envelope.dead & ~self.previous_dead
        self.previous_dead = self.envelope.dead.copy()
        self.previous_gate = gates.copy()
        shifts = np.where(speaking == 4, 2, np.where((speaking >= 2) & (speaking <= 7), 1, 0))
        result = np.array([R.wrap_signed(body.step(int(mix))[0] << int(shift), 64)
                           for body, mix, shift in zip(self.body, mixed, shifts)], dtype=np.int64)
        return result, mixed


def render(name, scene, manifest, image, out):
    events = events_for(name, scene)
    notes = sorted({e['midi'] for e in events})
    synth = Batch(name, manifest, image, notes)
    end = max(e['time']+e['duration'] for e in events)
    frames = round((end+1.0)*FS)
    ons, offs = {}, {}
    for event in events:
        ons.setdefault(round(event['time']*FS), []).append(event)
        offs.setdefault(round((event['time']+event['duration'])*FS), []).append(event['midi'])
    gate = np.zeros(len(notes), dtype=bool)
    level = np.zeros(len(notes), dtype=np.int64)
    trigger = np.zeros(len(notes), dtype=bool)
    raw = np.empty((frames, len(WIDTHS)), dtype=np.int64)
    reference = RawPerformance(name, manifest, image, bank=1)
    reference_body = R.BodyFilter(coeffs=synth.cfg['body_q27'])
    rg = np.zeros(16, dtype=bool)
    rl = np.zeros(16, dtype=np.int64)
    rt = np.zeros(16, dtype=bool)
    mapping = {r['midi']: i for i, r in enumerate(reference.rows)}
    checked = min(12000, frames)
    started = time.monotonic()
    for frame in range(frames):
        trigger[:] = False
        for midi in offs.get(frame, []):
            gate[notes.index(midi)] = False
        for event in ons.get(frame, []):
            s = notes.index(event['midi'])
            gate[s] = True
            level[s] = (event['velocity'] << 1) | (event['velocity'] >> 6)
            trigger[s] = True
        raw[frame], mix = synth.step(gate, level, trigger)
        if frame < checked:
            rg[:] = False
            rt[:] = False
            for i, midi in enumerate(notes):
                rg[mapping[midi]], rl[mapping[midi]], rt[mapping[midi]] = gate[i], level[i], trigger[i]
            y, emap, dead = reference.step(rg, rl, rt)
            refmix = int(y.sum())
            if refmix != int(mix[0]):
                raise ValueError(f'{name}/{scene}: baseline mix mismatch at {frame}')
            speaking = int(np.count_nonzero((~dead) & (emap > 0)))
            shift = 2 if speaking == 4 else 1 if 2 <= speaking <= 7 else 0
            expected = R.wrap_signed(reference_body.step(refmix)[0] << shift, 64)
            if expected != int(raw[frame, 0]):
                raise ValueError(f'{name}/{scene}: baseline output mismatch at {frame}')
        if frame and frame % FS == 0:
            print(name, scene, f'{frame/FS:.0f}/{frames/FS:.2f}s', flush=True)
    print('finished', name, scene, f'{time.monotonic()-started:.1f}s wall', flush=True)
    folder = out/name
    (folder/'native').mkdir(parents=True, exist_ok=True)
    np.save(folder/f'{scene}_raw_q24.npy', raw)
    # Center pan has unity gain in the current RTL; ITD and reverb are disabled.
    wide = raw.astype(float)/(1 << 24)/8
    active = slice(round(.12*FS), round(end*FS))
    levels = np.array([rms(wide[active, i]) for i in range(len(WIDTHS))])
    peaks = np.max(np.abs(wide), axis=0)
    target = min(.075, *(.88*levels/np.maximum(peaks, 1e-30)))
    rows, listening = [], []
    for i, width in enumerate(WIDTHS):
        gain = target/max(levels[i], 1e-30)
        z = wide[:, i]*gain
        z[-960:] *= np.linspace(1, 0, 960)
        path = folder/f'{scene}_rise{width}.wav'
        sf.write(path, np.repeat(z[:, None], 2, axis=1), FS, subtype='PCM_24')
        unbounded_pcm = (raw[:, i]+2048) >> 12
        native = np.clip(unbounded_pcm, -32768, 32767).astype(np.int16)
        sf.write(folder/'native'/path.name, np.repeat(native[:, None], 2, axis=1), FS, subtype='PCM_16')
        reread, sr = sf.read(path, always_2d=True)
        if sr != FS or not np.isfinite(reread).all() or np.max(np.abs(reread)) > .880001:
            raise ValueError('Invalid listening WAV')
        if abs(db(rms(reread[active, 0]))-db(target)) > .0001:
            raise ValueError('Listening RMS mismatch')
        onset = round(events[0]['time']*FS)
        f, power = welch(wide[onset:onset+round(.2*FS), i], fs=FS, nperseg=2048)
        hf = float(power[f >= 4000].sum()/max(power.sum(), 1e-30))
        rows.append(dict(width=width, rise_us=width/FS*1e6, file=str(path.relative_to(out)),
                         native_file=str((folder/'native'/path.name).relative_to(out)),
                         native_active_rms_dbfs=db(levels[i]), native_peak_dbfs=db(peaks[i]),
                         native_clipped_samples=int(np.count_nonzero((unbounded_pcm < -32768) | (unbounded_pcm > 32767))),
                         native_rail_samples=int(np.count_nonzero((native == -32768) | (native == 32767))),
                         modal_state_rail_samples=int(synth.rails[i]), body_saturations=synth.body[i].sat_total,
                         listening_gain_db=db(gain), listening_active_rms_dbfs=db(target),
                         onset_power_above_4khz_fraction=hf,
                         onset_spectral_centroid_hz=float(np.sum(f*power)/max(power.sum(), 1e-30)),
                         sha256=sha(path)))
        listening.append(reread)
    montage = np.concatenate([part for wave in listening for part in
                              [wave, np.zeros((round(.35*FS), 2))]])
    sf.write(folder/f'{scene}_comparison_2_4_8_16_32.wav', montage, FS, subtype='PCM_24')
    return dict(instrument=name, scene=scene, events=events, frames=frames, seconds=frames/FS,
                baseline_reference_frames_checked=checked, variants=rows)


def publish(out, result):
    (out/'results.json').write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n')
    os.environ.setdefault('MPLCONFIGDIR', '/tmp/final_excitation_width_mpl')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.8))
    for ax, name, title in zip(axes, ['guitar_abc', 'piano_abc'], ['Guitar 2', 'Piano 2']):
        row = next(r for r in result['renders'] if r['instrument'] == name and r['scene'] == 'single')
        raw = np.load(out/name/'single_raw_q24.npy')
        start = round(row['events'][0]['time']*FS)
        for i, width in enumerate(WIDTHS):
            f, p = welch(raw[start:start+9600, i].astype(float), fs=FS, nperseg=4096)
            ax.plot(f, 10*np.log10(np.maximum(p/max(p.max(), 1e-30), 1e-12)), label=f'{width} samples', lw=.8)
        ax.set(xlim=(50, 16000), ylim=(-90, 2), xscale='log', xlabel='Frequency (Hz)', ylabel='Power / own spectral peak (dB)', title=title)
        ax.grid(alpha=.2)
        ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(out/'onset_spectra.png', dpi=150)
    sections = []
    for name, label in [('guitar_abc', '吉他 2'), ('piano_abc', '钢琴 2')]:
        pieces = [f'<h2>{label}</h2>']
        for scene, title in [('phrase', '旋律'), ('single', '三个独立音符')]:
            row = next(r for r in result['renders'] if r['instrument'] == name and r['scene'] == scene)
            pieces.append(f'<h3>{title}：依次 2 / 4 / 8 / 16 / 32 采样，每档间隔 0.35 秒</h3>'
                          f'<audio controls preload="none" src="{name}/{scene}_comparison_2_4_8_16_32.wav"></audio>')
            for v in row['variants']:
                pieces.append(f'<p>{v["width"]} 采样（{v["rise_us"]:.1f} μs） · 原始 RMS {v["native_active_rms_dbfs"]:.2f} dBFS · 原始削顶 {v["native_clipped_samples"]} 采样</p>'
                              f'<audio controls preload="none" src="{html.escape(v["file"])}"></audio>')
        sections.append(''.join(pieces))
    page = '<!doctype html><meta charset="utf-8"><title>最终系数：激励宽度试听</title><style>body{font:16px system-ui;max-width:960px;margin:36px auto;padding:0 20px;background:#f6f7fa;color:#17263a}audio{width:100%}h2{margin-top:48px}p{line-height:1.6}</style><h1>最终系数：激励上升采样数对照</h1><p>48 kHz；使用当前正式 BIN 中的系数、琴体与包络。只改变上升采样数；钢琴 PW_LEN+GAP_LEN 保持 480。试听按每种乐器、每个场景的有效段 RMS 拉齐；native/ 保存固定标尺 PCM16。未更改生产资源或 RTL。</p><p>增加上升采样数会拉长触弦时间，不代表提高采样率。各档力度目标相同，激励面积和频谱不同；本轮没有重新标定 G。</p><p>钢琴存在现有计数偏差：后续击锤从 cnt=0 开始，比首锤多累加一次。2采样档第二锤实际峰值为目标A的1.03125，32采样档为0.708984；实际击锤起点间隔为481/482采样。本轮保留该行为，因此钢琴比较也包含后续击锤峰值的变化。详细脉冲审计见 results.json。</p><img style="width:100%" src="onset_spectra.png">'+''.join(sections)
    (out/'index.html').write_text(page)
    lines = ['# 最终系数的激励上升采样数实验', '', '[试听页](index.html)', '',
             '使用现有吉他2、钢琴2正式系数，比较2/4/8/16/32采样；48kHz、固定力度目标。',
             '琴体、包络、模态G/a1/a2、演奏事件均冻结。钢琴PW_LEN+GAP_LEN保持480采样。',
             '钢琴保留现有后续击锤cnt=0的偏差：上升多累加一次，实际击锤起点间隔481/482采样。',
             '2采样档第二锤实际峰值为A的1.03125，32采样档为0.708984；不能视为严格等峰值实验。',
             '采用整数Python音频模型；各场景前12000帧的2采样基线与RawPerformance逐点对照。',
             '关闭混响和ITD，中心声像单位增益，headroom=3，使用当前按发声数移位的总增益。',
             '不是RTL仿真、综合或板级验收，未修改生产资源。', '',
             '试听使用量化为PCM16前的宽位输出，经恒定增益拉齐每个场景的有效段RMS；末端20ms淡出。',
             'native/保留固定标尺PCM16。原始削顶、模态触轨、滤波饱和见results.json。',
             '所有文件SHA256与来源快照均有记录；未引入生产硬件乘法器。', '',
             '复跑：`python python/modal_sim/final_excitation_width_experiment.py`。', '']
    (out/'README.md').write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sources = [Path(__file__), ROOT/'python/modal_sim/eng1_audition.py',
               ROOT/'python/modal_sim/eng1_rtl.py', ROOT/'python/modal_sim/router_eng1.py',
               ROOT/'python/modal_sim/body_fixed_point.py', ROOT/'python/modal_sim/performance_chain.py',
               ROOT/'rtl/router/routers/exc_router.sv', ROOT/'rtl/router/routers/env_router.sv',
               ROOT/'rtl/router/routers/body_router.sv', ROOT/'rtl/router/parts/polyphony_gain.sv',
               ROOT/'rtl/router/tools/performance/resources.json', ROOT/'rtl/router/tools/performance/resources.bin']
    hashes = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    for p in sources:
        dest = out/'source_snapshot'/p.relative_to(ROOT)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, dest)
    manifest = json.loads((out/'source_snapshot/rtl/router/tools/performance/resources.json').read_text())
    image = (out/'source_snapshot/rtl/router/tools/performance/resources.bin').read_bytes()
    if hashlib.sha256(image).hexdigest() != manifest['image_sha256']:
        raise ValueError('Resource image hash mismatch')
    renders = [render(name, scene, manifest, image, out)
               for name in ['guitar_abc', 'piano_abc'] for scene in ['phrase', 'single']]
    changed = [path for path, digest in hashes.items() if sha(ROOT/path) != digest]
    if changed:
        raise ValueError(f'Inputs changed during experiment: {changed}')
    result = dict(sample_rate=FS, widths=WIDTHS, resource_sha256=manifest['image_sha256'],
                  coefficient_policy='Final production bytes frozen; no modal gain recalibration',
                  experiment='Equal force target; rise duration changes, not sample rate; existing subsequent-pulse counting preserved',
                  excitation_audit={name: audit_excitation(name, manifest['frontends'][name])
                                    for name in ['guitar_abc', 'piano_abc']},
                  output='Integer sample model, no reverb/ITD, center unity, headroom3, current voice-count gain',
                  source_hashes=hashes, renders=renders, production_files_modified=False,
                  rtl_simulation=False, synthesis=False, pnr=False)
    publish(out, result)
    print('DONE', out/'index.html', flush=True)


if __name__ == '__main__':
    main()
