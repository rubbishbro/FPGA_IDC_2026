# 共享箱体：父会话独立审查报告

**恢复后的新核心补验：**body v3数值与源码未改；core候选(bank0a812/engine183463/lane bad892)已父会话bank/engine12/12（1506/1508周期）、RAM24/24及真实板级body512样本/生产wrapper/reset补验通过。新core4096样本bodyON/12.5MHz整链已亲验**1/1通过**，257事件/4097帧、1启动欠载/0稳定欠载、最长1072周期，完整64bit原SOS黄金一致；正式默认满载bank9/9、engine7/7亦父会话通过。父会话真实整机Gowin100MHz setup/hold0/0，但clock MPW−0.514ns仍拒收，不能把它列为完整硬件通过。最新证据见[`hardware_timing_review.md`](hardware_timing_review.md)首节；下方暂停与旧版本均为阶段历史。

随后PLL共同名义source-latency候选虽真实报告MPW转正，父会话因缺乏PVT/边沿相关性依据已拒收并移除新增覆盖；箱体不受此模型实验影响，保持只读原hash。MPW仍OPEN，不将名义模型pass套用为实板/完整时序通过。

日期：2026-10-04。**结论：首版guitar歌曲箱体及四乐器单模块功能验证通过；板级箱体综合/P&R/实际听音尚未通过。** 实现者为用户指定DeepSeek V4.1 Flash，验收由父会话亲跑，不把实现者自测代称独立通过。

**用户暂停时验收补充：**最新完整84.083MHz交付版冻结副本已父会话亲跑bodyON/12.5MHz4096样本整链，257事件4097外部帧、0稳定欠载，最长1039周期；bank/engine共12/12、1474/1475周期。物理setup571仍拒收。随后DS未完成的lane/bank修改留在工作区，与该验收SHA不同，绝不能沿用冻结版通过结论；已停开发/构建，具体证据与半成品警告见[`hardware_timing_review.md`](hardware_timing_review.md)开头。body v3本身未改。

**最新v3复验：**流水RTL hash=`00d8e13d3d695f14f1b8c709b17c8a923f09968cd737bfcfc77f052ffbcf9456`。父会话亲跑四乐器独立8/8、正式模块10/10、非法参数/坏ROM拒绝4/4、ROM/数值3/3，均退出0；最大74周期、逐位数值与v2一致，reset覆盖新增0..127关键相位。日志/非空无失败XML在`/tmp/opencode/body-review/parent-pipeline-v3-*`，源hash记录`parent-pipeline-v3-body-hash.json`。**v3单模块及以下冻结版本整机功能接受；完整板STA仍未验收**。旧29例基线保持v2记录，不自动冒称新核心流水最终复测。

隔离Gowin补证父会话已亲读：proj3只观察低3bit，不能采用其121.176MHz裕量作为完整64bit接口证明；按要求proj4保留全64bit输出/全部饱和及握手观测，单clk10ns下setup/hold0/0、Fmax100.266MHz、最坏setup **+0.026ns**、hold+0.247ns。余量很小，且仍非真实PLL/整机布局；须以完整工程新STA为准。详见[`hardware_timing_review.md`](hardware_timing_review.md)。

**父会话真实工具亲跑补证：**在`/tmp/opencode/body-parent-timing-v3/`冻结v3 RTL并复制完整输出harness，仅将观测器`^ par_ctl`改成`^ (^par_ctl)`消除7bit→1bit截断（不改生产RTL/数值）。Gowin syn+pnr实际退出0，core直接100MHz下setup/hold **0/0**、Fmax **124.787MHz**、最坏setup+1.986ns、hold+0.247ns；保留1703FF/1689logic/2SDPB/3MULT27X36。与proj4的差别是不同观测器/布局，不回写为全板裕量。EX3204是原isunknown仿真拒绝保护不支持综合；PR1014是隔离直接clk的generic routing警告，此harness不验证真实PLL全局时钟/输出接口。先前Qt默认与offscreen启动两次失败均留日志，改为进程级QT_QPA_PLATFORM=minimal后跑通，没有改安装或license。最终报告`build/parent_body/impl/pnr/parent_body.tr`及日志`flow-minimal-qt.log`。

## 范围与数值

按用户选择“工程＋箱体”“先闭环guitar”：一乐器全部声部混音共享一组4 biquad；四乐器分别有系数并单测，不做四乐器全局混音共用guitar滤波。原始模态权重与`Patch.sos`只读使用，未更改参考数据来迁就RTL。

