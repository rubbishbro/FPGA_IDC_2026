# FPGA_IDC_2026 — FPGA 模态合成电子乐器

面向 IDC 竞赛、基于 Tang Mega 138K Pro（Gowin）的实时合成项目。声音由 HDL 逐样本递推产生；录音用于离线提取参数，模型与 RTL WAV 用于试听验证。

更新：**2026-11-01**。本地已合入整理后的main。当前源码尚未重新编译；板上为已校验3ED7六音色固件，本轮不编译、不烧录。

## 当前实现

| 部分 | 已有实现 | 待验收 |
| --- | --- | --- |
| 合成 | 16槽双bank，eng0矩阵与eng1 ABC同等接入；六种已安装音色 | 增益偏小、连续演奏/听感；正式32音未冻结 |
| 资源与音高 | 固定Flash分区、768KiB混合镜像；ENG1 Bend/CC1、一阶更新及原子提交 | 合并后资源/标定身份、音准与时变控制 |
| 演奏与配置 | PAD/MIDI、力度/重触发/踏板/归属；真实配置结果与REVERB_SET | 忙时panic、CC音量/EQ及实物联机 |
| 输入与灯光 | 压力/摇杆扫描；LED位序与摇杆上下修复已烧录 | 模拟ADC、位置/延迟、灯光观感和方向 |
| 音频 | PCM16/FIFO、标准I2S及板载PT8211/3.5mm，立体声最大侧单位增益 | 合并后混响极值回归、模拟电平及新PnR |
| 显示 | 真实PCM独立CDC、FFT/波形/极坐标；main新增fmap叠加 | 新叠加层与录制合并后的整板验收 |
| 上位机 | 多轨编辑/导出/Web Serial；有线事件录制生成可编辑轨道 | 真实UART录制回放；PCM/WAV回传尚未实施 |
| Python | 当前Q24整数模型、前端/路由对拍及音色实验 | 实验专用唇振/气流不等同已接入RTL |

参数只维护在[音频设计](docs/音频设计.md)；源码、板上固件、历史测试及未关闭问题见[调试记录](docs/调试记录.md)和[问题表](docs/bugs.md)。默认固定16音，音频时钟12.5MHz对应48.828125kHz，48kHz资源有约+29.6音分速度偏差。

**阅读入口：**[文档](docs/README.md) · [代码架构](CODE_ARCHITECTURE.md) · [上板测试](docs/上板测试.md) · [赛题验收](docs/赛题验收.md)。

## 数据流与目录

```text
统一入口 instrument_board_top
  ├─ 50MHz → core50MHz / audio12.5MHz / pixel33.333MHz，失锁共同复位
  ├─ PAD/摇杆/LED ──────────┐
  ├─ 双UART → comm → MIDI ──┴─→ 一套voice_router → PCM/FIFO/I2S → I2S/PT8211
  └─ 摇杆/按键/远程REVERB → loop/dispatch → 真实音频后端 + LCD菜单
                                             独立PCM FIFO → FFT/波形/极坐标
离线：录音/提取表 → 资源生成/manifest → Flash系数及同源逐槽配置
显示取得独立PCM副本，不能反压I2S
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

串口／蓝牙现可在“输入→演奏方式”选择[引导演奏](docs/MIDI接入.md#midi-guide)：LCD显示4×4目标键，外部MIDI只提示，实体压力键负责发声。菜单／状态／合成／整版协议仿真及板级综合已通过，未烧录；物理时序边界仍按现有I04处理。

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

2026-10-30已选择性迁入board50的真实FFT/波形和极坐标历史页，经独立异步FIFO连接主合成PCM；保留本地双声道、PT8211和MIDI引导。新版U5仍为DIN=B21、GAIN=A20外接3V3，未采用远端冲突引脚或硬编码12倍音量。详见[迁移范围与验证](docs/工程验证.md#board50-migration-2026-10-30)。
