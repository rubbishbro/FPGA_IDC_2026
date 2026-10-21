# 硬件实现说明与早期推进路线（历史归档）

> 本文保留早期工作约定、算法说明和阶段路线，不代表当前进度。当前统一阅读[工程汇报](../../../工程汇报.md)。

## 当前工程阅读入口

- [歌曲合成工程资源占用（v5）](../docs/reports/song_synthesis_resources_v5_20261009.md)：整机P&R占用与综合阶段模块分摊分开列示。
- [文档导航与历史归档](../../../README.md)：按内容名称查阅，不将旧阶段报告当作当前结果。
- [歌曲修复与100MHz时序记录](song_control_timing_review.md)：普通setup/hold为0违例，MPW模型仍待查；用户决定先做有限实板试验，尚未收到的实测不记为通过。

## 0. 工作约定（2026-10 更新：AI 实现、作者把关）

本目录下的 RTL 改为 **"AI 按冻结规格实现、项目作者审查与判定"** 的方式推进：

| 谁 | 做什么 |
|---|---|
| **AI** | 按 `rtl/DECISIONS.md` 的冻结规格**实现模块** + 写 **cocotb 逐位对拍**；一次只交付一个模块 |
| **作者** | 审查代码、跑验证、判定通过与否、决定是否进入下一模块、拍板未冻结项 |

规则：

* 规格以 `rtl/DECISIONS.md` 为准。遇到未冻结项（§G）先提出，不擅自假设。
* 每个模块必须附**可判定的验证判据**；优先与 `python/modal_sim/fixed_point.py`（验证链②）**逐位相等**。
* 模块接口与内部设计由实现方给出并说明，作者负责审查、指出问题、定位差异。

### 模块 2A 文档

* [`module2A_design.md`](../../../../rtl/module2A_design.md)：单声部四路时分复用阵列的设计规格、接口、周期表与测试判据，以及 2B/2C 的范围边界。
* [`module2A_delivery_report.md`](module2A_delivery_report.md)：实现模型、独立审查、实际测试结果和未完成的硬件验证；以报告中的状态判断是否已交付。

### 模块2B/2C与音频首阶段

* [`module2BC_design.md`](../../../../rtl/module2BC_design.md)：系数ROM装载及32声部调度设计/测试规格。
* [`audio_bringup_design.md`](../../../../rtl/audio_bringup_design.md)：上板自动歌曲与MAX98357A喇叭播放目标，特别注明PT8211与标准I2S的时序差异及硬件待确认项。
* [`module2BC_delivery_report.md`](module2BC_delivery_report.md)：实现与独立复测状态；数字链路结果与实物验收分开记录。
* [`audio_delivery_report.md`](audio_delivery_report.md)：音频实现者的文件、正式测试和限制；父会话复测结论仍以总交付报告为准。
* [`platform/tang_mega_138k_pro/BOARD_README.md`](platform/tang_mega_138k_pro/BOARD_README.md)：MAX98357A的PMOD2接线、真实PLL生成及板级构建/验收步骤。缺Gowin/IP时不能生成可烧录结果。

父会话音频独立补测入口：`sim/test_audio_chain_review.py`（原始系数黄金→真实引擎→外部I2S，含32声部/整曲循环）和`sim/test_audio_transport_review.py`（复位握手、帧边界清除及一核心拍跨时钟清除）。使用torch312环境，构建/XML默认写入`/tmp/opencode/audio-review/`，不替换`sim/results.xml`。

### 共享箱体首版（独立功能验证通过，硬件构建未验收）

* [`body_design.md`](../../../../rtl/body_design.md)：4-biquad残余箱体、外部64bit/Q30与内部68bit/Q34、局部数值方案及门槛；首版闭环guitar，四乐器单测，不把混奏分组/噪声/控制迁移算作已完成。
* [`body_review_report.md`](body_review_report.md)：父会话独立逐位、误差、拒绝路径、歌曲/I2S、生产wrapper及真实DSP/ROM网表结果；生产BODY=1参数已验证，隔离模块STA通过，但完整整机Gowin/实板尚未接受。
* `sim/test_body_filter_review.py`、`sim/test_body_numeric_review.py`、`sim/test_body_rejection_review.py`：黄金来自原始Patch.sos，覆盖64bit输出/68bit历史、饱和、busy/clear/reset、量化误差、ROM重建及非法输入拒绝。
* [`hardware_timing_review.md`](hardware_timing_review.md)：真实P&R已保留阵列/箱体，但完整工程100MHz时序未通过，父会话拒收并分配地址/控制优化。箱体流水v3现已亲跑逐位/冻结整机/隔离100MHz及真实DSP/ROM网表功能通过；最终核心版本/整机仍须重新验收。`sim/review_gowin_reports.py --require-body`检查STA/clock/箱体门槛，`sim/review_i2s_pin_delays.py`分清真实快慢角路径和约束保守上界，不因产出bitstream自动放行。


## 1. 硬件上到底要算什么

Python 参考在 `python/modal_sim/`（`engine.py` / `sustain_engine.py` / `drumkit.py`），
数学推导在 `python/MATH.md`。逐采样数据通路：

