> 历史快照：保留当时结论，不作为当前实现状态。当前入口见仓库 README 和 docs/README。

# 代码衔接架构与阅读路线

> **2026-10-20 注**：ENG1 已从 `coeff_loader` 迁到 `class_loader` / `class_loader64` /
> `class_loader_mux`，B/C 先走 `synth_top` 测试路径；本文 §2/§3 的实例树是 2026-10-06 的
> A-only 旧快照（仍写 `coeff_loader`）。**ENG1 的当前结构、模块清单和收敛计划以
> [`docs/ENG1_ENG2_统一架构.md`](ENG1_ENG2_统一架构_2026-10-21.md) 为准**；本文其余部分作为板级/音频链路导读仍然有效。

本文是开发者的代码导读，不维护资源或验收状态；当前进度统一见[工程汇报](../工程汇报.md)。

核对日期：2026-10-06。面向项目作者阅读现有代码；按工作区实际模块实例、参数和文件依赖整理，不把规划当成已实现功能。

**本次只新增这份说明，不修改RTL、参数、ROM、PLL、约束或下载文件。**

## 0. 先分清：哪些代码在哪里运行

| 类别 | 位置 | 运行在哪里 | 是否成为FPGA逻辑 |
|---|---|---|---|
| 录音样本 | `music_resources/` | 电脑读取 | 否，板子不播放这些录音 |
| 参数提取 | `python/fft_analysis/` | 电脑 | 否，FFT不在当前FPGA里运行 |
| 浮点/定点参考、ROM生成 | `python/modal_sim/` | 电脑 | 否；生成的ROM数据用于构建 |
| 提取结果、电脑合成音频/图表 | `FFT_results/` | 电脑 | 只有经过生成流程的系数数据进入硬件 |
| 可综合硬件模块 | `rtl/core/`、`rtl/audio/`、平台目录 | FPGA | 是，以所选构建入口和参数为准 |
| 系数ROM初始化文件 | `rtl/rom/` | 综合工具读取，仿真器也读取 | 构建后成为片内ROM初值 |
| 功能仿真与验收 | `sim/` | 电脑上的Python/仿真器 | 否，不能加入生产综合源列表 |
| 构建脚本、管脚/时序约束 | 平台目录里的Tcl/CST/SDC | 电脑上的Gowin工具 | 控制硬件构建，不是音频算法 |
| 构建产物 | `build/`、平台`reports/`、独立验收临时目录 | 电脑/下载工具 | `.fs`是配置数据，不是阅读算法的入口 |
| 旧的独立合成实验库 | `sythsound/` | 电脑 | 不接入当前FPGA歌曲链路 |

整个项目有两条硬件运行链路：**歌曲工程**和**独立持续测试音工程**。一次下载选择其中一个，并不是两个顶层同时运行。

## 1. 全项目鸟瞰：离线准备 → 硬件运行 → 独立验证

```text
【电脑：离线准备】
music_resources/录音
    ↓ python/fft_analysis/run.py → core.py（plots.py画诊断图）
FFT_results/params/<乐器>_partials.npz、<乐器>_body.npz等
    ↓ python/modal_sim/params.py：Patch、模态参数、箱体SOS
    ├→ engine.py：浮点合成参考、生成/检查音色
    ├→ gen_coeff_table.py：量化a1/a2/G，打包每乐器72bit系数表
    │      ↓ FFT_results/params/*_coeff.mem + *_coeffindex.json
    │   gen_hw_rom.py：严格合并、生成稠密索引
    │      ↓ rtl/rom/modal_coeff.mem + modal_index.mem
    └→ gen_body_rom.py：量化4节箱体SOS
           ↓ rtl/rom/body_coeff.mem

【FPGA：歌曲工程】
song_player → modal_engine → 共享body_filter → 16bit PCM适配
                 ↑ ROM                          ↓
                                        异步TX FIFO → I2S → MAX98357A

【FPGA：独立测试音工程】
tone_source：±1024 → 同一个i2s_amp_tx → MAX98357A
（不经过歌曲、模态、箱体、FIFO）

【电脑：验证】
浮点参考 ↔ 定点参考 ↔ RTL仿真/实际输出引脚解码
真实Gowin构建 → 实际报告检查 → 最后仍需实板测量/出声验收
```

