# ENG1 Python 模型：当前 RTL 同步版

更新：2026-10-30。本页前半部分为当前生产合同；后半部分保留迁移前 Q30 文档，供历史实验追溯。

## 当前入口

- `python/modal_sim/eng1_rtl.py::Eng1Synth`：四种 B 类音色的生产模型。
- `router_eng1.RouterEng1(...)`：现在构造同一个 `Eng1Synth`。
- `eng1_bc.BSynth`：现在使用生产模型，默认加载 MIDI64..79 的16槽音组；可显式传入 `note_map` 和 `ResourceBank`。
- `LegacyRouterEng1`、`LegacyBSynth`、旧 `ScoreRenderer` 和 `CSynth` 保留 Q30 历史实验。当前 RTL 没有 C 类 seed/timer/choke 前端，不能用 C 试听冒充板端声音。

```python
from eng1_rtl import Eng1Synth, ResourceBank

# 可从实际生成的 bin + manifest 解码，校验每个音符资源hash。
bank = ResourceBank.from_directory("build/eng1_py_sync/final", "flute")
synth = Eng1Synth("flute", resources=bank, note_map=range(48, 64))
slot = synth.note_on(60, velocity=100, source=0)
frame = synth.step()                 # 当前输入音频帧的合成结果
pcm_left, pcm_right = frame.pcm      # 实际定标的PCM16，未做峰值归一化
synth.control("bend", 16383, source=0)
synth.control("cc1", 127, source=1)
synth.note_off(slot)                # 普通释放，保留模态尾音至清零退休
```

`note_on`的velocity是MIDI整数1..127。`BSynth.note_on`兼容浮点力度(0,1]，转换到MIDI力度后仍走同一条路径。
固定槽位音高不在已加载音组中时明确拒绝；另一来源占用/释放未退休时拒绝，不自动抢槽或偷偷载入另一个音高。
生产B资源使用forte表，力度来自velocity/压力；`BSynth`不再将任意dynamic表当成已加载的生产资源。

## 已同步的数值与生命周期

| 范围 | 当前模型合同 |
|---|---|
| 状态与激励 | signed32 Q24；冲激为8bit level左移16位；MIDI 7->8bit映射与RTL一致 |
| 核心 | G/a1低26bit有符号、a2低24bit无符号；64条存储，只计算/写回前48模态；正偏置舍入及signed32饱和 |
| 持续激励 | 逐槽period、40bit Q24相位、41bit加法进位；零调制旧周期一致；变调保持相位，重触发归零 |
| 包络 | 同源逐槽A/R；起音当帧E=0；D=1048576，S=0x1fffffff；力度不再乘第二次 |
| 清理 | dead来自包络状态，不能用E=0猜测；dead边沿经过router寄存后在下一音频帧清模态；硬清除当帧清并可在下一帧再次响应dead边沿 |
| idle | 帧内状态写回退休后发布；release到零不提前允许另一归属抢槽 |
| 动态音高 | 双来源Bend/CC1、slew、ROM插值、不可变base/K、一阶a1更新、完整影子批次和原子提交；支持取消、清理、坏P1T1拒绝 |
| 腔体 | 四种B音色在当前body_router均为直通，未擅自加额外音色滤波 |
| 混响 | NONE/HALL/BATHROOM均按当前SV表达式宽度复刻，包括F09截断和清空末端边界；没有替RTL修正声音 |
| 双声道/PCM | ILD插值、位置slew、分数ITD、清空、Q24到PCM16的headroom/舍入/限幅；默认headroom=3，未归一化 |

`Frame`返回 `x/emap/y/mix/out/pcm/delta/zero/idle`，便于追查差异。`out`是混响后的Q24整数，`pcm`是输出定标后的左右声道。
`step(active=False)`只屏蔽输出PCM并清空间定位历史；不会把仍在持音的声部假报为空闲。停止DSP采样推进时不要调用`step()`。
PAD可调用`step_pad(pressure, on_threshold=64, off_threshold=48)`使用板端门限；默认参数2/1对应voice_router的模块默认门限。

## 模型时序边界

模型入口位于**已经接受的演奏帧**，不重写原始MIDI解析、队列、选源维护、Flash/QSPI或FIFO/串行发送器。
`step()`返回该帧结果，不包含I2S/PCM FIFO的固定播放延迟；配置/音组切换用新的资源模型或`reset(initialized=False)`表示装载后必需的初始化清零帧。
默认构造/`reset()`表示初始清零已退休、后端可准入音符。换输入来源/配置的完整握手仍由RTL外层负责。

`PitchEngine.clock()`单独逐core时钟建模真实eng1_pitch FSM（包括参数RAM同步读），可以显式驱动sample_tick、commit_ok、control、cancel、cleanup和slot_source。
高层`control()`队列使用该FSM，按core_hz/sample_rate推进；默认50MHz、16槽帧忙窗598拍，忙窗内禁止提交、帧间原子提交。
`frame_busy_cycles`是显式调度参数，不是新建的完整voice_router逐拍模拟；原始MIDI到声音的绝对延迟不由这个简化调度证明。

逐帧回放接口`step(gate=..., level=..., retrigger=..., clear=..., sources=..., committed_delta=...)`接受实际RTL采集的输入/原子比例快照。
模型独立计算激励、包络、a1、递推、混音及后级；不会直接使用RTL的x/包络/输出作结果。实际波形对拍比较的也包括自动推导的zero和退休idle。
本接口用来消除外层MIDI/调度到达时刻差异；不会把“同一原始字节时刻”说成完整整机逐拍对拍。

