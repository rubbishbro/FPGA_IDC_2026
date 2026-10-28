# ENG1 Python 模型（router 级整数）

更新：2026-10-29。对象是当前 `rtl/router/engines/eng1.sv` 及其在 `voice_router`
里的激励、包络、腔体、混响链路；不是旧的 `fixed_point.py` 复音池，也不是浮点
`sustain_engine.py`。

## 文件

| 文件 | 作用 |
|---|---|
| [`python/modal_sim/router_eng1.py`](../python/modal_sim/router_eng1.py) | `Eng1Core`、激励状态机、ADSR/dyn/const 包络、腔体、混响、整链与音符分配 |
| [`python/modal_sim/eng1_demo.py`](../python/modal_sim/eng1_demo.py) | 原有 A 类 guitar / B 类 flute 链演示 |
| [`python/modal_sim/eng1_bc.py`](../python/modal_sim/eng1_bc.py) | B/C 共用 `Eng1Core`：B 周期冲激 + ADSR，C seed + timer + choke |
| [`python/modal_sim/eng1_pieces.py`](../python/modal_sim/eng1_pieces.py) | 新写的 D 小调吉他练习曲与 C 减和弦钢琴前奏 |
| [`python/modal_sim/eng1_cosim.py`](../python/modal_sim/eng1_cosim.py) | 生成作业向量，用 iverilog 与 `eng1.sv` 逐位对拍 |
| [`sim/unit/eng1/test_router_eng1.py`](../sim/unit/eng1/test_router_eng1.py) | pytest 回归 |

## 位宽契约

| 信号 | 格式 |
|---|---|
| `x` | Python参考signed32 Q2.30；当前router输入按Q24解释，整数核不额外转换二进制点 |
| `G` | signed 26, Q2.24 |
| `a1` | signed 22, Q2.20；乘法前 `<<4` |
| `a2` | unsigned 24, UQ0.24 |
| `y1` / `y2` | signed32；独立Python模型Q30，生产整链Q24，与所用资源定标一起确定 |
| `ynew` | `clamp((acc + 2^23) >>> 24)`，signed 32 |
| `y` | signed 64，一个 slot 的 modal 和 |
| `emap` | signed 32, Q1.31 |
| 腔体系数 | signed 32, Q4.27；内部 68 位状态 / 104 位累加 |
| 混响增益 | signed 32, Q4.27；4 条 64 位延迟线 |

## 模型模式与当前 RTL

- `rtl_compat=False`（默认）：使用当前模态状态、全模态 st_zero、attack 钳位和全宽混响乘积的意图模型。
- `rtl_compat=True`：复刻 2026-10-25 旧 F05 的跨模态状态/数量截断，仅用于历史追溯。当前 RTL 的反馈和 st_zero 已改，不能再称这个模式与当前实现一致。
- eng1_cosim.py默认仍为历史rtl模式，旧TB还依赖串行核内部状态；27/28日intended的63通过/3个零模态失败属于修复前。当前五级流水的算术/空作业以sim/run_audio.py --test eng1为准，29日256组通过；系统音频另有顶层接线阻塞，见[问题台账](bugs.md)。

当前钢琴/吉他由 eng_sel 选择 eng0；本文是 eng1 参考链，不代表这两个实际路由已改用 eng1。当前激励也已升级为斜坡/指数尾部/递减锤击，试听模型未逐项跟进，所以整链不能称与最新 RTL 逐样本完全一致。

## B/C 也走同一个 Eng1Core

`python/modal_sim/eng1_bc.py` 不再使用独立的 DSP 引擎：

| 类别 | 激励 | 生命周期 | 系数/状态 |
|---|---|---|---|
| A | 一个有限脉冲 | ADSR/dyn | A 表 `G/a1/a2` |
| B | 周期冲激 `PW=1, GAP=T-1, N=7` | ADSR（attack/release 来自提取） | B 表 `G/a1/a2` |
| C | `x=0` | seed 起振 + timer 到期/choke 后 fade | C 表 `G=0, a1/a2` + seed `{y2,y1}` |

- `BSynth` 每个 slot 自己记 drive 周期/相位和 ADSR；16 个 slot 共享一个
  `Eng1Core`。
- `CSynth` 把 `drums.npz` 的 `(f, gamma, a)` 量化成 `a1/a2`，并用
  `{y2,y1} = a/r * sin(phi-theta), a/r² * sin(phi-2theta)` 反推 seed；力度按旧
  RTL `scale_seed` 的 UQ1.15 规则缩放。相位用按 key 固定的伪随机序列（同一
  key 每次可复现），避免所有 modal 同相叠成一个宽带尖峰。