箭头含义要区分：Python链路多为**文件生成/读取**；RTL链路是**同时存在的硬件模块之间的信号连接**，不是软件函数依次调用。

## 2. 歌曲工程的实际实例层级

以下前缀简写为 `P = rtl/platform/tang_mega_138k_pro/`，`A = rtl/audio/`，`C = rtl/core/`。

```text
P/board_top.sv  [module board_top，仓库Gowin构建顶层]
└─ P/top.sv  [u_top]
   ├─ P/clock_reset.sv  [u_clock_reset]
   │  ├─ Gowin_PLL_core_100M  → 100MHz clk_core
   │  └─ Gowin_PLL_audio_12M5 → 12.5MHz clk_audio
   └─ P/board_audio_core.sv  [u_audio，薄封装]
      └─ A/audio_demo_core.sv  [u_core，音频整合]
         ├─ A/song_player.sv  [u_song，事件/激励/采样调度]
         ├─ C/modal_engine.sv [u_engine]
         │  ├─ C/coeff_loader.sv    [u_loader，ROM装载]
         │  └─ C/modal_poly_bank.sv [u_bank，多声部调度/混音]
         │     └─ C/poly_modal_lane.sv ×4 [g_lane[0..3].u_lane]
         ├─ C/body_filter.sv [g_body.u_body，ENABLE_BODY非0时]
         ├─ 本模块内sum_to_i16()、单样本TX暂存
         └─ A/audio_transport.sv [u_transport]
            ├─ A/audio_async_fifo.sv [u_tx_fifo，32bit立体声对]
            ├─ OUT_FORMAT=1：A/i2s_amp_tx.sv [g_i2s_amp.u_tx]
            ├─ OUT_FORMAT=0：A/pt8211_tx.sv [g_pt8211.u_tx，替代分支]
            ├─ A/i2s_mic_rx.sv [u_mic，歌曲模式禁用]
            └─ A/audio_async_fifo.sv [u_rx_fifo，歌曲模式不使用]
```

**参数以调用处为准，不只看模块定义中的默认值：**

- `board_top.sv`明确设置`ENABLE_BODY=1`、`BODY_INSTRUMENT=0`，启用guitar箱体；同时指定三份ROM的绝对路径。它不只是ROM路径封装，文件旧注释对此不完整。
- `top.sv`采用32声部、每声部最多48模态；其自身`ENABLE_BODY`默认0，但被`board_top`覆盖成1。
- `board_audio_core.sv`明确设置`MODE_SONG=1`、`OUT_FORMAT=1`，选择自动歌曲和MAX98357A标准I2S。
- `audio_demo_core.sv`和`song_player.sv`的独立默认声部数是8；板级调用覆盖为32。
- `modal_lane.sv`、`modal_bank.sv`、`resonator.sv`是较早的独立模块，**不在上述生产歌曲实例树中**。

## 3. 歌曲链路：数据流、控制流和节拍流

### 3.1 音符装载：决定这一路“是什么声音”

```text
song_player.event_at()：42个《小星星》事件，guitar forte
    ↓ load_voice / load_instrument / load_midi / load_dyn / load_vel
modal_engine：装载与计算仲裁、保存voice_loaded/voice_nm
    ↓
coeff_loader：查modal_index.mem → 检查条目元数据
    ↓ 合法后clear目标声部历史，再cfg逐模态系数
modal_poly_bank：mode%4分发到四个lane
    ↓
poly_modal_lane.mem：保存目标声部各模态的系数
    ↓ 最终装载完成
load_done返回song_player
```

装载用的是音符编号，而不是USB-MIDI协议包；**目前没有USB/MIDI输入解析器**。

缺失音符/力度档或非法条目必须报错，不自动找邻近音、不换档。条目元数据检查成功之前，不clear、不cfg，避免失败装载破坏原声部。

### 3.2 逐样本计算：决定这一刻“输出多少”

