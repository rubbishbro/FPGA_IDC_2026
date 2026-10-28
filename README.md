# FPGA_IDC_2026 — FPGA 模态合成电子乐器

面向 IDC 竞赛、基于 Tang Mega 138K Pro（Gowin）的实时合成项目。声音由 HDL 逐样本递推产生；`music_resources/` 录音用于离线提取参数，Python WAV 用于试听与验证。

更新：**2026-10-28**，对照 `c00e3646`，补核最近拉取的 `8e9d1cda`。项目处于模块验证与整机集成阶段，验证结果保留各自执行日期。

## 当前实现

| 部分 | 已有实现 | 仍待完成 |
|---|---|---|
| 声部路由 `rtl/router/` | 默认 16 槽×64 模态，双 bank、两个 `eng_router` 并行处理各半声部；钢琴/吉他选 eng0，其余暂选 eng1；激励、逐声部包络、5 段腔体、四梳状混响 | 全路径数值/吞吐、bank B 独立性、真实 Flash 和整机验收 |
| Flash 与音高 | loader按slot-major读取独立音高表；钢琴打包器默认16个MIDI音，现镜像仍来自旧默认系数表 | 新scaled表与打包链统一、吉他音高标签修正、连续32音/音区和真片验收 |
| 压力垫/摇杆 | 采集 FSM 已有泄放、建立、请求、完成锁存与超时重试；成对 X/Y 出口及校准/八方向/连发适配器已实现 | 真实 ADC、矩阵逐键位置、扫描延迟和板级校准 |
| 配置与中文侧栏 | `control_loop` → `config_dispatch` → 整包 CDC → 像素帧头提交；默认 LCD demo 使用中文隐藏侧栏 | 音量/音色/混响/MIDI 等真实后端接入；未接项按能力位禁用 |
| 通信 `rtl/comm/` | 双 UART/HC-05、SLIP/CRC、MIDI/Config 解析、来源隔离与恢复接口 | MIDI→音符状态→fmap、配置协议转换、真实清音/退休确认与 App |
| 可视化 | 1024 点 FFT、BARS/WAVE/FALL、主题/峰值/网格等；独立 demo 使用测试音源 | 主合成器 PCM、音频跨域 FIFO 与现场联机 |
| 板级出声 | 历史 FIFO/I2S/DAC 链保存在 `history/rtl/audio/` | 新 router→PCM 缩放/饱和→FIFO→I2S→DAC；四复音、持续变调和端到端延迟测量 |
| Python | 参数提取、整数/浮点模型、A/B/C 试听、eng1 对拍入口 | 模型与当前顶层的激励/选核/加载差异收口 |

`rtl/core/` 是保留的共享 RAM ABC/E2 实现，与 `rtl/router/` 分开。其“21 项 PASS”属于 2026-10-22 历史记录；当前入口仍因 `rtl/simsynth/` 迁移而中断。`pad_voice_top` 默认 `N_MODES=48`，与 `voice_router`/钢琴镜像的 64 模态默认值不同，集成时必须统一。