参考规格[`body_design.md`](body_design.md)：系数signed32/Q30，输入/输出signed64/Q30，所有section历史/interstage signed68/Q34，单共享**逻辑**68×32乘法路径、100bit产品/104bitacc。每section一次round30/clamp68，末级round4/clamp64，末级输出饱和并入section3，饱和计数最多4。增加4小数保护位是本模块局部修正，不改原2A/2BC格式；理由是piano Q30无保护位的静默残余超过门槛，不能靠自动zero或改浮点参考消除。

噪声支路、note_off/_kill、动态声部分配/回收/抢占及多乐器混奏分组未迁移；补箱体不等于完整原始engine.py迁移。

## v2独立复测历史（新v3补证另列）

以下命令均使用`PATH="$HOME/micromamba/envs/torch312/bin:$PATH"`；构建使用绝对目录、重新编译、Icarus `-g2012/-Wall`，明确解析非空XML并检查失败，实际shell退出均0。没有写`sim/results.xml`。

| 入口 | 亲跑结果 |
|---|---|
| `python sim/test_body_filter_review.py --instrument 0..3 --build-dir /tmp/opencode/body-review/parent-<name>-final` | 四组各2/2，总8/8；每乐器4713样本，输出、每section x1/x2/y1/y2状态及饱和mask/count与独立原SOS黄金逐位一致。 |
| `python sim/test_body_rejection_review.py` | 4/4：instrument=-1、4、缺ROM、短ROM均不承认sample/clear握手、不输出伪造数据、coeff_error明确置位，复位重试仍拒绝。 |
| `python sim/test_body_numeric_review.py` | 3/3：80词ROM由四原SOS逐词重建；manifest格式/原浮点SOS/原FFT body源hash一致；从其他CWD在临时目录重生成两文件字节一致；浮点误差/稳定性/静默残余通过。 |
| `python sim/test_body_filter.py --build-dir /tmp/opencode/body-review/parent-formal-filter` | 正式入口10/10，父会话亲跑并逐XML确认；每乐器9055样本输出/状态一致、最大25周期，另含坏ROM/负instrument拒绝。 |
| `python sim/test_body_model.py` | 正式模型/生成器入口全部检查通过，父会话亲跑退出0；非法系数/非有限/不稳定/短image拒绝且不污染旧输出，guitar真实模态歌曲箱体浮点峰误差4.52e-8、RMS1.68e-8、无饱和。 |
| `python sim/test_audio_chain_review.py --voices 32 --gap 16 --samples 4096 --body --build-dir /tmp/opencode/body-review/parent-chain32-48k-full` | 1/1；原始模态coeff+原始guitar SOS独立黄金，modal mix、完整64bit箱体输出、PCM/FIFO/外部标准I2S逐位核对。 |
| 上一命令加`--diagnostic-12m5`，build=`/tmp/opencode/body-review/parent-chain32-12m5-full` | 1/1；相同黄金序列，实际仿真audio80ns / BCLK320ns / frame20480ns。按用户允许的诊断频率测deadline，不重新拟合48kHz系数。 |

### 单模块边界

每乐器4713样本包含冲激/负冲激、阶跃、交替符号、4096确定随机样本以及signed64全幅饱和压力；不是把输入缩成32bit再测。全部4section状态也是signed68独立比较，不只最终int16输出一致。全幅压力分别观察guitar/piano/banjo/mandolin **1/14/6/11**次section饱和。

**握手至out_valid最大25个核心周期**，小于128周期门槛。busy毒化不影响已接受样本；clear只清历史并保系数；多个计算相位reset取消token且无幽灵输出。拒绝路径测试中故意缺/短ROM导致的`readmemh`诊断是预期负例，不能与真实生产构建发生同样警告却放行混淆。生产综合仍必须把ROM读取失败视为阻塞。

### 歌曲端到端

两个频率版本均：**4096黄金样本、257装载事件、4097外部I2S帧；1启动欠载、0稳定欠载；正常箱体饱和/overflow/deadline/engine error均0**。最长modal+body **989核心周期**，100MHz下9.89us，低于诊断12.5MHz时的2048周期帧预算。

gap16用于多事件/整曲循环和共享箱体历史连续性压力，不代表默认250ms音符间隔整个曲长已用含箱体版本验证，更不是>=60s实板稳定性。48k版本audio周期81380ps，有限仿真精度下Fs=1e12/(81380×256)，约48,000.123Hz；12.5MHz版本精确80000ps、帧率48,828.125Hz。后者仅诊断口径，不称48k保真通过。

## 原SOS浮点误差与稳定性

每乐器1冲激+4096随机±0.5+65536静默，输入量化Q30后对原`scipy.signal.sosfilt`，独立DFI黄金不调用实现者`body_fixed_point.py`。频响为20Hz..20kHz的4000频点量化SOS与原SOS比较；时域舍入误差单独计算。正常幅度无饱和，没有自动zero阈值。