```text
song_player.pulse_val()：每次新音符的7样本升余弦激励
    ↓ active_mask：哪些声部计算；x_vec：各声部本次激励
modal_engine：检查请求、送入bank
    ↓
modal_poly_bank：逐个活动声部调度，四个lane并行计算其模态
    ↓ 每个模态：y[n] = G*x[n] - a1*y[n-1] - a2*y[n-2]
    ↓ lane部分和 → 声部和 → 全部活动声部mix_sum
song_player：收取engine结果，输出out_valid/out_sum
    ↓ audio_demo_core的一深度箱体输入暂存
body_filter：四节biquad串联（启用时）
    ↓ signed64、30位小数
sum_to_i16()：衰减、舍入、饱和为signed16
    ↓ {sample16, sample16}，左右相同
TX暂存 → audio_transport.u_tx_fifo
    ↓ 从100MHz域跨到12.5MHz域
i2s_amp_tx：每声道32bit时隙，高16bit有效，低位补零
    ↓ BCLK / LRC / DIN
MAX98357A → 桥接功放输出 → 喇叭
```

注意：当激励`x=0`，有历史的谐振器仍要计算，才能形成自然衰减尾音。`SKIP_ZERO_INPUT`只绕过零激励乘积，不代表停止整个声部的反馈更新。

### 3.3 采样节拍反向回来：为什么每帧只算一个样本

```text
i2s_amp_tx.frame_tick（音频时钟域）
    ↓ audio_transport：事件转toggle，跨域同步，检测变化
core_sample_pulse（核心域的一拍脉冲）
    ↓ song_player.sample_tick
调度下一次sample_valid
```

不要把`core_sample_tick`和`core_sample_pulse`混淆：前者是同步后的翻转电平，后者才是每音频帧一个的核心域脉冲。

### 3.4 启用功放不是证明出声

`audio_demo_core.playback_ready`在首个真实PCM被TX FIFO接收后置1。

歌曲顶层：`amp_sd = locked & playback_ready & ~reset`。

这只证明软件设计中的生产链路开始供给样本，不证明模块收到正确电平、成功解码或驱动喇叭。当前歌曲版U4复位的物理来源/有效极性仍待实板核实，不能照旧注释猜S1按键。

## 4. 核心如何共享计算和存储

### 4.1 voice和mode不是一回事

- **声部voice**：一个独立发声槽，例如按下一次琴键产生的一路声音。
- **模态mode**：这个声音内的一个衰减谐振器。
- 每个声部最多48模态，32声部最多1536个模态状态。
- 四个lane共享处理所有声部，不是给每个声部实例化48个`resonator`。

全局模态`k`的分配：

```text
lane = k % 4
lane内local = k / 4

lane0：mode 0,4,8,…
lane1：mode 1,5,9,…
lane2：mode 2,6,10,…
lane3：mode 3,7,11,…
```

### 4.2 两类存储，职责不同

```text
只读ROM：modal_coeff.mem / modal_index.mem
    保存全部支持音符的参数库
          ↓ coeff_loader装载
各lane工作缓存mem
    保存当前各声部的系数＋递归历史y1/y2
```

`poly_modal_lane.sv`的工作缓存按地址交替存放：

```text
base = voice * LOCAL_MODES + local
mem[2*base]     = 72bit系数
mem[2*base + 1] = {8'b0, y2[31:0], y1[31:0]}
```

RAM本体不整体复位；`state_valid`决定历史是否有效，清某声部时清它的有效位，读取无效历史时视为零。生产lane的同步单端口RAM写周期不更新读输出，即no-change模板。

每个lane只有一个逻辑乘法点，分相计算`G*x`、`a1*y1`、`a2*y2`；启动间隔II=3。需要结合`ph`、`mi`、`prod_r`、`pend_valid`阅读，前一个模态的完成/写回会与后一个模态的读取重叠，不是三个相位结束马上在同一拍得到全部结果。

**这里的TDM是内部运算资源的时分复用，不是外部I2S采用多声道TDM音频格式。**

### 4.3 数值位宽对照

| 位置 | 格式 |
|---|---|
| 模态激励x、历史y1/y2 | signed32，30位小数（Q2.30） |
| a1 | signed22，20位小数；乘法前左移4位统一尺度 |
| a2 | unsigned24，24位小数 |
| G | signed26，24位小数 |
| 系数ROM字 | 72bit：`[71:46]=G`、`[45:22]=a2`、`[21:0]=a1` |
| 模态乘积/累加 | signed58乘积，signed64累加；模态结果舍入/饱和回32bit |
| 声部和、混音和 | signed64，30位小数 |
| 箱体系数 | signed32，30位小数 |
| 箱体内部状态 | signed68，34位小数；100bit乘积，104bit累加 |
| 箱体外部输出 | signed64，30位小数 |
| PCM适配后 | signed16，左右复制 |
| TX FIFO的一项 | 32bit并行打包`{left16,right16}`，不是单声道32bit样本 |
| 外部I2S | 左右各32bit时隙，16bit有效数据放高位 |

