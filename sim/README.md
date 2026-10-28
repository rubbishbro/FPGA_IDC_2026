# 仿真、模型与时序入口

更新：2026-10-28。命令均从仓库根目录执行，隔离Questa补测另行注明运行目录；各验证范围分开计数。Python 脚本优先使用 IVERILOG/VVP、PATH，再尝试本机 `~/micromamba/envs/torch312/bin/`；`run_core.sh` 只使用环境变量/PATH。

## 2026-10-27 复测结果

| 命令 | 本轮结果 | 日志/边界 |
|---|---|---|
| `python3 sim/run_control_loop.py` | 15/15 PASS | `build/control_loop/`；5 组参数×3 种子，轮询/公平/背压/复位记账 |
| `python3 sim/run_joystick.py` | 26/26 PASS | `build/joystick/`；24 组适配参数与 2 组 ADC 行为模型接线，不含真实 ADC/整套 LED |
| `python3 sim/run_comm.py` | 13/13 PASS | `build/comm/`；通信和 mock 消费者；本轮未重复历史额外 8 种子压力批次 |
| `python3 sim/check_comm_vectors.py` | PASS | 6 fixtures、CRC29B1、EQ 编码、100 组分片流及错误恢复 |
| `python3 sim/run_ui.py --legacy` | 17/17 PASS | `build/sidebar/`；2 个异步时钟比的侧栏系统、1 个绘制用例、14 项原频谱回归 |
| `python -m pytest -q sim/unit/eng1/test_router_eng1.py` | 33 passed | Python 模型语义；不证明当前 router 选核/时序/资源 |
| `python python/modal_sim/eng1_cosim.py --mode intended` | **66 项，3 项 FAIL** | n_modes=0 的 case 36/52/64 不匹配，其余 63 项一致；详见当前问题 F12 |
| `bash sim/run_core.sh` | **前 2 项 PASS，第 3 项编译中断** | `rtl/simsynth/modal_step_pkg.sv` 已迁移，不能继续宣称当前 21 项全通过 |

<a id="questa"></a>

## 2026-10-28 Questa 补测入口

本机 `vsim/vlog` 为 **Questa Altera Starter FPGA Edition-64 2025.2**。原21文件清单编译在 `voice_router.sv` 报14条先使用后声明错误；整合测试使用 `/tmp/fpga-modelsim-review-20261028/voice_router_compat.sv`，仅前移声明和等价CO_SLOT定义，未改算法或仓库RTL。原TB／白盒夹具的DUT初始化需要 `-suppress 7061 -voptargs='-suppress 7061'`；这不是原版已能直接运行的证明。

兼容副本的默认24000点钢琴、4096点ALL16和64次bank独立性检查通过；当前未改模块的腔体1536点逐位一致，包络／调制／eng1及原范围混响测试通过。loader仅在原行为模型内通过，旧激励TB因缺RISE_SH接线及旧波形判据失败，当前激励合同夹具28次检查通过。intended对拍仍有3个零模态失败。

