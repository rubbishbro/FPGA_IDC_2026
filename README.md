# FPGA_IDC_2026 — FPGA 模态合成电子乐器

面向 IDC 竞赛、基于 **Tang Mega 138K（Gowin）** 的实时音频合成项目，包含离线参数提取、Python 参考模型、FPGA 合成与声部路由、压力垫／摇杆驱动，以及独立 LCD 音频可视化。

核心路线是**模态合成**：激励驱动多个衰减谐振器或状态空间模态，逐声部处理包络、混音，再经过共享腔体与混响。录音样本只用于**离线提取参数与对比音色**；目标板端逐样本计算声音，不播放预录 PCM。电脑生成的 WAV 是试听／验证材料，不是板端音源。

## 当前状态与阅读入口

更新：**2026-10-25**。目前处于模块验证与整机集成阶段，**不是已经完成板级验收的电子乐器**。

| 部分 | 当前实现与边界 |
|---|---|
| Python 工具链 | 参数提取、浮点／定点参考、A/B/C 类音色与曲目试听；不等于对应功能已上板 |
| 新声部路由 `rtl/router/` | `voice_router` 默认 16 声部 × 48 模态；顶层持有系数／状态，选择 E2 或 ABC 计算核，接逐声部包络、混音、5 段腔体和四梳状混响；仍有地址、反馈、包络、混响及吞吐问题 |
| 压力垫接入 | `pad_voice_top` 已连接旧压力垫驱动与新 router，支持外部 `fmap` 旁路；扫描／ADC 握手与键位音高映射仍待验证，输出 `y_valid/y_data` 不是 I2S／DAC |
| 原共享 RAM 路径 `rtl/core/` | 与新 router 分开保留；旧“21 项 PASS”是历史结果，当前 `sim/run_core.sh` 引用已迁移的 `rtl/simsynth/`，完整回归入口尚未恢复 |
| LCD 可视化 `FFT_spectrumshow/` | 独立 BARS／WAVE／FALL／SETTINGS demo，使用三音或扫频测试源；尚未接主合成器 PCM 与异步 FIFO |
| 板级音频 | 旧 I2S／FIFO 实现在 `history/rtl/audio/`；新链尚未完成合成→PCM→I2S→DAC 集成，复音、持续变调和端到端延迟仍待验收 |

**优先阅读：**[当前问题清单](docs/bugs.md) · [赛题要求完成度核对](docs/赛题要求完成度核对.md) · [新 router 结构](rtl/router/README.md) · [可视化说明](FFT_spectrumshow/README.md)。

已有记录：2026-10-25 完成度核对记录了可视化 **14 项 PASS**、新 router **4 项模块测试 PASS**；旧核心脚本前 2 项通过后在第 3 项编译中断。这些是对应范围的既有记录，不是整机通过，也不是本次 README 更新重新运行的结果。部分子目录文档保留旧阶段结论，应结合日期、源码及问题清单阅读。

## 合成模型与数据流

Python 参考模型按激励分为三类；这不是板端已交付音色清单：

| 类别 | 激励 | 离线模型／试听示例 |
|---|---|---|
| **A：拨弦／击弦** | 有限力脉冲 | 吉他、钢琴、班卓、曼陀林 |
| **B：持续音** | 周期脉冲串 | 长笛、小号、大提琴；另有小提琴／双簧管提取参数 |
| **C：打击乐** | 脉冲＋整形噪声 | 底鼓、军鼓、通鼓、踩镲、叮叮镲、吊镲 |

```text
【电脑：离线提取与验证】
music_resources/ 录音样本
    → python/fft_analysis/ 提取基频、分音、衰减、持续音／打击乐参数
    → FFT_results/params/ 参数表
    → python/modal_sim/ 浮点／定点参考与曲目渲染
    → FFT_results/sim/eng1/ 当前新音频
    → history/FFT_results/sim_pre_eng1_2026-10/ 旧 A/B/C 合成产物

【FPGA：新 router 实现，尚待正确性与整机验收】
压力矩阵／外部 fmap → pad_voice_top → voice_router
    → 激励／包络／调制 → eng0（E2）或 eng1（ABC）
    → 逐声部包络 → 混音 → 腔体 → 混响 → y_valid/y_data
    → [待集成：PCM 适配／FIFO／I2S／DAC]
```

Python 参数生成、旧 core ROM 与新 router Flash 镜像的格式不同，不能直接混用。新 router 的 W25Q64 加载格式与打包工具见 [`rtl/router/README.md`](rtl/router/README.md) 和 `rtl/router/tools/flash_image.py`。

## 目录结构

```text
python/
  paths.py                 离线分析／试听结果路径定义
  instruments.py           乐器、样本来源与分析配置
  requirements.txt         numpy、scipy、matplotlib、soundfile
  fft_analysis/            样本分析与参数提取
  modal_sim/               合成参考、定点验证、参数生成与试听；
                           router_eng1.py / eng1_demo.py 是 router 级 eng1 整数模型
  MATH.md                  模态模型与离散更新数学说明

rtl/
  router/                  新声部路由、计算核、包络／调制／效果、Flash loader
  core/                    原共享 RAM ABC/E2 路径，与新 router 分开
  drivers/                 4×4 力敏矩阵、摇杆、8×8 LED 与 ADC IP
  math/                    公共定点运算与数学模块
  rom/                     ROM 数据与元信息，使用前核对对应路径
  platform/                平台相关文件
sim/                       原共享 RAM 路径测试与综合探针
FFT_spectrumshow/          独立 FFT、波形、瀑布曲线与 LCD UI demo

FFT_results/
  params/                  提取的参数表
  figures/<inst>/          参数提取诊断图
  sim/<topic>/            分主题音频、图表与指标
music_resources/           只读样本库：Philharmonia、AVL、Salamander 等
docs/                      问题清单、赛题核对、产品与上位机讨论
reference_agent_readfirst/ 板卡、赛题原文与答疑资料
history/                   旧 RTL、测试及阶段文档，仅用于追溯
sythsound/                 早期独立模块化合成实验库，不接当前 FPGA 主链
build/                     构建产物，不作为当前验收结论来源
```