当前`i2s_amp_tx`实际取`in_data[15:0]`存入`mono`，再复制到左右时隙；它不是接收不同左右样本的通用立体声发送器。当前上游本来就两半相同，因此链路一致。

## 5. 独立持续测试音：最适合先阅读

```text
P/diagnostic_tone/top.sv [module diagnostic_tone_top，独立构建顶层]
├─ Gowin_PLL_audio_12M5 → 12.5MHz
├─ 顶层内3FF复位同步器：rst_sync[2]
├─ P/diagnostic_tone/tone_source.sv [u_tone]
└─ A/i2s_amp_tx.sv [u_i2s，复用生产发送器]
```

```text
tone_source.pcm={sample,sample} → i2s_amp_tx.in_data
i2s_amp_tx.in_ready            → tone_source.ready
```

发送器在帧边界消费一个样本，`ready`才让音源相位前进一步。

- 24帧`+1024`、24帧`-1024`，48帧循环；左右相同。
- BCLK=3.125MHz，LRC=48,828.125Hz，音调≈1017.253Hz。
- 32bit解码字为`0x04000000`或`0xFC000000`。
- `amp_sd = audio_locked & rst_n & tone_started`。
- 不实例化100MHz PLL、ROM、引擎、箱体、FIFO、麦克风，也没有U4/按键复位端口。
- 下载文件：`build/diagnostic_tone_20261005/diagnostic_tone.fs`；它不是歌曲版。

## 6. 各RTL文件的职责与第一眼该看什么

| 文件 | 职责/关系 | 阅读关注点 |
|---|---|---|
| `rtl/core/resonator.sv` | 单个二阶谐振器，早期独立验证/理解公式 | y1/y2、三项乘法、舍入、饱和 |
| `rtl/core/modal_lane.sv` | 2A单声部的一条共享lane | ph、RAM同步读、乘法复用；不是生产poly lane |
| `rtl/core/modal_bank.sv` | 2A单声部四lane数组 | mode分发、握手、四部分和 |
| `rtl/core/poly_modal_lane.sv` | 生产多声部lane | voice地址、state_valid、流水与no-change RAM |
| `rtl/core/modal_poly_bank.sv` | 生产四lane、多声部调度 | 帧预检查、VSELECT/VSTART、逐声部混音 |
| `rtl/core/coeff_loader.sv` | 同步ROM查表/装载 | S_IDX→S_CHK→S_CLEAR→S_CRD/S_CFG→S_DONE |
| `rtl/core/modal_engine.sv` | loader和poly bank整合 | 装载优先、voice_loaded、load_done与sample仲裁 |
| `rtl/core/body_filter.sv` | 共享4-biquad箱体 | ROM预加载、每节5个乘积、历史与局部舍入 |
| `rtl/audio/song_player.sv` | 内置曲谱/激励/采样调度 | event_at、pulse_val、pending、load/sample FSM |
| `rtl/audio/audio_demo_core.sv` | 音源、引擎、箱体、传输整合 | u_song/u_engine、g_body、sum_to_i16、两处暂存 |
| `rtl/audio/audio_async_fifo.sv` | 两时钟域传PCM | 二进制/Gray指针、跨域同步、满/空判断 |
| `rtl/audio/audio_transport.sv` | 音频串行与核心域连接 | TX FIFO、输出格式generate、帧toggle跨域 |
| `rtl/audio/i2s_amp_tx.sv` | MAX98357A标准I2S发送 | t分频、bcnt、nxt、payload、mono |
| `rtl/audio/pt8211_tx.sv` | PT8211的Japanese/LSBJ替代发送器 | 不能当标准I2S使用；当前板级工程不选此分支 |
| `rtl/audio/i2s_mic_rx.sv` | 数字麦克风接收分支 | 24bit采样、声道选择；当前歌曲工程禁用 |
| `rtl/platform/tang_mega_138k_pro/board_top.sv` | 生产构建封装 | BODY=1和ROM绝对路径覆盖 |
| `rtl/platform/tang_mega_138k_pro/top.sv` | 板级连线/功放使能 | u_clock_reset、u_audio、amp_sd |
| `rtl/platform/tang_mega_138k_pro/board_audio_core.sv` | 固定歌曲/I2S模式的薄封装 | MODE_SONG=1、OUT_FORMAT=1 |
| `rtl/platform/tang_mega_138k_pro/clock_reset.sv` | 双PLL/复位 | 两个时钟、lock、rst_n；实板reset仍待核实 |
| `rtl/platform/tang_mega_138k_pro/diagnostic_tone/top.sv` | 独立诊断顶层 | 单PLL、3FF、tone→I2S、SD使能 |
| `rtl/platform/tang_mega_138k_pro/diagnostic_tone/tone_source.sv` | 固定连续音源 | phase、ready、±1024、started |