| 乐器 | 峰值误差 | RMS误差 | 尾4096样本残余峰值 | 频响误差上限(dB) | 最大量化极点半径 |
|---|---:|---:|---:|---:|---:|
| guitar | 9.77e-9 | 7.25e-9 | 7.45e-9 | 4.38e-7 | 0.969546531 |
| piano | 7.79e-8 | 5.55e-8 | 5.77e-8 | 1.45e-6 | 0.992041603 |
| banjo | 8.37e-9 | 1.90e-9 | 1.86e-9 | 3.70e-7 | 0.960082354 |
| mandolin | 3.88e-8 | 5.31e-9 | 4.66e-9 | 1.79e-6 | 0.973617688 |

门槛：单位输入峰误差<=1e-5、频响误差<=0.01dB、长静默残余<=2e-7、极点半径<1，均满足。长静默此项是独立整数模型，不冒充65536样本完整RTL长尾测试。表中不包含原模态浮点→2A系数量化误差，不能把该局部误差表说成整个原始算法的浮点误差验收。

## 基线无回退

父会话实际复跑旧ENABLE_BODY=0正式入口：song **5/5**、transport **20/20**、demo **4/4**（共29/29），原2A **14/14**。XML分别在`/tmp/opencode/body-review/parent-baseline-{song,transport,demo}/`及`/tmp/opencode/ram-review/parent-original2a/`，旧tests未修改以迁就本模块。transport/demo每例独立`results_<case>.xml`，已逐文件解析汇总，不误认缺`results.xml`为失败。

## v3完整链与生产wrapper补测

父会话新增`sim/_review_source_snapshot.py`用于独立chain/board入口：先复制编译输入并记SHA，仿真固定使用复制文件，避免实现者并发编辑污染“到底验了哪个版本”。以下版本body=`00d8e13d…9456`、poly_lane=`13e7f6ab…17fe0`、生产wrapper=`201ff045…351d`；核心还在物理优化中，**这些结果只对这一冻结组合成立，不自动接受以后lane版本**。

| v3亲跑项 | 实际结果 |
|---|---|
| `python sim/test_audio_board_review.py --production-wrapper --samples 256 --build-dir /tmp/opencode/body-review/parent-v3-production-wrapper` | **1/1通过**：真实生产`board_top.sv`，不覆盖其中固定32voice/gap12000/bodyON/guitar0及三ROM绝对路径；256黄金样本/1事件/257外部帧，完整body输出/PCM/FIFO/I2S核对，audio-unlock/reset立即静音、重启。test-only行为PLL不证明物理时钟。 |
| `python sim/test_audio_chain_review.py --voices 32 --gap 16 --samples 4096 --body --diagnostic-12m5 --frozen-sources /tmp/opencode/body-review/parent-v3-production-wrapper/parent_source_snapshot --build-dir /tmp/opencode/body-review/parent-v3-frozen-chain32-12m5` | **1/1通过**：4096原模态+原SOS完整64bit黄金样本、257事件/4097外部帧，1启动欠载、0稳定欠载/overflow/deadline/正常body饱和，最长modal+body **1038核心周期**，低于诊断2048周期预算。 |
| 上项去`--diagnostic-12m5`，build=`/tmp/opencode/body-review/parent-v3-frozen-chain32-48k` | **1/1通过**：相同4096黄金序列、257事件/4097帧，1启动欠载/0稳定欠载，最长1038周期；目标48k ps-rounded时钟，不冒称已有12.288MHz有效硬件构建。 |
| 新生产body结构/拒绝门槛`python sim/test_audio_board_preflight_review.py` | **13/13通过**，新增80词ROM缺词/33bit溢出、生产BODY关闭、错instrument、body绝对路径与本fixture不符拒绝；只用临时合成PLL，不能据此验收STA/合法PLL/系数语义。 |
| 同冻结lane13e7：独立bank/engine SKIP0/1 | 各**3/3（共12/12）通过**，bank满载1536饱和/150帧117504 commits最大1473周期，engine113帧163776 commits最大1474周期，原子拒绝/失败load保旧声部/reset均通过。XML及SHA：`/tmp/opencode/body-review/parent-v3-frozen-{bank,engine}-skip{0,1}/`。 |
| 独立nominal I2S边沿检查：chain相同冻结源、bodyON/12.5MHz、512样本 | **1/1通过**：8143次DIN/WS变化全部在BCLK falling同仿真时刻，前后sampling rising间隔至少160ns。此项证明RTL边沿关系，不含PVT引脚延时、板skew或jitter。XML：`/tmp/opencode/body-review/parent-v3-pin-edge-proof/results.xml`。 |

