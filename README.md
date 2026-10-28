# FPGA_IDC_2026 — FPGA 模态合成电子乐器

面向 IDC 竞赛、基于 Tang Mega 138K Pro（Gowin）的实时合成项目。声音由 HDL 逐样本递推产生；录音用于离线提取参数，模型与 RTL WAV 用于试听验证。

更新：**2026-10-29**。核对已提交的 `32b92498` 及当前未提交工作区。项目处于模块验证与整机集成阶段；已执行的历史测试和本次复测分别记录。

## 当前实现

| 部分 | 已有实现 | 仍待完成 |
|---|---|---|
| 合成 `rtl/router/` | 默认16槽、64模态存储，双bank并行；钢琴/吉他选eng0，其余选五级流水eng1；实际计算64/20/48模态 | eng1四种持续音色的逐槽周期驱动/ADSR、真实资源及整机验收 |
| Flash与音高 | 6Bh串行地址修复、逐槽偏移/掩码/中止/超时、失败静音；钢琴/吉他scaled表接入打包，默认16音镜像按64条/槽存储 | 六种正式连续32音资源、统一烧录清单、真片QE/时序和听测 |
| 演奏与配置 | MIDI音符归属、力度、重触发、踏板、来源清理、两组16音切换；本地UI音色/通道联合提交与实际结果 | 远程配置协议桥、CC音量/EQ/Bend等DSP消费者、当前panic抢占回归 |
| 压力垫/摇杆 | 采集FSM、X/Y成对出口、校准/八方向/连发 | 真实ADC、16键位置/扫描延迟及板级校准 |
| 音频 `rtl/audio/` | PCM16舍入/饱和、异步FIFO、I2S、帧节拍CDC模块已有 | 当前两个演奏顶层缺少音频端口/实例，系统回归中断；须恢复接线后验证时钟/约束/DAC |
| 可视化 | 1024点FFT、BARS/WAVE/FALL、中文隐藏侧栏；独立demo使用测试音源 | 主合成PCM抽头、独立音频跨域与现场同源显示 |
| 本地上位机 | WebGL MIDI编辑、多轨/循环/力度、导入导出、有线Web Serial和v1编码 | 物理UART/Flash/DAC联调、板端能力查询/远程配置/PCM回传 |
| Python | 参数提取、整数/浮点模型、A/B/C试听与对拍 | 模型Q30与当前router Q24、激励/选核/资源差异继续对齐 |

**本次复测：**eng1 **256组逐模态对拍通过**，PCM/I2S模块单测通过；系统集成在展开时报告缺少 `AUDIO_ENABLE`。此前8项音频回归通过属于先前接线快照，不能代表当前工作区。上位机 **17项单测及语法检查通过**；钢琴/吉他默认打包结果与现有bin/mem逐字节相同。详见[最新核对记录](docs/工程评审与验证.md#global-docs-2026-10-29)。

`rtl/core/` 保留另一套共享RAM实现，与当前router分开。其历史21项PASS不代表当前回归通过；旧入口仍有迁移缺失。当前源码没有同时接通输入、DAC与LCD的统一板级顶层。

**阅读入口：**[代码架构](CODE_ARCHITECTURE.md) · [专题索引](docs/README.md) · [当前问题](docs/bugs.md) · [赛题验收](docs/赛题要求完成度核对.md)。

## 数据流与目录

```text
离线：录音 → python/fft_analysis → FFT_results/params → 模型试听/候选资源
      sythsound/*_coeff_scaled.txt → router/tools/*_flash.py → Flash镜像
演奏：comm_top事件 → midi_voice_top → 音符状态/选源 → voice_router → signed64
      压力/外部fmap → pad_voice_top ──────────────────────┘
配置：侧栏 → control_loop → config_dispatch → MIDI联合配置后端/显示CDC
输出：signed64 → 待恢复顶层接线 → rtl/audio → I2S → 待验DAC
显示：独立测试音源 → FFT/LCD；主合成PCM仍待接入
```

| 目录 | 用途 |
|---|---|
| `rtl/router/`、`rtl/midi/` | 当前合成、loader、演奏状态及配置后端 |
| `rtl/audio/` | PCM/FIFO/I2S模块与接入合同 |
| `rtl/drivers/`、`rtl/comm/` | 压力/摇杆、UART/HC-05、传输/解析/来源会话 |
| `rtl/config_pkg.sv`、`config_dispatch.sv`、`control_loop.sv` | 统一配置类型、真实结果提交与轮询 |
| `sim/` | 各模块与系统回归入口 |
| `FFT_spectrumshow/` | 独立FFT/LCD/侧栏demo，50MHz控制、约33.333MHz像素域 |
| `python/`、`FFT_results/` | 提取、模型、参数/图/试听；数学说明见python/MATH.md |
| `sythsound/` | 独立Python实验库及router钢琴/吉他资源生成 |
| `web/midi-editor/` | 本地MIDI编辑与UART上位机 |
| `docs/`、`reference_agent_readfirst/` | 专题设计/验收/问题，以及赛题/平台依据 |
| `history/`、`rtl/core/` | 历史工程与保留路径；验证证据不能混用 |
| `build/` | 本地日志/构建产物，Git忽略 |

## 本地 MIDI 上位机

Node.js 20+，无需安装依赖：

```bash
npm --prefix web/midi-editor run dev
```

在Chrome/Edge打开 `http://127.0.0.1:5173`。电脑参考试听使用三角波；UART按v1 SLIP/CRC发送当前音乐时间的演奏事件，播放前校验板端通道与已加载16音清单。板端音色/来源/音组仍需本地设置，操作与边界见[上位机说明](web/midi-editor/README.md)。

## Python 与验证入口

在仓库根目录执行；提取/试听脚本会写相应产物：

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r python/requirements.txt
python python/fft_analysis/run.py
python python/modal_sim/eng1_demo.py
python python/modal_sim/eng1_bc_demo.py
```

样本放在 `music_resources/`，模型参数在 `FFT_results/params/`。模型音色数量不等于硬件交付清单，eng1试听不能代表实际钢琴/吉他eng0路径。

```bash
python3 sim/run_control_loop.py
python3 sim/run_joystick.py
python3 sim/run_comm.py
python3 sim/check_comm_vectors.py
python3 sim/run_midi.py
python3 sim/run_router_midi.py
python3 sim/run_ui.py --legacy
python3 sim/run_audio.py --test eng1 --test bridge
npm --prefix web/midi-editor test
```

`sim/run_audio.py` 的完整系统矩阵当前因顶层接口缺失而失败。旧 `eng1_cosim.py` 使用历史测试接口，不再作为流水eng1的当前通过依据。Windows音乐/loader脚本、工具要求及已知入口缺口见[sim说明](sim/README.md)；本次未运行xsim、PnR或上板。

## 文档约定

根目录保留本README与架构导读；除名为 `docs` 的目录及其子目录外，每个目录最多两份说明文档。专题按职责组织，重复方案合并，交叉内容引用唯一合同。依赖清单、系数数据、许可证、第三方元数据和生成报告按原用途保留。
