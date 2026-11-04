# FPGA_IDC_2026 — FPGA 模态合成电子乐器

面向 IDC 竞赛、基于 Tang Mega 138K Pro（Gowin）的实时合成项目。HDL 逐采样递推产生声音；录音用于离线提取参数，Python 模型与 RTL 输出用于对拍、标定和试听。

更新：**2026-11-04**。用户已确认**整机联调通过、全部功能测试完毕**，当前交稿版本无未关闭的功能问题。最新保留构建为 `build/chorus_timeout_pipe_ab_20261104/`，PnR/时序验收通过。详见[当前状态](docs/status.md)及[功能验收记录](docs/reports/2026-11-04_整机联调与功能验收.md)。

**阅读入口：**[文档索引](docs/README.md) · [当前状态](docs/status.md) · [问题关闭状态](docs/bugs.md) · [上板测试](docs/上板测试.md) · [赛题要求](reference_agent_readfirst/competition_requements_most_important.md)。

## 系统与目录

统一板级入口为 `instrument_board_top`。PAD/MIDI 经统一路由驱动 16 个声部，PCM 经过 FIFO 输出到 I2S/PT8211；显示通过独立 PCM FIFO 获取 FFT、波形和极坐标数据。核心 50 MHz、音频 12.5 MHz、像素约 33.333 MHz；实际采样率为 48.828125 kHz。

生产资源包含 12 种乐器、358 个有效音/鼓资源，资源掩码 `0xFFF`。当前版本已完成整机功能联调与验收，资源与构建信息见[当前状态](docs/status.md)。

| 目录 | 用途 |
| --- | --- |
| `rtl/platform/tang_mega_138k_pro/` | 板级入口、生产源清单、时钟/复位、引脚/约束、构建与验收 |
| `rtl/router/`、`rtl/midi/` | 合成引擎、资源装载、演奏状态及配置后端 |
| `rtl/audio/`、`rtl/drivers/`、`rtl/comm/` | 音频输出、压力/摇杆/灯光、串口/蓝牙及协议 |
| `rtl_FFT/` | FFT、LCD、波形与极坐标显示模块及独立仿真 |
| `sim/`、`tests/` | 模块、系统及整数模型验证入口 |
| `python_monotor/` | ENG0矩阵与ENG1 ABC两种合成引擎的Python模拟、参数提取和结果数据 |
| `music_resources/` | 离线提取和本地试听使用的录音素材 |
| `web/midi-editor/` | 多轨 MIDI 编辑、采样试听及 Web Serial 上位机 |
| `ePiano_config/` | 鸿蒙配置应用及串口模拟器 |
| `docs/` | 当前状态、接口合同、报告、产品资料和调试记录 |
| `reference_agent_readfirst/` | 赛题及平台参考资料 |
| `build/` | 仅保留最新一次构建的位流、报告、源码快照与输入指纹；Git 忽略 |

## 两种合成引擎的 Python 模拟

[python_monotor/](python_monotor/README.md) 统一保存两种引擎的离线模拟与配套数据：

| 目录 | 对应引擎或用途 |
| --- | --- |
| `matrix_sim/` | **ENG0：矩阵状态空间引擎**，包含钢琴/吉他模拟、系数生成与 `synthlab` 实验库 |
| `modal_sim/` | **ENG1：ABC二阶递推引擎**，包含Q24整数参考、激励/包络/调制/后级模拟及RTL对拍；另保留共用和历史实验模型 |
| `fft_analysis/` | 录音频谱分析与参数提取，为两种引擎提供离线数据 |
| `results/` | 系数参数、图表、仿真数据和试听输出 |

这里的两种引擎是板端ENG0/ENG1的两种计算结构；音色的A/B/C分类另指激励与发声方式。它们是离线模拟工具，实际板端实现位于 `rtl/`。

## 本地上位机

Node.js 20+，无需安装依赖。在仓库根目录执行：

```bash
npm --prefix web/midi-editor run dev
```

在 Chrome/Edge 打开 `http://127.0.0.1:5173`。电脑试听使用本地录音采样；重建采样执行 `npm --prefix web/midi-editor run build:samples`，需要 Python 3 和 libsndfile。详见 [Web 采样演奏与键位配置](docs/web采样演奏.md)。

板端有线 UART 使用 **115200 8N1**，蓝牙使用 **9600 8N1**，均为 v1 协议。录制回传的是演奏事件，PCM/WAV 回传尚未实现。自定义键位、结果码及录制格式见[通信协议](docs/contracts/通信协议约定.md)。

## 构建与验证

板级构建入口为 `rtl/platform/tang_mega_138k_pro/build.tcl`，生产源清单为同目录 `sources.f`，引脚见[板级引脚](docs/contracts/板级引脚.md)。构建依赖 Gowin 工具；RTL 仿真依赖相应运行器支持的 Questa、Verilator 等环境。

```bash
python3 rtl/platform/tang_mega_138k_pro/check_board.py
python3 sim/run_control_loop.py
python3 sim/run_comm.py
python3 sim/run_router_midi.py
python3 sim/run_audio.py
python3 sim/run_flash_ref.py
python3 sim/run_board.py
npm --prefix web/midi-editor test
```

这些是验证入口，运行后会生成新的本地产物；既有验证结果见[报告索引](docs/reports/README.md)。离线模拟依赖 `python_monotor/requirements.txt`；运行入口与数据流见[两种引擎模拟说明](python_monotor/README.md)。

## 交稿目录约定

说明文档集中在 `docs/`，赛题资料保留在 `reference_agent_readfirst/`。`history/`、各处 `archive/` 和生成缓存已清理，历史材料通过 Git 查阅。报告中的旧构建路径保留为当时的证据位置；本地仅保留最新构建。系数、录音、许可证、资源清单及最新构建的验收证据按原用途保留。