## 7. Python文件如何衔接

### 7.1 样本提取与参数准备

| 文件（位于`python/`） | 角色 |
|---|---|
| `paths.py` | 路径统一定义；实际结果在根目录`FFT_results/`，以变量为准 |
| `instruments.py` | 乐器注册、样本来源、分析频带/模态数配置 |
| `fft_analysis/__init__.py` | 分析包说明/入口文件，不是硬件模块 |
| `fft_analysis/core.py` | 样本读取、FFT/分音跟踪、衰减拟合、箱体曲线提取 |
| `fft_analysis/run.py` | 拨弦/击弦乐器提取入口，调用core/plots |
| `fft_analysis/plots.py` | 提取诊断图 |
| `fft_analysis/sustain.py` | 持续类乐器提取；不代表持续类硬件已经实现 |
| `fft_analysis/percussion.py` | 打击乐参数提取；不代表打击乐硬件已经实现 |
| `modal_sim/params.py` | 读NPZ，Patch构造模态表，拟合箱体SOS |

### 7.2 参考模型、ROM与数值验证

| 文件（位于`python/modal_sim/`） | 角色 |
|---|---|
| `engine.py` | 浮点ModalSynth；功能范围比当前RTL宽，不要把里面的噪声/抢占等当成已上板 |
| `fixed_point.py` | 模态整数参考、量化/72bit打包；RTL逐位对拍的基准之一 |
| `body_fixed_point.py` | 从SOS独立构造箱体整数模型 |
| `gen_coeff_table.py` | Patch→浮点模态系数→每乐器量化表，调用engine/fixed_point |
| `gen_hw_rom.py` | 每乐器表→生产modal ROM/稠密索引/manifest |
| `gen_body_rom.py` | Patch.sos→生产body ROM/manifest |
| `fixed_point_check.py` | 定点与浮点的误差检查 |
| `limit_cycle_check.py` | 极限环/残留状态检查 |
| `calibrate_decay.py` | 衰减闭环校准工具，不是板上实时反馈逻辑 |
| `timbre_check.py`、`plot_chain.py` | 音色统计与滤波链可视化 |

### 7.3 电脑端演示/扩展实验

- `run.py`：拨/击类合成演示和验证图。
- `song.py`：电脑端曲目渲染；**不是RTL的`song_player.sv`**，二者不是运行时互相调用。
- `sustain_engine.py`、`sustain_demo.py`：持续类引擎/演示。
- `drumkit.py`、`kit_eval.py`、`cymbal_compare.py`、`roll_compare.py`：打击乐、留出样本验证、镲片/滚奏对比。
- 数学说明：`python/MATH.md`。这些脚本生成电脑音频、图或指标，不直接驱动板上I2S。

## 8. 验证代码如何接到实现

```text
sim/run.py：按短名称选择测试或工具，不默认运行全套
    ↓ 分类测试
    ├─ 驱动RTL输入：时钟、复位、load、sample等
    ├─ 用黄金模型计算预期数据
    └─ 读取RTL输出/提交历史/外部I2S引脚 → assert比较

sim/support/：公共runner、待测输入冻结、箱体参考辅助
sim/audio_helpers/：只用于测试的SV封装和行为模型
```

测试分类、目的和推荐命令只维护在[测试说明](../../../sim/README.md)，完整清单由`python sim/run.py --list`列出，本文不再复制一份文件表。单元测试、真实链路整合、真实综合网表、报告解析夹具和构建工具是不同验证层次；基础用例与独立原参数黄金也不能只因对象相同而合并删除。

