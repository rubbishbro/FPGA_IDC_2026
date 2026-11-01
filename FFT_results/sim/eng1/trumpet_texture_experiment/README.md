# 小号摩擦/颗粒/气流感对照实验（离线听感）
对象是现有生产 ENG1 E4 基线。没有重跑或修改 RTL、部署系数、旧实验脚本或 git 索引。所有候选只是在 `baseline_*.npy` 上做离线叠加，不能称为 RTL 逐位仿真结果。
## 关键测量
- 真实录音 `music_resources/trumpet/trumpet_E4_15_forte_normal.mp3`：f0 = 329.847 Hz（相对 12-TET E4 +1.15 cents），起音 10–90% = 74.6 ms。
- 合成基线：f0 = 328.767 Hz（-4.52 cents），周期 146 samples；与录音相差 +5.68 cents。
- 归一化谐波分布（24次，录音相对合成）：RMS 误差 0.461 dB，最大绝对误差 0.82 dB。
- 谐波间残差（1–12 kHz，相对峰值）：录音在 10/20/40/60/100/140 Hz 排除带宽下为 -71.0, -71.9, -73.8, -75.3, -77.7, -79.2 dB；合成基线为 -147.0, -148.7, -151.1, -152.6, -154.7, -156.2 dB。录音固定带宽跨度 8.3 dB；把 sustain.py 式 max(10, 0.02·k·f0) 方案也算入，录音总跨度 24.2 dB（-55.1 … -79.2 dB），合成基线总跨度 21.2 dB（-135.0 … -156.2 dB）。说明该指标对泄漏/颤音极敏感，不能当作真实噪声级。
- 短时高/低次谐波比波动（0.8 s，4096/512 STFT）：录音 std = 0.20 dB；合成基线 std = 0.00 dB；`harm_am` std = 0.16 dB。

## 候选（同一 scene 内 active RMS 一致）
| 候选 | 改动 | phrase | E4 single | 单音加入成分 RMS 相对基线 | 单音 peak |
|---|---|---|---|---:|---:|
| `baseline` | 生产基线，无添加 | [baseline_phrase.wav](baseline_phrase.wav) | [baseline_single.wav](baseline_single.wav) | — | -7.38 dBFS |
| `air_lo` | 带色非周期 -36 dB RMS（跟随包络，500 Hz–14 kHz） | [air_lo_phrase.wav](air_lo_phrase.wav) | [air_lo_single.wav](air_lo_single.wav) | -36.00 dB | -7.41 dBFS |
| `air_hi` | 同一噪声 +6 dB（-30 dB RMS） | [air_hi_phrase.wav](air_hi_phrase.wav) | [air_hi_single.wav](air_hi_single.wav) | -30.00 dB | -7.35 dBFS |
| `harm_am` | 仅高次谐波 4% std、2.5–12 Hz 连续 AM | [harm_am_phrase.wav](harm_am_phrase.wav) | [harm_am_single.wav](harm_am_single.wav) | -30.19 dB | -8.29 dBFS |
| `air_harm` | air_lo + harm_am 组合 | [air_harm_phrase.wav](air_harm_phrase.wav) | [air_harm_single.wav](air_harm_single.wav) | -29.20 dB | -8.32 dBFS |
| `hf_static` | 静态高频 +6 dB 高架（转折 2 kHz；亮度对照） | [hf_static_phrase.wav](hf_static_phrase.wav) | [hf_static_single.wav](hf_static_single.wav) | +0.58 dB | -5.90 dBFS |

所有 WAV 为 PCM24、48 kHz、双声道；phrase 与 single 分开做 scene 内 active RMS 匹配。共同峰值安全目标 -1.11 dBFS（linear 0.88），恒定增益、无压缩，末端 20 ms 线性淡出。

