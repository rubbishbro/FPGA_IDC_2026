"""Controlled Class-C noise ablation, not a bit-exact RTL simulation.

    python3 python_monotor/modal_sim/drum_noise_compare.py

Both versions share the exact modal samples, hit lengths, fades and gains.
Only the existing Python noise branch is added; no independent normalisation
or soft clipping is applied to the two versions.
"""

from __future__ import annotations

import json
import os

import numpy as np
import soundfile as sf

import drumkit as DK

OUT = os.path.join(DK.paths.SIM_DRUMS, "noise_compare")
SEED = 3
CAP = 3.0
PIECES = ("kick", "snare", "tom", "hat", "ride", "crash")


def render_hit_pair(kit, key, seconds, vel, rng):
    """Render once, then add/remove noise without changing the modal branch."""
    hit = kit[key]
    modal = DK.render_modal(hit, seconds, vel, rng)
    noise = DK.render_noise(hit, seconds, vel, rng, 1.0)
    # Keep the original full-model kit balance for BOTH versions. Calling
    # render_kit_hit with noise_scale=0 would independently renormalise the hit.
    gain = DK._piece_norm(kit, key, 1.0, CAP) * DK.KIT_GAIN.get(key, 1.0)
    fade = np.ones(modal.size)
    n = min(modal.size, int(0.05 * DK.SR))
    if n > 2:
        fade[-n:] = np.linspace(1.0, 0.0, n) ** 2
    return modal * gain * fade, (modal + noise) * gain * fade


def render_groove_pair(kit):
    seconds = 4 * DK.BAR + CAP
    dry = np.zeros(int(seconds * DK.SR))
    wet = np.zeros_like(dry)
    rng = np.random.default_rng(SEED)
    for beat, key, vel in DK.groove(4):
        pair = render_hit_pair(kit, key, DK.hit_length(kit, key, CAP), vel, rng)
        start = int(round(beat * DK.BEAT * DK.SR))
        for out, segment in zip((dry, wet), pair):
            n = min(segment.size, out.size - start)
            if n > 0:
                out[start:start + n] += segment[:n]
    return dry, wet


def shared_gain(signals):
    if not all(np.isfinite(y).all() for y in signals):
        raise ValueError("Non-finite audio")
    peak = max(float(np.max(np.abs(y))) for y in signals)
    return 0.9 / max(peak, 1e-12)


def write_audio(name, y):
    sf.write(os.path.join(OUT, name), y, DK.SR, subtype="PCM_24")
    return dict(seconds=round(y.size / DK.SR, 3),
                peak=float(np.max(np.abs(y))),
                rms=float(np.sqrt(np.mean(y ** 2))))


def main():
    kit = DK.PC.load_kit(DK.DRUMS)
    os.makedirs(OUT, exist_ok=True)
    dry, wet = render_groove_pair(kit)
    gain = shared_gain((dry, wet))
    dry, wet = dry * gain, wet * gain
    files = {}
    files["groove_no_noise.wav"] = write_audio("groove_no_noise.wav", dry)
    files["groove_with_noise.wav"] = write_audio("groove_with_noise.wav", wet)
    gap = np.zeros(int(DK.SR))
    files["groove_AB.wav"] = write_audio(
        "groove_AB.wav", np.concatenate((dry, gap, wet)))

    pairs = [render_hit_pair(kit, key, CAP, 0.9,
                            np.random.default_rng(SEED + i))
             for i, key in enumerate(PIECES)]
    hit_gain = shared_gain([y for pair in pairs for y in pair])
    blocks, timeline = [], []
    offset = 0
    short_gap = np.zeros(int(0.4 * DK.SR))
    for key, (a, b) in zip(PIECES, pairs):
        timeline.append(dict(piece=key, no_noise_s=offset / DK.SR,
                             with_noise_s=(offset + a.size + short_gap.size) / DK.SR))
        block = np.concatenate((a * hit_gain, short_gap, b * hit_gain, gap))
        blocks.append(block)
        offset += block.size
    files["single_hits_AB.wav"] = write_audio(
        "single_hits_AB.wav", np.concatenate(blocks))

    report = dict(sample_rate=DK.SR, subtype="PCM_24", seed=SEED,
                  bpm=DK.BPM, bars=4, tail_cap_s=CAP,
                  groove_shared_gain=gain, single_hits_shared_gain=hit_gain,
                  single_hits_timeline=timeline, files=files,
                  scope="Python modal/noise ablation, NOT bit-exact RTL",
                  processing="Shared full-model per-piece gain; shared output "
                             "gain per programme; no soft clip or RMS matching")
    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)

    rows = "\n".join(
        f"| {r['piece']} | {r['no_noise_s']:.1f} s | {r['with_noise_s']:.1f} s |"
        for r in timeline)
    readme = f"""# 鼓噪声支路试听对比

运行：`python3 python_monotor/modal_sim/drum_noise_compare.py`

- `groove_no_noise.wav`：A，仅模态，无噪声。
- `groove_with_noise.wav`：B，相同模态 + 原 Python 频谱整形／衰减噪声支路。
- `groove_AB.wav`：先 A（{dry.size / DK.SR:.1f} 秒），静音 1 秒，再 B。
- `single_hits_AB.wav`：单件鼓，每件先无噪声，再有噪声；时刻见下表。

| 鼓件 | 无噪声起点 | 有噪声起点 |
|---|---:|---:|
{rows}

48 kHz、单声道、24-bit PCM。节奏为 120 BPM、4 小节。
每对使用完全相同的模态波形、力度、尾长、淡出和增益，只增减噪声支路。
沿用完整 Python 模型的鼓件平衡，每组共用一个防削波输出增益；不做各自
峰值／响度归一化，也不加软削波、混响或伴奏。因此加噪声带来的音量变化
也被保留，试听时先保持播放音量不变。数值和时间表见 `report.json`。

这是 **Python 噪声消融对照**，不是当前 RTL 的逐位／定点仿真；不能据此
认定 FPGA 实际音色或噪声支路资源开销。原 Python 噪声是带频谱与包络的
鼓音组成部分，并非录音底噪。可重点比较军鼓沙响、踩镲和吊镲的密度与尾音。
"""
    with open(os.path.join(OUT, "README.md"), "w", encoding="utf-8") as fh:
        fh.write(readme)
    for name, info in files.items():
        print(f"wrote {os.path.join(OUT, name)} ({info['seconds']:.1f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
