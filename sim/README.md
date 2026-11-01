> 2026-11-01 测试适用性核查：见 [审计与归档清单](TEST_AUDIT_2026-11-01.md)。以下历史通过记录不代表当前工作区全部通过；当前侧栏系统测试已复现 watchdog。

# 仿真、模型与时序入口

更新：2026-10-29。命令均从仓库根目录执行，隔离Questa补测另行注明运行目录；各验证范围分开计数。Python 脚本优先使用 IVERILOG/VVP、PATH，再尝试本机 `~/micromamba/envs/torch312/bin/`。旧 CORE 验证已归档，见下文。

## 最近实现与回归状态（2026-10-29）

当前基线为d93778af加统一板级工作区。持续音色前端和两个演奏顶层I2S接线已恢复，早先缺AUDIO_ENABLE导致的系统展开错误不再是当前阻塞。

| 入口 | 当前范围/记录 |
|---|---|
| python3 sim/run_board.py | 本次重新执行3项全部通过：逐轴摇杆输入、严格800×480扫描、真实UART/UI/PAD/合成/I2S板级系统；仅PLL/ADC/Flash用模型 |
| python3 rtl/platform/tang_mega_138k_pro/check_board.py | 47端口/75份生产源检查通过；加--timing解析现有报告返回失败：setup11717/hold83，不代表重新PnR |
| python3 sim/run_sustain.py | 已有6项及四音色16槽各48000样本长测，见持续前端实施记录；本次不重复长测 |
| python3 sim/run_audio.py | 恢复接线后的8项已有通过记录，旧展开错误仅保留为修复前证据 |
| python3 sim/run_flash_ref.py | 公开vendor模型的loader/音乐5项已有通过记录；Windows入口另验 |
| npm --prefix web/midi-editor test / run check | 本次17项Node测试及语法检查通过，新增sidebars.mjs另过node --check；不含本次浏览器或物理串口验收 |

