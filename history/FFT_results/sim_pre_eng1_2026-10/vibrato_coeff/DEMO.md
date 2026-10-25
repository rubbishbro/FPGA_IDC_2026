# 颤音 A/B 试听

脚本：`python/modal_sim/vibrato_demo.py`  
合成器：B 类用 `SustainSynth`；A 类/纯音/音高 sonification 用同一组 cello 模态参数。
**不是**对录音做 FFT 再分析。

短句：cello C2 2.8 s → C4 3.0 s；深度 20 cents，LFO 5.2 Hz；
AM、噪声、roughness 全关，只保留纯音高颤音。

| 文件 | a1 更新方式 | 预期 |
|---|---|---|
| `demo_off.wav` | 无颤音 | 平直参考 |
| `demo_exact.wav` | `-2r cos(ρθ)` | 精确参考 |
| `demo_linear.wav` | `a1₀ + s(ρ-1)θ` | 和 exact 几乎一样 |
| `demo_q20.wav` | 当前 Q2.20 + δθ Q3.14 整数 | C2 有粗糙/音色抖动 |
| `demo_q24.wav` | Q2.24 + δθ Q3.20 整数 | C2 顺滑很多 |
| `demo_ab_q20_q24.wav` | q20 → 0.4 s 静音 → q24 | 最快听出差别 |
| `demo_ab_exact_q20.wav` | exact → 0.4 s 静音 → q20 | 对照精确参考 |

每个文件独立归一化到 -1 dBFS 附近，方便直接 A/B；
听 C2 段（前 2.8 s）最容易分辨，C4 段（后 3 s）差异会小一些。
音高轨迹见 `fig_staircase.png` 左图（C2）。

## B 类（持续音）残差

| 片段 | exact-linear | exact-q20 | exact-q24 |
|---|---:|---:|---:|
| C2 | -40.9 dB | -16.2 dB | -26.9 dB |
| C4 | -37.7 dB | -13.8 dB | -28.3 dB |

注意：B 类的音高由驱动 NCO 决定，q20 的差别主要是**共振/音色/幅度抖动**，
不是音高台阶。要听音高台阶，请看下面的 A 类自由衰减。

## A 类自由衰减（音高直接由 a1 决定）

用同一组 cello C2 模态，给一个初始状态后自由衰减，没有驱动：

| 文件 | 听感 |
|---|---|
| `demo_decay_exact.wav` | 平滑的 20 c 颤音 |
| `demo_decay_linear.wav` | 和 exact 几乎一样 |
| `demo_decay_q20.wav` | 几个 10 c 级台阶，明显不连续 |
| `demo_decay_q24.wav` | 接近平滑 |
| `demo_decay_ab_q20_q24.wav` | q20 → 0.4 s 静音 → q24 |

### 更清楚的单模态 / 音高轨迹试听

`demo_decay_*` 是多模态混合，音高台阶有时会被高次模态和衰减盖住；
如果还听不明显，用下面两组：

| 文件 | 内容 |
|---|---|
| `demo_pure_exact.wav` / `demo_pure_q20.wav` / `demo_pure_q24.wav` | 单个 C2 模态自由衰减，4 s，4 Hz，20 c |
| `demo_pure_ab_q20_q24.wav` | q20 → 静音 → q24 |
| `demo_pitch_exact.wav` / `demo_pitch_q20.wav` / `demo_pitch_q24.wav` | 把实际音高轨迹搬到 220 Hz 载波上（不是 cello 音色） |
| `demo_pitch_ab_q20_q24.wav` | q20 → 静音 → q24，台阶最明显 |

`demo_pitch_*` 是“音高轨迹的 sonification”：它不经过模态合成器，
只把 `a1` 反解出来的 cents 轨迹乘到 220 Hz 上，所以量化台阶不会被音色掩盖。

### 为什么 q24 不是严格围绕 f0

`q24` 只加宽了**调制量/影子**，标称 `a1_nom` 仍然来自 Q2.20 ROM。
cello C2 的 Q2.20 标称值对应约 **-1.57 c** 的静态误差；
所以 q24 的轨迹是围绕这个“已量化的标称音高”上下摆，而不是围绕理想 f0。
整数 `term1` 的截断还会再加一点偏置。实测 C2、4 Hz、20 c 下：

| 版本 | 轨迹中心 | 范围 |
|---|---:|---:|
| exact | 0.00 c | -20.00 .. +20.00 c |
| q20 | -1.86 c | -24.44 .. +20.72 c |
| q24 | -1.45 c | -21.55 .. +18.65 c |

要让它严格围绕 f0，需要在 note-on 用更高精度重算/存储 `a1_nom`，
或者把标称 a1 也做到 Q2.24。

B 类里听不出这个中心偏移是正常的：B 的音高由驱动 NCO 决定（NCO 用精确的 `rho`），
a1 只负责模态共振；A 类/`demo_pure_*` 才是音高直接跟着 a1 走。
