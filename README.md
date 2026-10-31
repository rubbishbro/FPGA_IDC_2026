# FPGA_IDC_2026 — FPGA 模态合成电子乐器

面向 IDC 竞赛、基于 Tang Mega 138K Pro（Gowin）的实时合成项目。声音由 HDL 逐样本递推产生；录音用于离线提取参数，模型与 RTL WAV 用于试听验证。

更新：**2026-10-29**。核对已提交的 `d93778af` 及当前板级集成工作区。项目处于模块验证与整机集成阶段；已执行的历史测试和本次复测分别记录。

## 当前实现

| 部分 | 已有实现 | 仍待完成 |
|---|---|---|
| 合成 `rtl/router/` | 默认16槽、64模态存储，双bank并行；钢琴/吉他选eng0，其余选五级流水eng1；实际计算64/20/48模态；四种持续音色已接逐槽周期驱动/ADSR和释放退休 | 正式资源、实板听感及整机验收（当前50MHz物理时序已通过） |
| Flash与音高 | 6Bh串行地址修复、逐槽偏移/掩码/中止/超时、失败静音；钢琴/吉他scaled表接入打包，默认16音镜像按64条/槽存储 | 六种正式连续32音资源、统一烧录清单、真片QE/时序和听测 |
| 演奏与配置 | MIDI音符归属、力度、重触发、踏板、来源清理、两组16音切换；本地UI音色/通道联合提交与实际结果 | 板级已接REVERB_SET真实结果和0502权限；CC音量/EQ/Bend DSP、忙时panic及实物联机仍待完成 |
| 压力垫/摇杆 | 采集FSM、X/Y成对出口、校准/八方向/连发；板级已接LED与逐轴死区 | 模拟ADC、16键位置/扫描延迟和实板校准 |
| 音频 `rtl/audio/` | PCM16舍入/饱和、异步FIFO、I2S、帧节拍CDC模块已有 | 两个演奏顶层已恢复I2S并接入统一板级；当前50MHz整板PnR已通过，DAC实板待验 |
| 可视化 | 1024点FFT、BARS/WAVE/FALL、中文隐藏侧栏；独立demo使用测试音源 | 统一板级显示真实菜单，FFT读口暂接零；PCM抽头/独立CDC留到第二阶段 |
| 本地上位机 | WebGL MIDI编辑、多轨/循环/力度、导入导出、有线Web Serial和v1编码 | 物理UART/Flash/DAC联调、板端能力查询/远程配置/PCM回传 |
| Python | 参数提取、整数/浮点模型、A/B/C试听与对拍 | 模型Q30与当前router Q24、激励/选核/资源差异继续对齐 |

**当前50MHz整板PnR已通过。** 最新构建包含一阶音高调制、真实FFT/极坐标、双声道与PT8211；setup/hold违反均0，最差setup +1.426ns，core报告Fmax53.839MHz。物理实现及源文件hash见[最新PnR验收](docs/工程评审与验证.md#eng1-pitch-pnr-2026-10-30)。尚未烧录，B类资源安装、实板听感及精确48k时钟仍待验收；历史100MHz目标未签核。

`rtl/core/`保留另一套共享RAM实现，其历史21项PASS不代表当前回归通过。统一板级入口为[instrument_board_top](rtl/platform/tang_mega_138k_pro/README.md)，默认仅钢琴16音；12.5MHz音频参考对应48.828125kHz，相对48k资源快约1.725%，精确48k和正式六种32音资源仍需收口。

**阅读入口：**[代码架构](CODE_ARCHITECTURE.md) · [专题索引](docs/README.md) · [当前问题](docs/bugs.md) · [赛题验收](docs/赛题要求完成度核对.md)。

## 数据流与目录

```text
统一入口 instrument_board_top
  ├─ 50MHz → core100MHz / audio12.5MHz / pixel33.333MHz，失锁共同复位
  ├─ PAD/摇杆/LED ──────────┐
  ├─ 双UART → comm → MIDI ──┴─→ 一套voice_router → PCM/FIFO/I2S → 待验DAC
  └─ 摇杆/按键/远程REVERB → loop/dispatch → 真实音频后端 + LCD菜单
                                             FFT读口暂为零
离线：录音/提取表 → 资源生成/manifest → Flash系数及同源逐槽配置
后续：合成PCM的独立副本/CDC → FFT/WAVE/FALL，不能反压I2S
```

| 目录 | 用途 |
|---|---|
| `rtl/platform/tang_mega_138k_pro/` | 统一板级入口、唯一源清单、时钟/复位、引脚/约束、构建与验收 |
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

串口／蓝牙现可在“输入→演奏方式”选择[引导演奏](docs/MIDI演奏与通信接入.md#midi-guide)：LCD显示4×4目标键，外部MIDI只提示，实体压力键负责发声。菜单／状态／合成／整版协议仿真及板级综合已通过，未烧录；物理时序边界仍按现有I04处理。

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
python3 sim/run_audio.py
python3 sim/run_sustain.py
python3 sim/run_flash_ref.py
python3 sim/run_board.py
npm --prefix web/midi-editor test
```

持续前端、完整音频、vendor Flash模型及板级回归均已有正式入口。旧eng1_cosim.py仍使用历史接口，不作为当前流水核通过依据。命令/工具条件见[sim说明](sim/README.md)，板级构建、接线及自动时序验收只在[板级说明](rtl/platform/tang_mega_138k_pro/README.md)维护。本次不重跑长测/PnR或烧录；功能复测与既有报告复核分别记录。

## 文档约定

根目录保留本README与架构导读；除名为 `docs` 的目录及其子目录外，每个目录最多两份说明文档。专题按职责组织，重复方案合并，交叉内容引用唯一合同。依赖清单、系数数据、许可证、第三方元数据和生成报告按原用途保留。

当前板级配置已对齐 `origin/board50@d47b14df`（50MHz核心、板载Flash QE初始化、实板键盘/蓝牙/I2S管脚）；本地双声道与引导演奏功能保留。构建与接线以[板级说明](rtl/platform/tang_mega_138k_pro/README.md)为准，历史100MHz PnR报告不代表当前50MHz版本验收。

2026-10-30已选择性迁入board50的真实FFT/波形和极坐标历史页，经独立异步FIFO连接主合成PCM；保留本地双声道、PT8211和MIDI引导。新版U5仍为DIN=B21、GAIN=A20外接3V3，未采用远端冲突引脚或硬编码12倍音量。详见[迁移范围与验证](docs/工程评审与验证.md#board50-migration-2026-10-30)。