`audio_helpers/`中的mock engine用于隔离歌曲调度，行为PLL用于数字时钟/锁定控制，不证明物理PLL或抖动。早期音频/板级替身测试已移入`sim/archive/`，生产真实链路验证在`sim/integration/`。分类依据实际源列表与覆盖范围，不依据`*_review.py`后缀。

## 9. 构建文件、ROM文件和报告

### 9.1 歌曲工程的平台文件

位置：`rtl/platform/tang_mega_138k_pro/`。

- `sources.f`：生产综合文件清单；阅读它可确认哪些旧模块没有加入工程。
- `gowin_build.tcl`：真实工具构建入口，指定device/top、添加源文件、调用综合/P&R。
- `build.sh`：构建启动脚本。
- `preflight.py`、`board_build.json`：构建前结构/IP/参数/约束等核对及配置记录。
- `tang_mega_138k_pro.cst`：生产管脚和电气约束。
- `tang_mega_138k_pro.sdc`：生产时钟、时序和跨域例外约束。
- `report_i2s_pins.tcl`：输出引脚时序报告辅助脚本。
- `audio_pmod2.cst`：辅助/早期音频约束；当前生产源清单使用的是`tang_mega_138k_pro.cst`，不要混用。
- `ip/pll_core_100m/`、`ip/pll_audio_12m5/`及`ip/pll_init.v`：真实vendor PLL包装、实现和支持逻辑。
- `ip/pll_audio_12m288_blocked_proof/`：历史阻塞证明，不是当前可替代音频IP。

主输出管脚：`C21→BCLK`、`B20→LRC`、`B19→DIN`、`A17→SD`，与`MAX98357A_WIRING.md`对照。不要把MAX功放OUT−接地。

### 9.2 ROM不是运行时磁盘读取

- `rtl/rom/modal_coeff.mem`：5483×72bit模态系数。
- `rtl/rom/modal_index.mem`：1024×20bit索引，地址`{instrument,midi,dyn}`；字含present/n_modes/offset。
- `rtl/rom/body_coeff.mem`：80×32bit，4乐器×4节×5系数；生产当前选guitar的20项。
- `modal_manifest.json`、`body_manifest.json`：布局/来源/hash等电脑端元数据，RTL不解析JSON。

`$readmemh`在仿真时读文件，在真实构建时用于初始化片内存储。板子运行时不依赖电脑上的`.mem`文件，也不在每次按音符时访问磁盘。

### 9.3 独立诊断工程

位置：`rtl/platform/tang_mega_138k_pro/diagnostic_tone/`。

- `gowin_build.tcl`：选择独立`diagnostic_tone_top`。
- `tone.cst`、`tone.sdc`：自己的管脚/时序约束。
- `README.md`：诊断操作；当轮数字验证和真实构建记录已移到[测试音历史验收](../archive/2026-10/rtl/platform/tang_mega_138k_pro/diagnostic_tone/PARENT_REVIEW.md)。
- `sim/tools/build_diagnostic_tone_review.py`：冻结输入并做隔离真实构建。
- `sim/tools/review_diagnostic_tone_reports.py`：诊断工程的报告门槛。
- 主工程报告工具：`sim/tools/review_gowin_reports.py`、`sim/tools/review_i2s_pin_delays.py`。

现有脚本中有旧阻塞注释或特定工具版本的报告调用限制；**本阅读图不是对所有旧构建入口“现在都能直接执行”的承诺**。运行构建前应按对应验收文档确认入口，不要为了读代码覆盖现有产物。

## 10. 目前没接入的功能，以及未来放在哪里

目前**没有**压力阵列ADC扫描、USB Host、USB-MIDI设备接收、UART-MIDI事件输入模块。相关对话只是方案讨论。

未来可能的控制链是：

```text
压力阵列 → 模拟前端 → ADC/扫描 → 压力数字值 → 阈值/力度映射 ─┐
USB键盘  → USB Host/桥接 → MIDI解析 → 音符/力度事件 ─────────┤
                                                          ↓
                                                演奏控制/声部分配层
                                                          ↓
                                         modal_engine.load/sample接口
```

它不是把压力值直接塞进I2S，也不是直接替换模态算法。输入事件层还需要维护活动声部、生成激励、按音频节拍提交采样帧，并制定明确的力度档映射/拒绝规则。