采样率严格匹配48k资源。不能静默把48k模型当成板端48.828125k播放；后者的音高/时间偏差仍见完整性检查报告。

## 可复跑验证

```bash
/home/rubbishbro/micromamba/envs/torch312/bin/python -m pytest -q \
  sim/unit/eng1/test_eng1_rtl.py sim/unit/eng1/test_router_eng1.py
/home/rubbishbro/micromamba/envs/torch312/bin/python sim/run_eng1_model.py \
  --out build/eng1_py_sync/final
# 只做接口/渲染冒烟，不生成音频文件
/home/rubbishbro/micromamba/envs/torch312/bin/python python/modal_sim/eng1_bc_demo.py \
  --no-write --seconds 0.02
```

RTL验收入口会独立生成匹配P1T1资源，运行生产RTL后保存可检查的trace。四种B音色各16槽、2048采样持音，并覆盖双来源相反方向弯音、CC1、清理后重起、换组失败/恢复。
另逐core时钟对拍调制状态/影子写入/提交；三种混响各4200样本、headroom=0/3/53，包含完整signed64输入和清空边界，比较混响、84bit空间输出及PCM。
本次结果和源码hash保存在`build/eng1_py_sync/final/`；本阶段不生成正式试听WAV，也不修改Flash部署。

本次实测：65项pytest通过；四音色各2290帧、共9160帧全部对拍通过；40000个core时钟、3934次系数写入、4次原子提交、3次控制确认（含1次格式拒绝）通过；后级37800采样通过。实际清零与退休idle也逐帧比较。汇总：`verification.json`，逐项：`results.json`，Python日志：`pytest.log`。

---

## 历史 Q30 参考说明（迁移前原文）

以下保留旧API名和旧验证边界，均按旧Q30实验解释；其中“RouterEng1仍为静态”“激励尚未跟进”等描述不再适用于上面的生产入口。


更新：2026-10-30。对象是当前 `rtl/router/engines/eng1.sv` 及其在 `voice_router`
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
| `a1` | signed 26, Q2.24；直接参与乘法，无 `<<4` |
| `a2` | unsigned 24, UQ0.24 |
| `y1` / `y2` | signed32；独立Python模型Q30，生产整链Q24，与所用资源定标一起确定 |
| `ynew` | `clamp((acc + 2^23) >>> 24)`，signed 32 |
| `y` | signed 64，一个 slot 的 modal 和 |
| `emap` | signed 32, Q1.31 |
| 腔体系数 | signed 32, Q4.27；内部 68 位状态 / 104 位累加 |
| 混响增益 | signed 32, Q4.27；4 条 64 位延迟线 |

### 2026-10-30 Q2.24 迁移

当前递推为 `acc=G*x-a1*y1-a2*y2`，三项统一按24位系数小数位计算；舍入、
饱和、状态位宽和流水节拍保持原合同。`co_data.a12[25:0]` 为有符号a1，
不再使用原来的22位截取和左移4位。递推仍为原有三项乘法，未加入二阶调制项。
Gowin单模块对比中Q2.20/Q2.24均为3个MULT27X36、450逻辑、275寄存器，
没有增加核心资源；本轮未重跑整板综合/PnR，不据此签核板级时序。

B类 `build_b_table` 从浮点极点直接量化到Q2.24，并按新的量化极点重算G。
生产 `sustain_resources.py` 与诊断 `gen_sustain_q24.py` 共用该构建器；
Flash每模态仍为64字节，word0/1/2为G/a1/a2，word1格式改为Q2.24。
生产manifest显式记录格式与系数hash。旧Q2.20 B镜像必须重新生成，当前loader
不会运行时识别旧镜像的小数位，不能混用；板端默认资源准入范围不因迁移扩大。

独立参考中的历史A类72-bit表仍按原布局解包，`load_a_table` 在接口边界
显式将a1左移4位转成Q2.24，保留其原有精度；独立旧 `fixed_point` / `abc_lane_core`
路径不在本轮迁移范围。C类参考表和seed反推使用新的Q2.24系数。
独立模型的Q30状态定标与生产Q24状态定标仍按上表区分。

运行时颤音与弯音共用一阶式 `a1(t)=a1_base+K*lambda(t)`，
`K=2*r*theta*sin(theta)`，`lambda=2^(cents/1200)-1`；K离线计算，a2保持不变。
该静态迁移现已继续接入运行时一阶调制及连续相位激励，见[一阶音高调制](ENG1一阶音高调制.md)。
`RouterEng1`整链试听模型仍保持静态系数；动态整数参考由`pitch_linear.py`及`sim/run_pitch.py`维护。
验证与综合对比见[Q2.24迁移验收](工程评审与验证.md#eng1-q24-2026-10-30)。

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
- 长笛用 `SHIFT=22, PW=1, GAP=T-1, N_PULSE=7` 的周期冲激参数；生产exc_router现已为四种持续音色使用逐槽period的B模式，Q24/SHIFT16；不能将Q30参考整数直接比较为生产PCM。旧PAD/BASS枚举已不存在。

## 2026-10-29 接入复核补充

前述零模态/吞吐是旧阶段记录：当前工作区eng1已改为五级跨模态流水，空作业和满深度由sim/run_audio.py的新整数oracle验证。本文独立Python模型仍使用Q30；当前router激励/PCM按Q24解释，不能直接复制SHIFT22。

B类周期驱动、ADSR及逐槽period现已接入RTL；实施合同和修复前实测统一见[eng1演奏前端](ENG1演奏前端设计.md)。BSynth提供参考，当前RTL验证结果另见[工程验证](工程评审与验证.md#sustain-implementation-2026-10-29)。