## 候选单音测量（0.8–1.4 s 稳态）
| 候选 | 谐波形状误差 vs 基线 (dB RMS) | 残差 40 Hz 排除 (dB rel peak) | 残差 140 Hz 排除 (dB rel peak) | 2 kHz+ 功率占比 | 高/低谐波比 std (dB) |
|---|---:|---:|---:|---:|---:|
| `baseline` | 0.000 | -151.1 | -156.2 | 23.2% | 0.00 |
| `air_lo` | 0.090 | -71.6 | -71.3 | 23.3% | 0.01 |
| `air_hi` | 0.246 | -65.6 | -65.3 | 23.3% | 0.02 |
| `harm_am` | 0.064 | -149.8 | -155.8 | 23.4% | 0.16 |
| `air_harm` | 0.111 | -71.6 | -71.3 | 23.4% | 0.17 |
| `hf_static` | 5.367 | -146.5 | -151.3 | 57.5% | 0.00 |

`air_lo/air_hi` 主要抬高宽带谐波间底噪，基本不改变高/低谐波比的波动；`harm_am` 主要增加高/低谐波比的短时波动（并产生近谐波边带），对 40/140 Hz 排除的宽带残差影响很小；`hf_static` 主要抬高平均亮度（2 kHz+ 占比和高/低比均值），不增加纹理波动。

## 方法限制
- Residual inter-harmonic level is not true broadband noise: Hann leakage, vibrato, frequency drift and MP3 band-limiting contribute; the report shows a 10-140 Hz fixed exclusion sweep plus a sustain.py-style max(10, 0.02*k*f0) variable-width check. The recording's overall span is about 24 dB, so no unique noise level is identifiable.
- The -36/-30 dB RMS air levels are manual sensitivity trials, not a fit to the recording. They bracket the recording's fixed/variable-width residual depending on exclusion; no unique level is identifiable from this data.
- The colored-noise filter follows the local mean inter-harmonic shape but is high-passed at 500 Hz and low-passed at 14 kHz; it is an artificial excitation, not a measured airflow signal.
- The harmonic AM is an artificial 4 % std, 2.5-12 Hz amplitude modulation of the >3.5*f0 band; it does not change pitch and is not vibrato. Its resulting high/low fluctuation is intentionally of the same order as the recording.
- The static high shelf (+6 dB asymptotic high-frequency boost, corner 2 kHz; +3.0 dB at 2 kHz) is a brightness control, not a texture/friction candidate.
- The E4 recording is a 44.1 kHz MP3 resampled once to 48 kHz; high-frequency content above the MP3 band limit is not recoverable.
- The synthetic E4 period is 146 samples (328.767 Hz), about 5.7 cents below the measured recording f0 (329.847 Hz). Each spectrum is measured at its own f0, so this does not bias the normalized harmonic comparison, but the candidates inherit the synth pitch.
- All candidates are offline additions to the existing baseline; they must not be described as production RTL output or as a validated friction model.

## 验证
- 基线 raw 重新载入并逐采样核对；baseline WAV 与 `raw/2**24/8 × 常数增益 × 末端淡出` 的差在 PCM24 量化内。
- 所有 WAV 有限、无 PCM24 触轨、峰值 ≤ 共同安全目标；scene 内 active RMS 在 2e-6 相对误差内一致。
- 端前静音为数字零；single 尾部（2.05 s 后）低于 -80 dBFS，phrase 尾部（10 s 后）同样低于 -80 dBFS。
- `air_hi` 与 `air_lo` 使用同一噪声波形，共同增益前实测差 6.00 dB。
- `baseline_single.wav` 与上一轮 body 实验逐字节一致；`baseline_phrase.wav` 因本轮候选组的共同 scene 目标，比上一轮高 +0.20 dB；原始 npy 未变。
- 没有压缩、没有时变增益（末端 20 ms 淡出除外），没有把真实录音剪进乐句。

## 音频与文件（相对本目录）
- 6 组 × 2 scene：`baseline_*.wav`, `air_lo_*.wav`, `air_hi_*.wav`, `harm_am_*.wav`, `air_harm_*.wav`, `hf_static_*.wav`
- 2.4 s 真实 E4 参考：[recording_reference_E4.wav](recording_reference_E4.wav)（源 `music_resources/trumpet/trumpet_E4_15_forte_normal.mp3`，2.4 s 窗口，源文件末端不足部分补零；单独增益，不属于 RMS 匹配候选组）
- 图：[texture_analysis.png](texture_analysis.png)
- 数值：[results.json](results.json)
- 数组：[analysis_arrays.npz](analysis_arrays.npz), [noise_filter.npz](noise_filter.npz)