当前`song_player`使用`event_index % NUM_VOICES`固定轮换槽位，不是完整的实时声部分配/回收/抢占系统。Note Off、延音踏板、噪声支路、方案C等不能从Python模型的存在推断已经在RTL完成。

## 11. 推荐阅读顺序

### 第一轮：最短可理解的数字音频链

1. `rtl/platform/tang_mega_138k_pro/diagnostic_tone/tone_source.sv`：一个样本是什么，ready为何推进相位。
2. `rtl/audio/i2s_amp_tx.sv`：t/bcnt/nxt怎样把样本变成引脚波形。
3. `rtl/platform/tang_mega_138k_pro/diagnostic_tone/top.sv`：PLL、复位和两模块怎样接线。
4. `sim/diagnostics/test_diagnostic_tone_review.py`：从外部引脚读回左右数据，如何证明标准I2S。

读完能画出一帧BCLK/LRC/DIN，并解释并行`{left16,right16}`与串行32bit时隙的区别。

### 第二轮：声音算法与硬件共享计算

5. `python/MATH.md`、`rtl/DECISIONS.md`：公式、定点尺度与舍入约定。
6. `rtl/core/resonator.sv` + `sim/unit/core/test_resonator.py`：手算一个模态的三个样本。
7. `rtl/core/modal_lane.sv`、`modal_bank.sv`：理解四lane/II3；这是单声部学习台阶。
8. `rtl/core/poly_modal_lane.sv`、`modal_poly_bank.sv`：增加voice地址和多声部调度。
9. `rtl/core/coeff_loader.sv`、`modal_engine.sv`：ROM如何变成当前声部的工作系数。

### 第三轮：整机接起来

10. `rtl/audio/song_player.sv`：曲谱、装载、激励、采样请求。
11. `rtl/core/body_filter.sv`：一次混音结果怎样过四节箱体。
12. `rtl/audio/audio_demo_core.sv`：跟踪`sp_out_sum→body_src_sum→src_i16→tx_hold`。
13. `rtl/audio/audio_async_fifo.sv`、`audio_transport.sv`：跨时钟数据与反向采样节拍。
14. 平台`board_top.sv→top.sv→board_audio_core.sv`及`clock_reset.sv`：实际参数、时钟、管脚。
15. `sim/integration/test_audio_chain_review.py`、`test_audio_board_review.py`：从真实系数/引擎到外部引脚的整链检查。

### 第四轮：追溯参数为什么这样取

16. `python/fft_analysis/core.py`、`run.py`：从录音提取模态。
17. `python/modal_sim/params.py`、`engine.py`、`fixed_point.py`：浮点参数到整数模型。
18. `gen_coeff_table.py→gen_hw_rom.py`，以及`gen_body_rom.py`：生成生产ROM。

## 12. 阅读时的五个常见误区

1. **文件存在≠顶层使用。** `resonator`不是生产lane的子模块，PT8211分支不是当前MAX发送链，麦克风分支当前关闭。
2. **默认参数≠实际参数。** 必须追上一层实例化覆盖，特别是声部数和BODY使能。
3. **valid≠已经接收。** 有ready的接口只在`valid && ready`同拍为真时接收；bank/body的结果out_valid是单拍且没有输出ready，需要整合层暂存接住。
4. **时钟周期≠音频样本周期。** 核心10ns、音频参考80ns、BCLK320ns、音频帧20.48µs；许多核心周期共同完成一个样本。
5. **仿真通过≠实板出声/完整时序签核。** 测试音、歌曲、PLL的验收范围不能混用；最新结果见统一工程汇报，不在本文重复更新。

旧README/文件头中还出现24bit输出、精确12.288MHz、旧结果路径、已经不存在的根目录`top.sv`或`legacy_sythsound/`等历史描述。阅读本版本以实际实例和参数为准：**生产输出16bit PCM、12.5MHz音频参考；当前旧库实际目录是`sythsound/`。**

开发规格入口：`rtl/module2A_design.md`、`rtl/module2BC_design.md`、`rtl/body_design.md`。验收状态只看[工程汇报](../工程汇报.md)；历史任务和旧`reports/`中的失败/临时报告不是当前通过证明。

读一个RTL文件时，建议在纸上只记五项：**它的时钟、输入数据、接收条件、内部状态、输出完成条件**，再沿实例名和信号名跳到上下游。这比先逐行看所有always块更容易建立全局理解。