```
note_on ──▶ 系数表读取 ──▶ 激励脉冲 ──▶ N 条二阶谐振器 ──▶ 声部求和 ──▶ 共享箱体 ──▶ 饱和 ──▶ I2S
              (ROM)        (短表/计数器)   (IIR, 主体算力)      (V 路)      (4 biquad)   (24bit)
```

### 1.1 激励：有限长升余弦脉冲

`plen = tau * sr`（τ≈1.5e-4 s → 48 kHz 下约 7 个采样），形状
`x[i] = amp * (0.5 - 0.5*cos(2π i / plen))`，i = 0..plen-1，之后为 0。

要理解的点：这是**定长小表 + 计数器**，不是 DDS；`plen` 由力度选择（forte/piano 两档）。

### 1.2 模态谐振器（算力主体）

每个模态一条二阶 IIR，直接型：

```
y[n] = g*x[n] − a1*y[n−1] − a2*y[n−2]
a1 = −2 r cos θ,  a2 = r²,  r = exp(−γ dt),  θ = 2π f dt
```

`f`、`γ`（以及 `g`）来自 `FFT_results/params/*.npz`，按音高/力度查表。

要理解的点：
* 每模态每采样 **3 乘 2 加**；规模是 **V 声部 × N 模态**（N=48~64！），
  这是全设计唯一的算力瓶颈——先算清 `V×N×3` 乘/采样，再对照每采样可用周期数
  （50 MHz / 48 kHz = 1041）。
* `a1` 的取值范围（|a1| 可接近 2）决定定点格式，不能想当然。
* 极点半径 `r = 1 − γ·dt`，最慢的极点 γ 很小 → `r` 极接近 1 → **位宽决定衰减精度**。

### 1.3 箱体：可共享

4 个 biquad（8 阶），**每采样只算一次**，不是每声部一次。
要理解为什么可以共享（线性时不变系统：先求和再滤波 ≡ 先滤波再求和）——这是省资源的依据。

### 1.4 复音与"方案 C 催死"

声部池 + 高水位抢占：被抢占的声部不是清零，而是把 **γ 乘以 kill_factor**（极点半径变小），
让尾巴**连续加速**而不是硬切。改 `a1/a2` 时 `y1/y2` 里还有能量，于是下一采样会跳
`Δ = (a1_old − a1_new)·y1 + (a2_old − a2_new)·y2`——Python 里把这个跳变**测出来**当作"无咔哒"的证据。
要理解的点：这是本设计最有意思的取舍，也是 FPGA 上"状态不清零"的直接体现。

### 1.5 定点化（决定成败）

现有约定见 `reference_agent_readfirst/fpga_platform.md`（`PHASE_BITS` / `SAMPLE_BITS` / `TABLE_BITS`
是**示例值**，不是推导结果）。必须自己推导并验证：

* 系数小数位 F 取多少？依据是"最慢极点的衰减率误差"，而不是平均值；
* **最慢极点要单独扫描**：γ=0.25 时 `1−r ≈ 5.2e-6`，Q1.20 的半个 LSB ≈ 4.8e-7，
  单是 `r` 的舍入就能带来约 9% 的该极点衰减率误差——整批极点的统计结论掩盖不了这一个；
* 二阶直接型还要检查 `2r·cosθ` 能否被所选格式的整数范围表示；
* 累加器位宽、饱和/舍入策略、是否出现极限环。

## 2. 建议推进顺序（每步都要有可判定的验证）

| 阶段 | 做什么 | 验证判据 |
|---|---|---|
| 0 | **不看代码**，把算法从连续方程推到逐采样更新式，讲清每个预计算系数 | 能向别人讲明白；能手算 3 个采样 |
| 1 | 单模态二阶谐振器（含定点系数） | 与 Python 逐采样对齐（误差 < 1 LSB 或明确的容差）；冲激响应的 f/γ 误差 |
| 2 | N 模态 + 系数 ROM（先 1 声部） | 与 Python 的 1 声部输出逐样本对齐；综合报告看乘法器/LUT |
| 3 | 激励脉冲 + 力度两档 | 起振波形与 Python 一致；脉冲长度/幅度可配 |
| 4 | 复音 + 高水位抢占（方案 C） | 抢占时无硬切；`kill_jump` 有界；声部数改变行为一致 |
| 5 | 箱体 + 求和 + 饱和 | 与 Python 的箱体输出对齐；饱和不溢出、不振荡 |
| 6 | I2S + 板级（先逻辑派 G1，后 138K Pro） | BCLK/LRCLK/SD 时序；上板出声 |
| 7 | 优化（DSP 映射、时分复用、位宽回收） | 时序收敛；资源报告；听感不回退 |

## 3. 开工前需要定下来的参数

* 目标复音数 `NUM_VOICES`（验证平台先小，主力平台再扩）
* 每声部模态数 `N`（A 类 48~64，C 类 40~64）
* 采样率 48 kHz；验证板（逻辑派 G1）系统时钟 50 MHz → **每采样只有 1041 个周期**；
  主力平台可用 PLL 提到 100 MHz（2083 个周期）。这个数是全部架构选择的基准
* 系数/状态/累加器/音频的定点格式
* 是先做 A 类（拨/击）还是 C 类（打击乐）——建议 A 类，因为它是纯 IIR，噪声支路更复杂