同时复现：eng1输出间隔4166拍（预算2083）、pending切音色提前改变模态数、7个声部帧混合系数版本。常量输出1的变异仍被音乐TB判PASS，所以音乐冒烟不等于音频正确性验收。完整结果及证据包只维护在[Questa补测记录](../docs/工程评审与验证.md#questa-2026-10-28)。

以下命令依赖本机已经建立的**隔离库与夹具**，不是干净clone的一键入口：

```bash
cd /tmp/fpga-modelsim-review-20261028
QSIM_INI="$PWD/modelsim.ini" vsim -c -suppress 7061 \
  -lib "$PWD/work" tb_router_contracts -gCASE_ID=0 \
  -voptargs='-suppress 7061' -do 'run -all; quit -f'
# CASE_ID: 0=等待切音色，1=eng1预算，2=调制版本，3=bank独立性
```

同一隔离库的音乐用例可将top换成 `tb_music`：默认参数为24000点；16键补测使用 `-gALL16=1 -gNSAMP=4096 -gHOLD=1500`。运行目录须包含 `rtl/router/tools/piano_flash.mem`，输出在该目录的 `_analysis/`，避免覆盖仓库已有音频。

`verified_results.json` 保留完整命令、日志路径和显式判定。SV打印FAIL后仍可能进程返回0，必须检查RESULT／工具错误；原始模块探针另按观察值与期望比较。临时脚本／库不随Git分发，异机复核需从补测记录取得冻结证据包后重建。当前 `eng1_cosim.py` 和已有Python runner仍使用Icarus，本次没有修改它们来支持Questa。

## MIDI演奏状态层（2026-10-28）

```bash
python3 sim/run_midi.py
```

两组自检：`tb_midi_note_state`检查归属、力度、踏板、清理和有序操作握手；`tb_midi_note_pipeline`连接真实MIDI parser和延迟模拟消费者，检查同帧快速On/Off不会丢失。日志与results.json默认写入build/midi，可用`--out`指定目录；脚本检查退出码、PASS以及FAIL/FATAL，编译/运行失败返回非零。

本轮Icarus两组通过（状态层663次断言、管线2项操作）；Questa 2025.2隔离库复核同两组通过，编译0错误/0警告，日志在`/tmp/fpga-midi-step31-20261028/`。脚本本身使用Icarus，Questa复核不依赖修改源码或屏蔽警告。另有4项既有通信回归通过。范围与待接部分见[MIDI状态层](../docs/MIDI演奏与通信接入.md#note-state-step31)；尚未连接真实主引擎，不能据此判断声音、压力映射或硬清音通过。

## MIDI接入真实router（3.2，2026-10-28）

```bash
python3 sim/run_router_midi.py
# 可指定完整Questa配置与隔离输出目录：
python3 sim/run_router_midi.py --ini /absolute/path/modelsim.ini --out /tmp/router_midi
```

脚本使用本机vlib/vlog/vsim，将完整ini复制到输出目录并绑定私有work库；默认配置来自QSIM_INI、MODELSIM或本机`~/gowin/simlib_questa/modelsim.ini`。运行`tb_midi_instrument_map`、`tb_performance_input_mux`、`tb_router_midi`、`tb_router_midi_eng1`、`tb_router_pending_config`、`tb_loader_offsets`、`tb_loader_timeout`、`tb_midi_safety`及联合配置新增的`tb_joint_config`、`tb_config_joint_result`、`tb_pad_load_failure`，当前11项均通过。默认日志/results.json在`build/router_midi`；错误、超时、FAIL/FATAL或缺少PASS都返回失败，不保留上次results.json冒充新结果。

真实router测试包含原激励/包络、eng0/eng1、状态RAM与后级；声学用例由测试force读返回总线提供合成系数；当前独立Flash模型实际加载系数RAM，另有16槽/32资源音高的loader与安全用例，不代表真Flash/正式音色资源通过。源清单直接编译；3.2阶段为0错误/6条端口kind默认值警告，当前完整UI清单仍有端口kind警告但0错误；没有7061抑制或临时兼容RTL。eng1增加43帧两bank混音比较，防止B结果有效拍后丢失。详细端口、六通道映射和证据范围见[3.2接入说明](../docs/MIDI演奏与通信接入.md#router-midi-step32)。

压力垫历史音乐TB最终版本与修改前各256点逐点一致；此项单独使用旧TB所需的7061选项，不与正式回归的严格编译混计。没有本轮PnR、48k满规模或I2S结论。

## 控制、侧栏、摇杆

`control_loop` 独立测试仅编译 loop 和 TB，不依赖通信/router/UI；集成到 `sidebar_system` 后以 64 bit 请求、两来源运行。业务生效/结果由 config_dispatch 和消费者确认，不能由来源握手推出。

`run_ui.py` 不带 `--legacy` 仅跑 3 组侧栏测试；带该选项追加 14 项可视化，**17 已包含 14**。日志含编译警告；通过不等于无警告。像素图 `sidebar.ppm` 与 `sidebar.ppm.dropdown.ppm` 的侧栏来自 RTL，底图是测试图形。

摇杆测试覆盖校准、八方向、死区/迟滞、换轴/反向、连发、背压、超时和 X/Y 成对出口。侧栏已接适配器，独立 LCD demo 仍是 HAS_JOYSTICK=0，真实 ADC/矩阵逐键位置和板级方向仍待验证。

接口见 [loop](../docs/控制与侧栏设计.md#control-loop)、[摇杆](../rtl/drivers/JOYSTICK_ADAPTER.md)、[侧栏接线](../docs/控制与侧栏设计.md#integration)。

## router 和整数模型

当前音乐入口是 `rtl/router/tb/tb_music.sv`，Windows Vivado xsim 一键流程：

```powershell
pwsh -File rtl/router/tools/run_all.ps1
```

脚本默认 Vivado 2017.4 的 Windows 路径，可用 `-Vivado` 指定安装目录；需 Python/numpy。它生成钢琴镜像、逐个编译 22 个文件、仿真并导出 `_analysis/music.wav`。音乐 TB 直接灌 RAM、跳过真实 SPI，帧数/无 X/非零输出不是逐样本 golden。Linux环境仍未运行pwsh/xsim；28日是在上述隔离Questa兼容副本上补跑同一音乐TB，不把镜像格式自检当成真片验收。

Python 回归和 eng1 对拍可在已有数值环境运行：

```bash
export PATH="$HOME/micromamba/envs/torch312/bin:$PATH"
python -m pytest -q sim/unit/eng1/test_router_eng1.py
python python/modal_sim/eng1_cosim.py --mode intended
```

`eng1_cosim.py` 默认仍是复刻旧 F05 的 rtl 模式，帮助文字也未同步。当前 eng1 已改用本模态状态和全模态 st_zero，应显式传 intended；目前零模态边界仍失败。对拍输出 `build/eng1_cosim/cases.txt` 与可执行文件，不能将 `$finish`/进程退出 0 当成功，应查看 `RESULT`。契约和模型/RTL 差异见 [ENG1 模型](../docs/ENG1_PY_MODEL.md)。

## 保留 core 回归

2026-10-22 的 21 项 PASS 是历史范围，当前 `sim/run_core.sh` 在 tb_shared_modal_ram、tb_router_loader 之后失败。缺少的 `modal_step_pkg` 和 `modal_engine7` 不能仅以新文件路径替换，旧 e2_engine 接口也需迁移。旧并行前端测试在 `history/sim/unit/core_legacy/`。

如需复现编译阻塞：

```bash
IVERILOG="$HOME/micromamba/envs/torch312/bin/iverilog" VVP="$HOME/micromamba/envs/torch312/bin/vvp" OUT=/tmp/fpga_docs_core bash sim/run_core.sh
```

该目录是中断日志，不是完整回归结果。

## 时序与构建

- 通信：`sim/synth/comm_build.tcl` / `sim/check_comm_timing.py`。已有独立探针结果见 [VERIFICATION](../rtl/comm/VERIFICATION.md)；后者会启动构建，本轮未重跑 PnR。
- LCD：`sim/synth/sidebar_build.tcl` 从根目录 source，`BOARD_PNR=1` 执行 PnR；`python3 sim/check_ui_timing.py` **只读已有报告并生成核对摘要**。本轮复核 setup/hold 0/0，最差 +1.448/+0.216ns，约束为 50MHz 控制/33.333MHz 像素；这不是本轮重新构建，也不覆盖音频整机。
- 摇杆：`sim/synth/joystick_build.tcl` 为独立适配器综合，不包含采集整链和 PnR。
- core：`sim/synth/gowin_build.tcl` 为保留共享 RAM 探针；router 的 `syn_only.tcl/synth_pnr_router.tcl` 是另一目标。旧 Fmax/资源数均需对照源码/清单/约束及报告日期。

27日既有回归见[验证记录](../docs/工程评审与验证.md#verification)；28日Questa补测及隔离新增夹具见[补测记录](../docs/工程评审与验证.md#questa-2026-10-28)。早先文档更新仅记录结果；后续3.2已修改router选源/接线并新增正式回归入口，范围见上节；没有新增PnR／上板结论。

### 两组16音与MIDI安全回归（2026-10-28）

当前`run_comm.py`13项、`run_midi.py`两项及上述Questa八项通过。`tb_loader_offsets`以16槽、32音、非二次幂3模态验证234笔记录写入，覆盖锁存、乱序/重复偏移、mask、地址越界、空表及中止；`tb_loader_timeout`验证有界失败与零填充。测试用`w25q64_read_model.sv`独立解码6Bh的8串行命令+24串行地址+8 dummy，再输出quad数据，不复用DUT头部计数。

`tb_midi_safety`使用真实16槽、32音资源，覆盖控制排空/取消/超时、run=0清理、来源/通道过滤、保持隔离下重载、持音切组、失败不提交active、显式重试和无法推进的清理故障。两组切换有装载停顿，离开当前组的On拒绝，不是32音跨组并发。

镜像打包器默认16音bin/mem与原产物逐字节一致，32音131072B生成/回读通过；测试音域40..71不是正式音域。命令和参数见[当前合同](../docs/MIDI演奏与通信接入.md#midi-bank-fixes)。实施前快照、候选镜像和完整性记录在`/tmp/fpga-midi-fixes-20261028/`，回归日志在`build/midi_fixes/comm_final`、`build/midi_fixes/state`、`build/router_midi`。没有本轮PnR、真片或PCM/I2S验收。

### 联合配置与加载失败回归（2026-10-28）

`python3 sim/run_router_midi.py --out build/joint_config/router`当前运行11项Questa：既有8项加tb_joint_config、tb_config_joint_result和tb_pad_load_failure。可用`--test tb_joint_config`只跑指定用例。脚本增加config_pkg、真实UI依赖及私有字体文件，不使用RTL兼容副本或7061抑制。

- tb_joint_config连接真实sidebar_system、loop/dispatch/mailbox及midi_voice_top，使用16槽、64模态、32音统一步长。两次本地菜单操作实际完成MIDI音色/通道联合切换，另检查通道反查、来源/音区、混响枚举、空表失败、资源能力拒绝、硬panic中止加载、清理超时、显式恢复和在途复位取消。控制域和像素域逐拍检查不存在半个音色/通道对。
- tb_config_joint_result检查错tag、非法联合对、无效资源、失败结果不能更新实际值，成功结果整包提交且反压稳定。
- tb_pad_load_failure例化真实pad_voice_top，验证默认64模态、错误透出、无自动重试/错误音频及显式恢复。tb_router_pending_config使用真实Flash模型，补成功换表状态清零和失败不提交身份。

Flash是独立6Bh行为模型，像素帧脉冲加速；CTRL_HZ也只为UI测试加速轮询，不用于推导真实UI端到端延迟。音频系统时钟在联合用例中真实为100MHz，可从后端接收至成功结果测量模拟装载执行时间。默认RESOURCE_MASK仅钢琴，测试显式启用统一布局的钢琴/吉他资源；不是正式六种音色或真片验收。原UI三项和MIDI状态两项另跑，通过结果分别保留在build/sidebar和build/joint_config/state。无本轮PnR/PCM/I2S结论。

联合配置本次结果：11项Questa全部通过；tb_joint_config为37次检查、17笔后端接收＝16笔最终结果＋1笔复位取消，两笔本地菜单操作完成；错误结果单测7次检查。100MHz/25MHz SCK下，所测成功后端事务最大5392.950μs（约5.39ms），包含清理、64KiB装载和排空；不包含加速的UI轮询/帧等待，也不是实板上界。原UI三项、MIDI状态两项通过。源码快照与完整性记录在`/tmp/fpga-joint-config-20261028/`。