- C 的 timer 到期或同组 choke 后进入 fade；`hat` 和 `cymbal` 分别成组。
- RTL C 核没有 noise 分支；`CSynth` 因此是 seed-only。旧 `drumkit` 的 noise 仍是
  legacy 扩展，不在新 C 路径里。
- 旧 RTL 的 `c_engine_top` 是 seed/timer 语义；当前 `rtl/router` 还没有把 C 的
  seed 口接进 `voice_router`，所以这是“按 RTL 设计意图”的模型，不是当前 router
  已上板的 C 路径。
- 旧 `sustain_engine.SustainSynth` / `drumkit` 保留为 legacy 试听/参数提取；
  新 B/C 合成入口是 `eng1_bc.BSynth` / `CSynth`。

```bash
python python/modal_sim/eng1_bc_demo.py
```

输出：

```text
FFT_results/sim/eng1/
  eng1_b_phrase.wav
  eng1_c_groove.wav
```

## 新片段

`python/modal_sim/eng1_pieces.py` 用重构后的引擎写了两段新曲：

- **guitar — Estudio in D minor**：Dm | Bb | Gm | A | Dm | A，84 BPM，4/4；
  模型 guitar 配置（吉他 5 段、dyn0、旧 2 采样激励；当前 RTL 已有斜坡/尾部）。
- **piano — Prelude in C diminished**：Cdim | F#dim | Cdim | Bm7(no3) | Cdim |
  Cdim，60 BPM，4/4；模型 piano 配置（腔体直通、ADSR、旧 1 采样激励；当前 RTL 钢琴为 32 采样上升/448 间隔/4 次锤击）。提取的钢琴表只有 C / Eb / F# / A / B 这些音高类，
  曲子按这组音写，不假装缺失的音存在。

```bash
python python/modal_sim/eng1_pieces.py
```

输出：

```text
FFT_results/sim/eng1/
  eng1_guitar_estudio.wav
  eng1_piano_prelude.wav
```

脚本只写 WAV；peak/RMS、body 饱和计数打印到 stdout，不落 JSON/图片。

## 验证入口与模型检查

模型pytest与RTL对拍的命令/日期化结果统一见 [工程评审与验证](工程评审与验证.md#verification) 和 [运行器说明](../sim/unit/eng1/README.md)。intended与兼容模式的选择按本页契约；旧零模态修复及测试入口状态见 [问题台账](bugs.md)，不在模型说明再维护一份全局测试汇总。

模型特有的既有B表检查覆盖flute/trumpet/cello/violin/oboe共198个音符，G无饱和、量化后极点r<1；它只说明这批参数的定常检查，不证明时变调制稳定或已接板端。

## 边界

- 不模拟拍数/实时预算（旧 tb_throughput 已移除，需新的周期证据；本模型不证明 F07）。
- 不模拟 loader 地址；模型允许每 slot 独立系数表，当前 loader 已按 slot 独立读取表，但本模型不验证地址/真片协议。
- 不模拟 `mod_router` 的 a1/a2 更新，所以揉弦不在这个模型里。
- `fmap_q`/`note_on`/`emap` 的一拍寄存、腔体 93 拍和混响 6 拍流水没有逐拍模拟；
  整链 RTL 对拍要先按 valid 对齐。
- A 类表的 `G` 是按升余弦脉冲生成的，模型 guitar 激励仍是旧 2 采样形状，当前 RTL 已升级；两者电平和
  音色不会与 `engine.py` 逐样本一致，这是表/激励口径差异。
- 长笛用 `SHIFT=22, PW=1, GAP=T-1, N_PULSE=7` 的周期冲激参数；当前 exc_router 除钢琴/吉他外使用默认参数；旧 PAD/BASS 枚举已不存在，也没有自动得到这里的 B 类周期驱动。

## 2026-10-29 接入复核补充

前述零模态/吞吐是旧阶段记录：当前工作区eng1已改为五级跨模态流水，空作业和满深度由sim/run_audio.py的新整数oracle验证。本文独立Python模型仍使用Q30；当前router激励/PCM按Q24解释，不能直接复制SHIFT22。

B类周期驱动及ADSR仍未在RTL按乐器选择，逐槽period也未接入；本轮生产模块实测与建议见[eng1激励与包络接入复核](ENG1演奏前端设计.md#current-behavior)。BSynth是参考，不表示当前RTL已实现真实持续音色。