XML在对应build的`results.xml`（board为`real/results.xml`），源快照manifest为`parent_source_snapshot/sources.json`。gap16覆盖重装/整曲多轮，生产wrapper只补固定默认参数/路径与首事件，不冒称整个默认10.5秒曲长或>=60s实板稳定性。

### 随后77.315MHz整机报告对应版本（独立冻结补验）

lane同`13e7f6ab…17fe0`，engine更新为`525012d5…cccf`、bank=`5c618d7f…3ccd`，不能只看lane/body hash就将此前结果混称此版本。父会话已在`/tmp/opencode/core77-review/delivered77/parent_source_snapshot/`核对精确SHA：bank/engine SKIP0/1共12/12（1473/1474周期）、RAM模板等价矩阵24/24、bodyON诊断整链4096样本1/1（最长1038周期/0稳定欠载）、真实板级body512样本及坏装载2/2、生产wrapper首256样本1/1通过。4096样本边沿监测66903次DIN/WS变化仅在BCLK falling，名义前后rising160ns。

该冻结版本的六条数字reset链另1489524次边沿核对，24个button/core-lock/audio-lock相位扰动，通过即时静音/复位取消/重新产出使能；不模拟亚稳态或提供物理MTBF。证据与精确路径在[`hardware_timing_review.md`](hardware_timing_review.md)第5节。**上述仅功能接受；真实报告仍setup2928、汇总hold7（实际7条removal）违例，物理时序拒收。**

### v3真实综合网表数值补证

父会话亲跑`python sim/test_body_netlist_review.py --netlist /tmp/opencode/body-parent-timing-v3/build/parent_body/impl/gwsynthesis/parent_body.vg --build-dir /tmp/opencode/body-review/parent-v3-gowin-netlist-fullscale`，**1/1通过、退出0**，1736个完整signed64输出逐位一致、22次section饱和、最大74周期。直接用真实Gowin网表及安装内未修改GW5A `prim_sim.v`，不换mock DSP/ROM，不回退RTL；黄金是父会话原SOS DFI。检查sat mask/count、busy毒化、多个流水相位reset、实际20词系数ROM/SDPB与宽DSP映射。

该网表来自guitar隔离harness，工具把端口改名并将原clear=0条件常量传播；测试专用adapter按**实际网表连接**恢复端口（reset反相、in_ready与clear_ready等同、coeff_error常量0），并明确排除clear/坏ROM拒绝的网表验收，不能把优化掉的功能虚构成验证通过。原RTL的clear/错误拒绝由上述独立单模块测试覆盖。先前的VG扩展名语言标签及原端口名接线编译失败已经修正测试adapter，未改生产RTL/网表/工具库来迁就黄金。

vendor原库有6条implicit-wire语法诊断（未参与此body实例的IO/PLL等模型解析），完整保留日志，没有消音或修改库。此项是**零延时功能网表仿真，不是P&R/SDF动态时序或完整板级网表仿真**。

## v2证据历史与剩余验收

- 单模块XML：`/tmp/opencode/body-review/parent-{guitar,piano,banjo,mandolin}-final/results.xml`。
- 拒绝路径XML：`/tmp/opencode/body-review/parent-rejection/<negative-instrument|high-instrument|missing-image|short-image>/results.xml`。
- 两时钟完整链XML：`/tmp/opencode/body-review/parent-chain32-{48k,12m5}-full/results.xml`。
- 日志：`/tmp/opencode/body-review-parent-*.log`（数值完整入口为`body-review-parent-numeric-all.log`）。
- 已审查源码hash：`/tmp/opencode/body-review/parent-reviewed-source-hashes.json`；body_filter=`b9d4948199963b9c…`、audio_demo_core=`909699939b0f1290…`、body ROM=`64920ba53a4f73a0…`、manifest=`77d360a3afe2debd…`，与DS最终交付版本核对一致。

实现者正式完整报告[`body_delivery_report.md`](body_delivery_report.md)已交付，父会话核对上述关键hash并亲跑正式模块/模型入口，功能范围接受。该报告的自测数值与本报告独立随机序列不同，不强行合并误差数值。父会话已授权DS下一轮platform正确传递ENABLE_BODY/BODY_FILE并在生产wrapper开启guitar BODY；先保留pre-body基线，再独立重跑含箱体的真实ROM/箱体/DSP与setup/hold/未约束检查，目前此硬件结果尚未交付接受。完整实板part与接线确认后才能决定烧录。**不以当前旧provisional bitstream充当含箱体、可用或48k保真文件；本轮未调用Programmer。**