生成器当前写入piano_coeff_scaled.txt，打包器默认仍读取piano_coeff.txt；两者不能画成一条已接通的新表链。输入选择与定标细节见 [系数合同](rtl/router/README.md#coefficient-pipeline)。

**阅读入口：**[代码架构](CODE_ARCHITECTURE.md) · [文档索引](docs/README.md) · [当前问题](docs/bugs.md) · [赛题核对](docs/赛题要求完成度核对.md)。

## 数据流与目录

```text
电脑离线：music_resources → python/fft_analysis → FFT_results/params
         → python/modal_sim → FFT_results/sim/eng1（模型试听）

当前合成：压力矩阵/外部 fmap → pad_voice_top → voice_router
         → 激励/包络 → 双 bank 合成 → 混音 → 腔体 → 混响 → y_valid/y_data
         → 待集成 PCM/FIFO/I2S/DAC 与可视化音频输入

本地配置：原始摇杆/双按键 → sidebar_system → control_loop → config_dispatch
         → 显示快照 CDC/帧头应用，或真实后端请求/结果
外部通信：双 UART/HC-05 → transport → analyzer → 事件/配置接口
         → 待接演奏消费者和侧栏协议适配
```

| 目录 | 用途 |
|---|---|
| `python/` | 参数分析、模型、ROM 生成及试听；数学说明在 `MATH.md` |
| `rtl/router/` | 当前声部路由、DSP、Flash loader/打包器与音乐测试 |
| `rtl/core/` | 保留的共享 RAM 路径；不能与新 router 混用证据 |
| `rtl/drivers/`、`rtl/comm/` | 压力/摇杆、UART/HC-05、传输、解析和会话协调 |
| `rtl/config_pkg.sv`、`config_dispatch.sv`、`control_loop.sv` | 配置合同、提交协调和请求轮询 |
| `sim/` | 通信、控制、摇杆、侧栏、模型验证及旧 core 回归 |
| `FFT_spectrumshow/` | 独立频谱/LCD demo；50MHz 控制、约 33.333MHz 像素域 |
| `FFT_results/` | 参数、提取图、模型音频；不是板级录音 |
| `docs/` | 当前设计、验收边界、问题及专题说明 |
| `reference_agent_readfirst/` | 赛题和平台入口；详细板卡资料/答疑在其 `docs/` |
| `history/` | 旧 RTL、测试、图和阶段记录；不参与当前生产构建 |
| `sythsound/` | 独立 Python 合成实验库；其钢琴系数生成器也供 router 镜像工具使用 |
| `build/` | 本地构建产物与日志，Git 忽略 |

## Python 快速开始

以下命令在仓库根目录执行；生成脚本会更新相应产物。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r python/requirements.txt

python python/fft_analysis/run.py          # A 类参数提取
python python/fft_analysis/sustain.py      # 持续音
python python/fft_analysis/percussion.py   # 打击乐
python python/modal_sim/eng1_demo.py       # A/B 整数模型试听
python python/modal_sim/eng1_pieces.py     # 吉他/钢琴片段
python python/modal_sim/eng1_bc_demo.py    # B/C 共用 Eng1Core
```

样本需位于 `music_resources/`，试听所需参数在 `FFT_results/params/`。旧试听产物在 [历史目录](history/FFT_results/sim_pre_eng1_2026-10/README.md)；旧脚本仍可运行，路径由 `python/paths.py` 定义。Python A/B/C 分类和音色数量不等于板端已交付清单；钢琴/吉他当前选 eng0，eng1 试听不代表该路由选择已改变。

## 验证与构建

```bash
python3 sim/run_control_loop.py          # 15 组
python3 sim/run_joystick.py              # 26 组
python3 sim/run_comm.py                  # 13 项
python3 sim/check_comm_vectors.py        # 协议向量与分片流
python3 sim/run_ui.py --legacy           # 3 组侧栏 + 14 项原可视化
python -m pytest -q sim/unit/eng1/test_router_eng1.py
python python/modal_sim/eng1_cosim.py --mode intended
```

2026-10-27 本轮复测：上面前五项全部通过，Python 模型 **33 passed**；eng1 intended 对拍 **66 作业中 3 项失败，均为 `n_modes=0`**，不能继续引用旧兼容模式的全通过结论。旧 core 脚本前两项通过，第 3 项因缺失源文件中断。完整结果、工具条件和报告边界见 [仿真说明](sim/README.md) 与 [验证记录](docs/工程评审与验证.md#verification)。

新 router 音乐测试使用 Windows Vivado xsim：`pwsh -File rtl/router/tools/run_all.ps1`，详见 [router 说明](rtl/router/README.md)。它会生成镜像并直接灌入仿真 RAM，不覆盖真实 Flash；本轮未运行 xsim。

LCD demo 构建见 [可视化说明](FFT_spectrumshow/README.md)，通信探针见 [验证记录](rtl/comm/VERIFICATION.md)。独立探针时序或既有 bitstream 不能代替当前音频整机验收。

## 文档约定

根目录保留本 README 与架构导读；除名为 `docs` 的目录及其子目录外，每个目录最多两份说明文档。专题设计集中于 `docs/`；历史记录标明日期和适用范围，当前结论以实现和可复现验证为依据。依赖清单、系数数据、许可证及工具生成报告按原用途保留。