本次输出在/tmp/fpga-doc-refresh-20261029，详细[文档核对记录](../docs/工程验证.md#doc-refresh-board-2026-10-29)。既有持续前端35项和板级43项功能汇总属于各阶段范围，有重叠项，不能相加成独立用例总数；实际整板时序仍失败，未烧录。下文旧失败均标其执行阶段。

## 2026-10-27 复测结果

| 命令 | 本轮结果 | 日志/边界 |
|---|---|---|
| `python3 sim/run_control_loop.py` | 15/15 PASS | `build/control_loop/`；5 组参数×3 种子，轮询/公平/背压/复位记账 |
| `python3 sim/run_joystick.py` | 26/26 PASS | `build/joystick/`；24 组适配参数与 2 组 ADC 行为模型接线，不含真实 ADC/整套 LED |
| `python3 sim/run_comm.py` | 13/13 PASS | `build/comm/`；通信和 mock 消费者；本轮未重复历史额外 8 种子压力批次 |
| 旧 `check_comm_vectors.py`（已归档） | 历史记录 | 旧版帧向量，不适用于当前协议；见本次审计 |
| `python3 sim/run_ui.py --legacy` | 17/17 PASS | `build/sidebar/`；2 个异步时钟比的侧栏系统、1 个绘制用例、14 项原频谱回归 |
| `python -m pytest -q sim/unit/eng1/test_router_eng1.py` | 33 passed | Python 模型语义；不证明当前 router 选核/时序/资源 |
| `python python/modal_sim/eng1_cosim.py --mode intended` | **66 项，3 项 FAIL** | n_modes=0 的 case 36/52/64 不匹配，其余 63 项一致；详见当前问题 F12 |
| 旧 CORE（已归档） | 历史记录：前 2 项 PASS，第 3 项编译中断 | 见 [归档说明](../history/core_2026-11-01/README.md)，不属于当前回归 |

<a id="questa"></a>

## 2026-10-28 Questa 补测入口

本机 `vsim/vlog` 为 **Questa Altera Starter FPGA Edition-64 2025.2**。原21文件清单编译在 `voice_router.sv` 报14条先使用后声明错误；整合测试使用 `/tmp/fpga-modelsim-review-20261028/voice_router_compat.sv`，仅前移声明和等价CO_SLOT定义，未改算法或仓库RTL。原TB／白盒夹具的DUT初始化需要 `-suppress 7061 -voptargs='-suppress 7061'`；这不是原版已能直接运行的证明。

兼容副本的默认24000点钢琴、4096点ALL16和64次bank独立性检查通过；当前未改模块的腔体1536点逐位一致，包络／调制／eng1及原范围混响测试通过。loader仅在原行为模型内通过，旧激励TB因缺RISE_SH接线及旧波形判据失败，当前激励合同夹具28次检查通过。intended对拍仍有3个零模态失败。

同时复现：eng1输出间隔4166拍（预算2083）、pending切音色提前改变模态数、7个声部帧混合系数版本。常量输出1的变异仍被音乐TB判PASS，所以音乐冒烟不等于音频正确性验收。完整结果及证据包只维护在[Questa补测记录](../docs/工程验证.md#questa-2026-10-28)。

以下命令依赖本机已经建立的**隔离库与夹具**，不是干净clone的一键入口：

```bash
cd /tmp/fpga-modelsim-review-20261028
QSIM_INI="$PWD/modelsim.ini" vsim -c -suppress 7061 \
  -lib "$PWD/work" tb_router_contracts -gCASE_ID=0 \
  -voptargs='-suppress 7061' -do 'run -all; quit -f'
# CASE_ID: 0=等待切音色，1=eng1预算，2=调制版本，3=bank独立性
```

同一隔离库的音乐用例可将top换成 `tb_music`：默认参数为24000点；16键补测使用 `-gALL16=1 -gNSAMP=4096 -gHOLD=1500`。运行目录须包含由当前回归入口生成的私有 Flash 模型镜像，输出在该目录的 `_analysis/`，避免覆盖仓库已有音频。

`verified_results.json` 保留完整命令、日志路径和显式判定。SV打印FAIL后仍可能进程返回0，必须检查RESULT／工具错误；原始模块探针另按观察值与期望比较。临时脚本／库不随Git分发，异机复核需从补测记录取得冻结证据包后重建。当前 `eng1_cosim.py` 和已有Python runner仍使用Icarus，本次没有修改它们来支持Questa。

## MIDI演奏状态层（2026-10-28）

```bash
python3 sim/run_midi.py
```

两组自检：`tb_midi_note_state`检查归属、力度、踏板、清理和有序操作握手；`tb_midi_note_pipeline`连接真实MIDI parser和延迟模拟消费者，检查同帧快速On/Off不会丢失。日志与results.json默认写入build/midi，可用`--out`指定目录；脚本检查退出码、PASS以及FAIL/FATAL，编译/运行失败返回非零。

本轮Icarus两组通过（状态层663次断言、管线2项操作）；Questa 2025.2隔离库复核同两组通过，编译0错误/0警告，日志在`/tmp/fpga-midi-step31-20261028/`。脚本本身使用Icarus，Questa复核不依赖修改源码或屏蔽警告。另有4项既有通信回归通过。范围与待接部分见[MIDI状态层](../docs/MIDI接入.md#note-state-step31)；尚未连接真实主引擎，不能据此判断声音、压力映射或硬清音通过。

## MIDI接入真实router（3.2，2026-10-28）

```bash
python3 sim/run_router_midi.py
# 可指定完整Questa配置与隔离输出目录：
python3 sim/run_router_midi.py --ini /absolute/path/modelsim.ini --out /tmp/router_midi
```

脚本使用本机vlib/vlog/vsim，将完整ini复制到输出目录并绑定私有work库；默认配置来自QSIM_INI、MODELSIM或本机`~/gowin/simlib_questa/modelsim.ini`。运行`tb_midi_instrument_map`、`tb_performance_input_mux`、`tb_router_midi`、`tb_router_midi_eng1`、`tb_router_pending_config`、`tb_loader_offsets`、`tb_loader_timeout`、`tb_midi_safety`及联合配置新增的`tb_joint_config`、`tb_config_joint_result`、`tb_pad_load_failure`，以及引导模式的`tb_midi_guide_state`、`tb_midi_guide`，共13项。默认日志/results.json在`build/router_midi`；错误、超时、FAIL/FATAL或缺少PASS都返回失败，不保留上次results.json冒充新结果。

真实router测试包含原激励/包络、eng0/eng1、状态RAM与后级；声学用例由测试force读返回总线提供合成系数；当前独立Flash模型实际加载系数RAM，另有16槽/32资源音高的loader与安全用例，不代表真Flash/正式音色资源通过。源清单直接编译；3.2阶段为0错误/6条端口kind默认值警告，当前完整UI清单仍有端口kind警告但0错误；没有7061抑制或临时兼容RTL。eng1增加43帧两bank混音比较，防止B结果有效拍后丢失。详细端口、六通道映射和证据范围见[3.2接入说明](../docs/MIDI接入.md#router-midi-step32)。

压力垫历史音乐TB最终版本与修改前各256点逐点一致；此项单独使用旧TB所需的7061选项，不与正式回归的严格编译混计。没有本轮PnR、48k满规模或I2S结论。

## 控制、侧栏、摇杆

`control_loop` 独立测试仅编译 loop 和 TB，不依赖通信/router/UI；集成到 `sidebar_system` 后以 64 bit 请求、两来源运行。业务生效/结果由 config_dispatch 和消费者确认，不能由来源握手推出。

`run_ui.py` 不带 `--legacy` 仅跑 3 组侧栏测试；带该选项追加 14 项可视化，**17 已包含 14**。日志含编译警告；通过不等于无警告。像素图 `sidebar.ppm` 与 `sidebar.ppm.dropdown.ppm` 的侧栏来自 RTL，底图是测试图形。

摇杆测试覆盖校准、八方向、死区/迟滞、换轴/反向、连发、背压、超时和 X/Y 成对出口。侧栏已接适配器，独立 LCD demo 仍是 HAS_JOYSTICK=0，真实 ADC/矩阵逐键位置和板级方向仍待验证。

接口见 [loop](../docs/控制设计.md#control-loop)、[摇杆](../rtl/drivers/JOYSTICK_ADAPTER.md)、[侧栏接线](../docs/控制设计.md#integration)。

## router 和整数模型

旧 Windows xsim `run_all/run_guitar/run_loader` 入口已删除。当前 Python 回归共享 `sim/router_sources.list` 中的源文件清单，不再从旧 PowerShell 脚本抽取路径。vendor Flash 回归由 `sim/run_flash_ref.py` 在隔离目录生成 MEM 输入；完整 router 使用当前资源镜像。

Python 回归和 eng1 对拍可在已有数值环境运行：

```bash
export PATH="$HOME/micromamba/envs/torch312/bin:$PATH"
python -m pytest -q sim/unit/eng1/test_router_eng1.py
python python/modal_sim/eng1_cosim.py --mode intended
```

`eng1_cosim.py` 默认仍是复刻旧 F05 的 rtl 模式，帮助文字也未同步。当前eng1已为五级流水，空作业修复由新oracle复测通过；旧TB依赖串行核内部接口，仅传intended不足以把它变为当前回归。历史向量模式比较仍应显式intended。对拍输出 `build/eng1_cosim/cases.txt` 与可执行文件，不能将 `$finish`/进程退出 0 当成功，应查看 `RESULT`。契约和模型/RTL 差异见 [ENG1 模型](../docs/ENG1模型.md)。

## 已归档 CORE 验证

旧 CORE、单元测试、run_core.sh 和共享 RAM 综合探针已整体移至 [history/core_2026-11-01](../history/core_2026-11-01/README.md)。仅保留历史参考价值，不再列作当前回归入口；历史 21 项 PASS 不能用于当前 voice_router 验收。原始脚本存在缺失依赖和旧接口，归档不提供一键运行保证。

## 时序与构建

- 通信：`sim/synth/comm_build.tcl` / `sim/check_comm_timing.py`。已有独立探针结果见 [VERIFICATION](../rtl/comm/VERIFICATION.md)；后者会启动构建，本轮未重跑 PnR。
- LCD：`sim/synth/sidebar_build.tcl` 从根目录 source，`BOARD_PNR=1` 执行 PnR；`python3 sim/check_ui_timing.py` **只读已有报告并生成核对摘要**。本轮复核 setup/hold 0/0，最差 +1.448/+0.216ns，约束为 50MHz 控制/33.333MHz 像素；这不是本轮重新构建，也不覆盖音频整机。
- 摇杆：`sim/synth/joystick_build.tcl` 为独立适配器综合，不包含采集整链和 PnR。

27日既有回归见[验证记录](../docs/工程验证.md#verification)；28日Questa补测及隔离新增夹具见[补测记录](../docs/工程验证.md#questa-2026-10-28)。早先文档更新仅记录结果；后续3.2已修改router选源/接线并新增正式回归入口，范围见上节；没有新增PnR／上板结论。

### 两组16音与MIDI安全回归（2026-10-28）

当前`run_comm.py`13项、`run_midi.py`两项及上述Questa八项通过。`tb_loader_offsets`以16槽、32音、非二次幂3模态验证234笔记录写入，覆盖锁存、乱序/重复偏移、mask、地址越界、空表及中止；`tb_loader_timeout`验证有界失败与零填充。测试用`w25q64_read_model.sv`独立解码6Bh的8串行命令+24串行地址+8 dummy，再输出quad数据，不复用DUT头部计数。

`tb_midi_safety`使用真实16槽、32音资源，覆盖控制排空/取消/超时、run=0清理、来源/通道过滤、保持隔离下重载、持音切组、失败不提交active、显式重试和无法推进的清理故障。两组切换有装载停顿，离开当前组的On拒绝，不是32音跨组并发。

镜像打包器默认16音bin/mem与原产物逐字节一致，32音131072B生成/回读通过；测试音域40..71不是正式音域。命令和参数见[当前合同](../docs/MIDI接入.md#midi-bank-fixes)。实施前快照、候选镜像和完整性记录在`/tmp/fpga-midi-fixes-20261028/`，回归日志在`build/midi_fixes/comm_final`、`build/midi_fixes/state`、`build/router_midi`。没有本轮PnR、真片或PCM/I2S验收。

### 联合配置与加载失败回归（2026-10-28）

`python3 sim/run_router_midi.py --out build/joint_config/router`当前运行11项Questa：既有8项加tb_joint_config、tb_config_joint_result和tb_pad_load_failure。可用`--test tb_joint_config`只跑指定用例。脚本增加config_pkg、真实UI依赖及私有字体文件，不使用RTL兼容副本或7061抑制。

- tb_joint_config连接真实sidebar_system、loop/dispatch/mailbox及midi_voice_top，使用16槽、64模态、32音统一步长。两次本地菜单操作实际完成MIDI音色/通道联合切换，另检查通道反查、来源/音区、混响枚举、空表失败、资源能力拒绝、硬panic中止加载、清理超时、显式恢复和在途复位取消。控制域和像素域逐拍检查不存在半个音色/通道对。
- tb_config_joint_result检查错tag、非法联合对、无效资源、失败结果不能更新实际值，成功结果整包提交且反压稳定。
- tb_pad_load_failure例化真实pad_voice_top，验证默认64模态、错误透出、无自动重试/错误音频及显式恢复。tb_router_pending_config使用真实Flash模型，补成功换表状态清零和失败不提交身份。

Flash是独立6Bh行为模型，像素帧脉冲加速；CTRL_HZ也只为UI测试加速轮询，不用于推导真实UI端到端延迟。音频系统时钟在联合用例中真实为100MHz，可从后端接收至成功结果测量模拟装载执行时间。默认RESOURCE_MASK仅钢琴，测试显式启用统一布局的钢琴/吉他资源；不是正式六种音色或真片验收。原UI三项和MIDI状态两项另跑，通过结果分别保留在build/sidebar和build/joint_config/state。无本轮PnR/PCM/I2S结论。

联合配置本次结果：11项Questa全部通过；tb_joint_config为37次检查、17笔后端接收＝16笔最终结果＋1笔复位取消，两笔本地菜单操作完成；错误结果单测7次检查。100MHz/25MHz SCK下，所测成功后端事务最大5392.950μs（约5.39ms），包含清理、64KiB装载和排空；不包含加速的UI轮询/帧等待，也不是实板上界。原UI三项、MIDI状态两项通过。源码快照与完整性记录在`/tmp/fpga-joint-config-20261028/`。

### eng1五级流水与I2S采样基准（2026-10-28至29，先前接线快照）

以下保留先前接线快照的结果。其后曾出现顶层接口缺失，现已由持续前端实施恢复并完成8项音频回归；当前整板阻塞为物理时序，见本页开头。

```bash
python3 sim/run_audio.py --out build/i2s_pipeline/audio_final
python3 sim/run_router_midi.py --out build/i2s_pipeline/router
python3 sim/run_midi.py --out build/i2s_pipeline/state
python3 sim/run_ui.py
```

音频入口使用Questa私有库和生产RTL，无7061警告抑制/声明兼容副本。包含256组Python整数oracle的逐模态状态/和检查（0/1/48/64模态、数量限幅、busy期间输入变化、II=1、复位排空）；PCM端到端检查正负满幅/舍入/饱和、计划静音、缺样和重复结果诊断；6组真实16槽系统集成（MIDI顶层内PAD模式下两引擎×两参考时钟，再测PAD专用顶层的两引擎）。独立I2S解码按WS边沿取期望队列、BCLK采位，核对一位延迟、左右复制和零填充。

每组系统测试连续至少1600个正常合成样本后执行重载、空表失败、恢复、run停启；MIDI顶层配置另切入真实MIDI模式验证A/B两bank的NoteOn、重复NoteOn、CC64延音、NoteOff与CC120清除，实际退休后检查门控；Flash为独立6Bh模型，eng1使用稳定的合成ABC表，不是正式长笛资源。12.5MHz场景覆盖此前约19.5ms漂移欠载时间；12.288MHz模拟准确48k配置，时钟边沿有仿真时间精度量化。所有音频时钟均与100MHz core异步相位。旧eng1_cosim.py/TB仍属历史入口，不替代新增对拍。

结果：音频8项、router/联合配置11项、UI3项、MIDI状态2项，共24项通过。音频结果在build/i2s_pipeline/audio_final/results.json；追加真实MIDI事件验证的6组系统矩阵在build/i2s_pipeline/midi_clocked/results.json。12.5MHz帧间隔2048core拍，12.288MHz为2083/2084拍；正常窗口deadline/overflow/underflow均为0。钢琴64模态最大计算733拍，eng1实际48模态597拍（100MHz分别7.33μs、5.97μs），不等于物理时序收敛证明。详细接线见[rtl/audio](../rtl/audio/README.md)。本次不做panic音频队列flush；无实板/PnR/声学结论。

### 四种eng1持续音色实现回归（2026-10-29）

顶层I2S接线已恢复，本节覆盖此前“缺AUDIO_ENABLE”的工作区基线。正式命令：

```bash
python3 sim/run_sustain.py --out build/sustain/full
python3 sim/run_audio.py --out build/sustain/audio_final
python3 sim/run_router_midi.py --out build/sustain/router_final
python3 sim/run_flash_ref.py --out build/sustain/flash
python3 sim/run_ui.py
python3 sim/run_midi.py --out build/sustain/state_final
QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software   ~/gowin/IDE/bin/gw_sh sim/synth/sustain_build.tcl
```

run_sustain可用--test frontend/config/system选择，--inst 2/3/4/5选音色，--samples设置16槽持音样本数（默认48000）。需要numpy/scipy的资源生成器默认使用本机torch312环境，异机用SUSTAIN_PYTHON指定。Questa沿用QSIM_INI或现有full ini，单项长测超时3600秒，仿真watchdog另外限界；不要把超时当通过。

- frontend：四音色各48000采样，4槽不同周期/力度/包络，独立样本参考共848048次检查。
- config：旧音色持键挂起、候选映射/偏移变化、非法配置不启动Flash、有界失败及显式恢复。
- system：真实生成的32音B表经独立6Bh模型装入16槽×64存储/48计算；逐帧比较冲激、包络及全部模态递推/混音，独立解码I2S。含延音、重触发、释放阻止异来源抢槽、清零后复用、CC120、坏表失败不提交新周期和音区恢复。
- Flash公开模型：独立runner在私有目录准备MEM/状态文件，钢琴64、吉他64、空片及两种音乐冒烟；不改写仓库TB、不直接灌DUT RAM。Windows脚本已同步源依赖、64存储、生成器路径和退出前执行回归；本机没有Windows xsim实际执行结果，Questa入口为本次复现证据。

测试48..79资源显式允许重定音并记录来源，不是正式音域或六音色烧录镜像。生成器/配套配置与部署限制见eng1前端文档。综合探针仅证明代码可综合，不证明100MHz布局布线收敛。


### 整版第一阶段

`python3 sim/run_board.py`运行真实UART→comm→MIDI、实体按键→UI→实际后端、PAD扫描/LED/I2S/LCD及失锁复位；仅PLL、ADC和Flash是模型。独立输入用例覆盖逐轴死区，LCD用例检查严格800×480。`--test inputs|lcd|system|clocks|polyphony|audio|pcm|numeric|led`可选择，`--out`指定私有库/日志。板级生产清单、引脚预检和Gowin构建见[整版入口](../rtl/platform/tang_mega_138k_pro/README.md)。本阶段不接FFT音频数据。

当前时钟域回归新增：clocks检查mailbox八种复位相位/停钟及效果器同步清理；polyphony检查两引擎各16槽供样、释放清零及复用；pcm以624324个参考向量检查PCM舍入/饱和逐位等价；numeric检查配置范围与32bit无符号比较等价；led比较两帧随机GRAM在线端的完整波形。`python3 sim/run_board_pll.py`另用GW5A厂商库运行生产三输出PLL及PLL_INIT，测量100MHz/12.5MHz/33.333MHz与占空比。板级行为模型的PASS不能代替此项或物理时序验收。

## 双声道空间处理

`python3 sim/run_stereo.py`运行5组移位加法空间处理整数参考与8组异步I2S线端回归；`--test unit/bridge`可单选。结果在`build/stereo/results.json`。`python3 sim/run_audio.py --test stereo`运行eng0/eng1和MIDI/PAD四组真实合成动态声像对拍，已纳入该运行器默认矩阵。`python3 sim/run_board.py --test stereo_sweep`验证板级自动扫动实际接线，默认板级矩阵也包含它。Questa需已配置的本机运行环境；运行器不会把编译成功当作仿真成功。

独立无DSP综合脚本为`sim/synth/stereo_build.tcl`，使用显式100MHz时钟约束，并检查实际网表中没有MULT/DSP/PADD原语。综合估算Fmax不等于PnR验收。方案、完整用法与本轮结果见[双声道空间定位方案](../docs/音频设计.md)。

## MIDI引导演奏（2026-10-29）

```bash
python3 sim/run_router_midi.py --out build/guide_router_full
python3 sim/run_ui.py --legacy
python3 sim/run_board.py --out build/guide_board_e2e --test guide
# 隔离整板综合，不覆盖原物理报告：
INSTRUMENT_BUILD_DIR=build/guide_synth QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software ~/gowin/IDE/bin/gw_sh rtl/platform/tang_mega_138k_pro/build.tcl
```

引导状态覆盖16个非连续音高、和弦、80ms余辉、零力度On、重复音、范围、CC及来源清理；集成覆盖真实菜单0503、压力起音、MIDI不发声、串口／蓝牙准入、持键等待、音组切换、加载失败及恢复。`tb_config_joint_result`追加模式快照不一致／非法PAD+guide防护。`tb_guide_render`通过真实mailbox和最终LCD合成器检查全部16格与RGB/DE四拍对齐，截图为`build/sidebar/guide.ppm`、`guide.ppm.sidebar.ppm`。旧两张侧栏golden保持不变；`run_ui.py --legacy`共18项。

板级guide使用同一个tb_instrument_board的GUIDE_TEST=1变体，通过真实UART引脚发送v1 MIDI帧，操作真实按键菜单；ADC模型允许切换cell0压力，Flash使用piano_flash.mem。板级旧system变体仍默认启用原cell0压力。仿真可确认接线／功能，实物键位方向、蓝牙无线延迟及板级PnR另行验收。

## board50显示迁移（2026-10-30）

`python3 sim/run_board.py --test polar --test visualizer`新增两项：四象限CORDIC角度/半径、生产板级PCM抽头的2050样本跨域顺序/饱和、真实FFT非零频谱、观测溢出诊断及复位清队列。独立夹具仅在观测抽头注入测试PCM，整板system/guide用例仍使用真实合成链。私有运行目录会复制board/*.mem，不依赖旧work库中的FFT ROM。

极坐标页替代style2原平面历史绘制；原lcd_curve_spectrum单元保留可独立回归。默认菜单/引导叠加及两张侧栏golden保持，物理时序/听感需另验。完整结果见[迁移验证](../docs/工程验证.md#board50-migration-2026-10-30)。

## ENG1一阶音高调制

使用具备numpy/scipy的Python环境运行`python sim/run_pitch.py`。
`--test unit/phase/system`分别验证438组统一音高轨迹与原子提交、16槽70000采样小数相位、
以及真实P1T1资源的MIDI/I2S整链；默认系统测试为50MHz、16槽12000采样，
可用`--core-hz`和`--samples`选择配置。输出在`build/eng1_pitch/unit`或显式`--out`目录。
`sim/check_pitch_resources.py`检查完整资源目录，`sim/check_pitch_dynamics.py`检查一秒受驱/自由衰减。
生产实现与资源格式见[ENG1一阶音高调制](../docs/ENG1音高.md)。