## Python 快速开始

以下命令在**仓库根目录**执行。先准备虚拟环境与依赖；只试听已有结果时无需运行脚本。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r python/requirements.txt
```

提取参数需要 `music_resources/` 中对应的原始样本；渲染需要 `FFT_results/params/` 中的相应参数。脚本会生成或更新结果文件，运行前请保存需要保留的试听结果。

```bash
# 参数提取（已有参数时可跳过）
python python/fft_analysis/run.py                # 拨弦／击弦类
python python/fft_analysis/sustain.py            # 持续音类
python python/fft_analysis/percussion.py         # 鼓组 → params/drums.npz

# 合成与验证（按需选择，不必全部执行）
python python/modal_sim/run.py                  # A 类试听与对比图
python python/modal_sim/sustain_demo.py         # B 类持续音
python python/modal_sim/drumkit.py              # 鼓组与伴奏
python python/modal_sim/kit_eval.py             # 鼓组留出样本验证
python python/modal_sim/song.py                 # 歌曲片段
python python/modal_sim/bella_ciao.py            # Bella Ciao，曼陀林
python python/modal_sim/song_mystery_flute.py    # Mystery of Love，长笛＋吉他
python python/modal_sim/eng1_demo.py             # router 级 eng1 整数模型（A/B 试听）
python python/modal_sim/eng1_cosim.py            # eng1 与 RTL 对拍（需 iverilog）
```

当前保留的新试听在 [`FFT_results/sim/eng1/`](FFT_results/sim/README.md)：

- `eng1_guitar_dry.wav`：A 类 guitar，走当前 router 的 eng1 整数链（body=guitar、混响 NONE）。
- `eng1_flute_hall.wav`：B 类 flute（body=passthrough、混响 HALL）。
- 两段都是 Python 模型输出，不是 RTL 板级录音。

旧 A/B/C 类的曼陀林、长笛、鼓组、揉弦等音频/图表已整体归档到
[`history/FFT_results/sim_pre_eng1_2026-10/`](history/FFT_results/sim_pre_eng1_2026-10/README.md)，
生成脚本仍在 `python/modal_sim/`；当前 `FFT_results/sim/` 只保留 eng1。

长笛音色对比与后处理工具：

```bash
python python/modal_sim/flute_timbre_compare.py  # 模型与源样本频谱对比
python python/modal_sim/flute_warm_mix.py        # 已渲染 WAV 的暖色 EQ／混响
python python/modal_sim/stereo_mix.py            # 已渲染分轨的立体声展示混音
```

上述离线分析／试听结果路径由 `python/paths.py` 定义，主要写入 `FFT_results/`；ROM／Flash 生成工具有各自的目标文件与格式契约。

## RTL 仿真与构建

- **新 router：**模块、测试清单及源文件依赖见 [`rtl/router/README.md`](rtl/router/README.md)，测试位于 `rtl/router/tb_*.sv`，辅助脚本位于 `rtl/router/tools/`。部分用例存在 Icarus 兼容性阻塞，已知功能问题见 [`docs/bugs.md`](docs/bugs.md)。
- **原共享 RAM 核：**入口为 `bash sim/run_core.sh`，需要 Icarus Verilog（`iverilog`／`vvp`）。**当前源清单迁移未完成，不能作为一键全通过命令**；历史测试范围见 [`sim/README.md`](sim/README.md)。
- **可视化：**测试清单在 `FFT_spectrumshow/sim/run_regression.ps1`，板级顶层为 `FFT_spectrumshow/board/ui_demo_top.v`；工具路径、构建与下载步骤见[独立说明](FFT_spectrumshow/README.md)。
- **综合／时序：**新 router 的 `syn_only.tcl`、`synth_pnr_router.tcl` 与旧 `sim/synth/` 探针对应不同目标。探针 Fmax、既有 bitstream 或模块仿真不能代替当前整机的时序／出声验收。

## 更多资料

- [问题清单](docs/bugs.md)：主 router、压力采集、适配层与测试阻塞。
- [赛题要求完成度核对](docs/赛题要求完成度核对.md)：基础／拓展要求、证据边界与待验收清单。
- [数学模型](python/MATH.md) · [参数提取汇总](FFT_results/report.md) · [离线仿真交付说明](FFT_results/sim/README.md)。
- [ENG1 Python 模型](docs/ENG1_PY_MODEL.md)：router 级 eng1 的位宽契约、与当前 RTL 的
  F05/F08/F09 差异、对拍方式和未覆盖边界（拍数、loader、调制、C 类）。
- [板卡资料](reference_agent_readfirst/fpga_platform.md) · [赛题摘录](reference_agent_readfirst/competition_requements_most_important.md)。
- [上位机可行性分析](docs/上位机可行性分析.md) · [产品需求与竞品调研](docs/产品需求与竞品调研.md)：规划／讨论，不代表已实现。
- [历史工程汇报](history/docs/工程汇报.md)与 `CODE_ARCHITECTURE.md` 保留早期架构信息，不作为新 router 的当前实现或验收依据。
