# 真实Gowin时序：父会话独立审查与修复分配

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

**继续收敛的最新状态：**v4保留v1元数据功能修复，仅将lane两处常数地址乘法改为显式窄位移位/加法。父独立34项RTL、60组地址矩阵及生产真实网表两个启动/reset的34帧黄金均通过；真实P&R setup0、Fmax100.007MHz、最坏+0.001ns。仍有TX FIFO第一同步级跨域hold2（最坏−0.160ns）和MPW−0.612ns，未放行。约束/source latency保持原模型；精确CDC审核和额外全模态bank综合网表回归在进行。详见[配置地址时序验收](song_control_timing_review.md)。下方v1–v3“不交付”结论仍作为各历史候选事实保留，不覆盖v4结果。

**v5进一步结果：**经独立确认的11个异步第一级D端口追加hold-only模型例外，未切第二级或setup/max_delay；真实重建setup0/hold0、Fmax100.007MHz/+0.001ns，两向传播界实际setup路径保留，精确CDC门槛通过。MPW仍−0.612ns，严格完整报告门槛继续拒收（仅剩负MPW项）。不称物理hold修复、PLL/PVT签核或可下载放行；详见同一[最新验收](song_control_timing_review.md)。

**2026-10-07功能证据更新：**原core100歌曲综合网表已复现装载记账错误、首帧永久等待。下方旧RTL整链/箱体网表结果仍仅是各自测试范围的历史证据，不能证明原歌曲网表功能等价。用户已授权最小元数据实现修复；v1、v2的RTL与真实网表功能均通过，但真实P&R分别为setup186/hold0、97.329MHz，以及setup623/hold2、91.346MHz；v3 RTL通过，但P&R进一步退化为setup2652/hold0、72.940MHz，网表夹具因端口变化停止未执行。**最终撤回本轮v2/v3优化，只保留v1最小功能修复，100MHz物理仍未闭环，不交付下载文件。**未扩散改冻结lane。完整证据见[歌曲元数据修复验收](song_metadata_fix_review.md)。未覆盖模型的MPW/PLL审核OPEN状态不因功能修复消失。

**2026-10-05用户确认先冻结、核对时钟并准备接线：**已保存39个生产输入/独立工具快照，停止进一步RTL优化；PLL/IP/SDC频率及CST核对一致，结构preflight退出0，未构建新模型/未烧录。快照、SHA及核对边界见[`demo_freeze_20261005.md`](demo_freeze_20261005.md)。接线依据Dock sheet17重新核对，见[`platform/tang_mega_138k_pro/MAX98357A_WIRING.md`](../../../../rtl/platform/tang_mega_138k_pro/MAX98357A_WIRING.md)。“冻结/准备接线”不表示MPW或实板已通过。

## 恢复后的最新验收（优先于下方暂停历史）

### 最新PLL延时候选：父会话拒收（不撤销已通过的核心功能/周期验收）

DS后续仅修改SDC，候选`a7316e0c…bf2e`用`set_clock_latency -source 3.765`同时覆盖core/audio两个PLL。真实候选报告确有setup/hold0/0、Fmax100.009MHz、最坏setup+0.001ns、Recovery+2.991/Removal+0.365、MPW+2.117ns，但**模型合法性未获独立证明，不算MPW闭环或整机放行**。

父会话亲读原始`SUG940-2.0.5E` §4.2.4（49页）与§5.2.3（60–61页），文档说明MPW计算及`set_clock_latency`的语法/early-late语义，**没有**允许把器件真实source min/max取平均值来消共路径悲观。`CLKOUT0_DT_STEP=0`仅nominal50% duty，不证明两edge insertion严格相等/无duty distortion/jitter；两个不同PLL也不能被假定具有相同PVT相位误差。原报告Clock Summary/路径数不变不代表时序模型未削弱。

真实候选`MPW1:4872–4895`显示RR与FF的PLL `tCL`都变为3.765ns，下游`3.564/1.582ns` route未变，因此3.017ns width为该名义模型下的结果，不是实测硬件高电平或经过厂商证明的PVT极值。原始报告SHA=`5e30247650d1f7aea222a881287ad2f4159db6ea8b7f0e919a0a1b880b88b413`。父会话归档`/tmp/opencode/core100-review/rejected-latency-model/{candidate.sdc,reports/}`；实际报告门槛与pin certificate均**退出1拒收**，日志同目录`report-gate.log`/`pin-gate.log`。pin门槛原本就拒绝未经审核的latency override，未为本候选放宽；报告门槛新增相同防护，夹具最新**18/18、23/23通过**。

父会话仅移除本轮agent新增的两条未证明source-latency覆盖及其不成立的说明，**保留准确的专用reset链全部CLEAR注释、7条既有hold例外及全部核心实现**；无用户工作回退。已逐项核对当前SDC的有效命令与亲跑core100冻结基线**完全一致**（源码注释更新，所以SHA不同），不为注释变更重新浪费一轮syn/PnR。当前脉宽判断仍以未覆盖模型的**−0.514ns/OPEN**为准，不能套用候选+2.117ns。DS最后单位改为全repo只读查适用器件的guaranteed duty/jitter/厂商建模或CPPR规则；没有依据就记录vendor/part阻塞，不随机改数字或降频。

**2026-10-05补充公开原文：**本机缺失的DS1239已父会话从公开vendor CDN实际取得并亲读，PDF为1.0.3E/2025-10-24（不同于官网目录日期）；Table3-18 printed44–45页提供PCLK≥100MHz period/cycle jitter<400ps、PLL duty precision<50mUI，带integer-divider/低抖动输入/clocktree caveat。DS只读复核一致。可形成条件MPW预算，但测量点/ES/B/组合规则/实物条件尚未确认，不能恢复midpoint覆盖或放行。另亲读最坏core setup路径无额外tUnc，+0.002ns不默认覆盖PLL动态jitter；若需要额外400ps，裕量约−0.398ns，是否/如何加入需有依据的clock-model审查，不提前声称满足。完整原文SHA、条件预算及待确认清单见[`clock_model_review.md`](clock_model_review.md)。两个DS任务已结束，无后台继续构建/烧录。

**核心控制优化已实际实现并由父会话独立复验；完整100MHz构建的setup/hold已亲跑闭环，但clock minimum pulse width仍失败，不放行烧录。** 不再将当前工作区称为此前VSELECT半成品；两处补齐、engine候选PREP和等价最低missing预检已经完成。

- 冻结SHA：lane=`bad892593e965e85ebbc811550d4cca0b8cc37ee3eca57f1cee6f9e453cf5b75`，bank=`0a812b8c5b135e13899e90dcc59b50473575d75dbc7c5a556e75ecda8f9cd907`，engine=`1834637cd746df125598f05ae018a9d6a3856618e342854c5019f9a7df6a6e9a`，body仍`00d8e13d…9456`。`/tmp/opencode/core100-review/parent_source_snapshot/sources.json`记录完整输入，clock/platform是MPW修复前的冻结版本。
- 实际实现：lane复用原write_en的registered pending值累加ps/sat；bank每voice VSELECT捕获run_n/run_x/voice，合法PREP才写operational payload；engine同样候选scratch→合法E_PREP→E_DRIVE；bank按每voice最低未配置mode比较n，cfg edge从实际bitmap+本次写入同时更新，保留任意顺序配置语义。
- 父会话满载bank/engine SKIP0/1各3/3，共**12/12通过**：bank1536饱和/150帧117504 commits最大**1506周期**；engine113帧163776 commits最大**1508周期≤1800**。独立测试另新增逆序、隔位、随机cfg顺序，逐写入重建黄金prefix，检查同cfg后下一edge拒绝空洞/最后cfg立即合法、重配与clear保系数；全部通过，不依赖DUT函数构造黄金。
- 父会话RAM no-change/read-first模板矩阵 **24/24通过**：V/N=1/1、3/7、32/48，各4lane×SKIP0/1，逐cycle输出/commit对拍及写拍rdata hold。此证据对当前lane控制实现与仅改RAM模板克隆成立，不冒称与旧lane内部partial_sum更新相位逐cycle一致。
- 板级真实engine/body512样本及坏装载静音 **2/2通过**，最长1066周期；生产wrapper默认参数/路径首256样本 **1/1通过**；数字reset相位 **1/1通过**（24扰动/六链1489524边沿），不模拟亚稳态/物理PLL。XML在`parent-board-body/{real,reject}/results.xml`、`parent-production/{real,reset-phases}/results.xml`。
- **父会话亲跑真实完整Gowin syn+pnr退出0**，报告`/tmp/opencode/core100-review/build/parent_core100/impl/pnr/parent_core100.tr`：core100MHz/audio12.5MHz目标正确、setup/hold **0/0**、Fmax **100.024MHz**、最坏setup **+0.002ns**，与DS独立构建关键STA一致。实际PnR资源11427logic/7422FF/**0 latch**、56BSRAM(16SPX9/6SDPB/34pROM)、15DSP(2MULT12X12/7MULT27X36)；不把综合阶段11346logic冒称PnR值。真实ROM/四lane/完整body保留，无EX3988/EX2420/EX3101，普通body recovery/removal仍分析为正。
- **剩余clock MPW最坏−0.514ns**（required0.9/actual0.386），不能称“完整STA通过”。原始报告byte-for-byte归档于`/tmp/opencode/core100-review/reports/`，报告门槛与pin certificate均父会话实际退出1拒收，日志`report-gate.log`/`pin-gate.log`。0.002ns setup余量很薄，clock物理修复后必须再验全部STA，不能沿用这个布局结论。
- 新核心4096样本bodyON/12.5MHz独立长链已**完成并亲验非空XML 1/1通过**：257事件/4097外部帧，1启动欠载/0稳定欠载、0正常body饱和/overflow/deadline，最长modal+body **1072周期**；66903次DIN/WS变化仅在BCLK falling，前后rising名义至少160ns。证据`/tmp/opencode/core100-review/parent-chain12m5/results.xml`。独立XML汇总33份/41例无failure/error/skipped（含12bank/engine、24RAM、1chain及4board/reset），不把初始启动静音欠载说成稳定丢样。
- 父会话另用上述冻结源列表跑**未修改的正式默认32×48 bank9/9、engine7/7**，均退出0；XML在`parent-formal-{bank,engine}/results.xml`。这是父会话亲跑默认满载入口，不沿用DS先前V3/N7小规模正式结果。这里只替换编译输入为快照，不更改测试/黄金/参数或周期门槛。
- 父会话补完**正式参数矩阵36/36**：N=1/7/48×V=1/3/32×SKIP0/1，bank `b02_counts_masks`、engine `e07_digest`每格实际重新编译/亲跑，全部XML无failure/error/skipped，engine九组SKIP0/1 digest均相同；证据`parent-parameter-matrix/{bank,engine}/N*_V*_s*/results.xml`。矩阵是这两个指定testcase覆盖，不冒称36个参数格各跑全部正式suite。
- 独立engine新增严格**同握手/连续拒绝**读回快照检查：候选scratch除外，engine operational/metadata、bank operational及全四lane缓存/有效位均不变；busy低、ready保持、error4当拍。当前冻结32×48 SKIP1 **3/3**、N1/V1 SKIP0 **3/3通过**，证据`parent-engine-strict{,-n1}/review.xml`；没有让“64拍内最终报错”替代原子拒绝合同。
- 父会话与DS分工：DS只修platform合法clocktree/PLL模型及MPW，core/body不再并发改；父会话冻结版功能/链路独立复测。无Programmer/无实板播放，part仍unknown。

日期2026-10-04。**用户要求暂停开发，现收口验收。最新亲读完整工程为84.083MHz版本：冻结副本功能/周期通过，100MHz物理时序仍拒收；当前工作区另含未完成的新流水修改，不能冒称已验收。** ROM缺失与SPX9 read-first写模式已关闭；箱体v3隔离STA及功能仿真通过不能替代整机物理时序。

**随后用户已授权恢复并加快完成：**原DS继续补完VSELECT及pending结果累加优化，父会话并行独立验收；不再对每个失败物理中间版重复4096样本长链，先相关快回归→真实P&R，最终稳定候选才完整矩阵/整链。本节以下暂停验收保留为版本历史，不表示现在仍暂停。

恢复时父会话另发现旧84MHz原报告`Minimum Pulse Width Table:215–224`负裕量，最坏**−0.769ns，actual0.131ns/required0.900ns**，目标loader ROM/lane SPX9 CLK。详细`MPW1:6616–6639`为late rising到达8.947ns、early falling9.078ns之差，不冒称这是已测硬件脉宽，也不能仅凭setup/hold计数0忽略它。已交原DS审查真实clocktree/PLL时序模型并纳入最终物理门槛，禁止关闭检查/伪造波形掩盖。父报告门槛与pin certificate共同加入负MPW拒绝；report gate另拒绝Ignored/Inactive约束。最新夹具**17/17、22/22通过**，旧84MHz报告仍实际非零拒收，日志`/tmp/opencode/core-resume-review/parent84-gate-with-pulse.log`。

为验证小规模快测能及时抓到半成品，父会话对保存的暂停lane/bank副本跑V=3/N=7：完整饱和和变count/历史两例**实际失败**（预期负控制，不算通过）；同参数84MHz已验收副本**3/3通过**。没有改黄金或缩短正式最终验收门槛。证据`/tmp/opencode/core-resume-review/{negative-paused-v3-n7,positive84-v3-n7}/review.xml`。后续可先用这一低成本检查淘汰声部选择/索引错误，再做满载物理与长链验证。

## 本次暂停验收：84.083MHz交付版与工作区分开

验收源快照：`/tmp/opencode/core84-review/delivered84/parent_source_snapshot/sources.json`，lane=`f0f9f998…074d`、engine=`a7eb66c3…46db`、bank=`5a967fe7…f796`、body=`00d8e13d…9456`，SDC=`ef14413c…ff5d`。父会话先亲自复制并逐项核对实现者交付SHA，再用冻结副本重新编译/运行，XML均非空且无failure/error/skipped。

| 父会话亲跑项 | 验收结果 |
|---|---|
| raw bank SKIP0/1，各3例 | **6/6通过**，满载1536饱和、150帧117504 commits，最大**1474周期**；严格同握手拒绝/busy低/连续拒绝无stall，operational寄存器、全部四lane历史有效位及缓存不变 |
| engine SKIP0/1，各3例 | **6/6通过**，113帧163776 commits，最大**1475周期≤1800**；失败load保原声部/晚槽原子拒绝/reset取消 |
| bodyON真实歌曲整链，诊断12.5MHz | **1/1通过**：4096完整64bit原SOS黄金样本、257事件4097外部I2S帧、1启动欠载/0稳定欠载，最长modal+body **1039周期**；66903次DIN/WS变化仅在BCLK falling，前后rising名义至少160ns |
| 真实完整STA | **拒收**：core84.083MHz，setup571/TNS−340.886ns，最坏−1.893ns；hold汇总0，Removal表最坏+0.286ns。有限专用reset CLEAR hold-only例外下普通body recovery/removal仍有分析，不把此项当全部约束/复位安全已完成验收 |

XML：`/tmp/opencode/core84-review/parent-{bank,engine}-skip{0,1}/review.xml`、`parent-chain12m5/results.xml`。真实报告：`rtl/platform/tang_mega_138k_pro/reports/pnr_body_v3_84mhz/timing_report.tr`；父会话实际报告门槛退出1，日志`/tmp/opencode/core84-review/report-gate.log`。本轮**没有**把77MHz版本的24例RAM矩阵/板级wrapper/reset相位结果冒称84MHz新版本已复跑；新的实板或外部certificate同样未通过。

**停止时工作区警告：**DS下一轮未完成交付，当前lane=`bad89259…5b75`、bank=`7a992381…5347`，不同于上述已测SHA。银行加入VSELECT/run_n_r/run_x_r，但`VNEXT`仍跳到VSTART，未完成接入VSELECT；这段不能作为正确多声部版本或可用工程交付。没有对这些半成品做验收，也没有擅自回退/覆盖；用户暂停后不再启动优化或构建。engine/body仍与84MHz快照一致。后续若恢复，先明确处理半成品，再重新验收，不从旧XML继承通过。

冻结数值、II3、100MHz、≤1800、同握手拒绝及失败保状态门槛均不变。没有烧录、实板出声或≥60s稳定性结果；12.5MHz只按诊断口径，part/PMOD方向仍待确认。

## 1. 已亲读的证据

| 真实报告目录（平台reports下） | 物理资源 | STA结果 |
|---|---|---|
| `pnr_timing_fail_prebody/` | 12959 logic、6227 FF、50 BSRAM、10.5 DSP | core100MHz约束，Fmax汇总56.051MHz；setup4235、hold14违例端点 |
| `pnr_body_timing_fail/` | 15394 logic、8787 FF、50 BSRAM、17 DSP | core100MHz约束，Fmax汇总48.729MHz；setup3991、hold10违例端点 |
| `pnr_body_v3_coreopt_77mhz/` | 四lane/16SPX9、系数ROM及body宽DSP保留 | core100MHz约束，Fmax **77.315MHz**；setup2928、汇总hold7，后者实际为7条异步reset **removal** 违例 |

父会话随后亲读已交付`pnr_body_vbr_sdc_c2o/timing_report.tr`并实际门槛拒收：voice-base预计算后core Fmax **59.670MHz**，setup3856、hold6；Clock Summary仍core10ns/audio80ns。最坏`mi→nativeDSP B`数据13.466ns、slack-6.759ns（DSP输入setup也计入预算），另有loader voice→vb_next CE约16.385ns控制链；因此不是只有一个状态有效位组合链。amp_sd/C2O的模型调整不允许掩盖这3856个内部违例。scope stage1跨域hold仍需精确例外与Gray约束证据，不能复制Fast路径冒充Slow或强行通过外部certificate。

父会话已实际读取`timing_report.tr`、资源XML及full-body网表片段。两报告Clock Summary明确core10ns/audio80ns、对象为`u_top/u_clock_reset/u_pll_{core,audio}/u_pll/PLL_inst/CLKOUT0`。这关闭了新增u_top层次后PLL约束对象失配的疑虑，但Clock Summary存在三种clock本身并不证明所有数据路径已约束。

full-body资源XML保留四lane各4 BSRAM、各1 MULT27X36；loader33 BSRAM；body 2393 FF、3 MULT27X36+1 MULT12X12。综合49 BSRAM、P&R50 BSRAM是两个阶段资源口径，不强行写成完全一致。

只读父会话门槛`sim/review_gowin_reports.py`已加入setup/hold及实际clock period检查，对失败报告均实际**退出1拒收**（没有因syn/pnr产出文件而返回成功）。新增`--require-body`检查真实body层次与非空状态/乘法资源，拒绝把prebody网表当含箱体交付；最新又检查Setup/Hold/Recovery/Removal表中的负slack，不能因Hold表全正忽略Removal。合成夹具单测`sim/test_gowin_report_gate_review.py` **15/15通过**，不冒充硬件结果。

## 2. 关键路径不能笼统误称为RAM或主乘法

### body地址DSP→系数选择→宽乘法→104bit加法

`pnr_body_timing_fail/timing_report.tr:96`：`g_body.u_body/n41_s/DOUT[0]→acc_101_s0/D`，19.635ns，slack -9.755ns。

父会话进一步查看真实`build/gowin/audio_board/impl/gwsynthesis/audio_board.vg:217104–217124`：**n41_s是sec×5地址运算的MULT12X12**，不是68×32主乘法。A为两bitsection，B为常数5，AREG启用、OREG绕过。路径再经过tap选择、系数mux、宽主乘法与104bitacc累加，组合链过长。

分配原body实现者：保持系数/68Q34历史/DFI/饱和完全逐位不变，消除动态sec×5地址DSP链，注册operand/product/acc或必要精确部分乘积/加法流水。原25周期是旧实现测值，**验收上限仍128周期**，不是必须坚持25；不能通过降频/减少guard或改舍入逃避时序。原body功能接受的是hash=`b9d4948199963b9c…`的v2，流水新版本须重新亲跑黄金，不自动继承通过结果。

### core常数地址DSP→动态状态有效选择→模态DSP

full-body报告`timing_report.tr:97`：lane3 `n241_s/DOUT[0]→n717_s/B[5]`，16.656ns、slack -9.725ns；prebody同类路径14.219ns、slack -7.482ns。

父会话读网表`audio_board.vg:42433–42489`：n717_s才是26×32模态MULT27X36（输出寄存，输入绕过）；**n241_s是vcur×12地址DSP**（MULT12X12，AREG启用/OREG绕过）。不能未经网表追踪把它称为“缓存读到乘法器”。先优化有限宽常数地址运算/voice base预计算，避免地址DSP与主DSP串联；必要小流水可增加fill/drain，但原数值与单端口缓存保持。

另有`loader.voice_r/load_done→bank x_r/nm_r/mix_acc.CE`约17–19ns控制链。平台/核心实现者负责分段预检/握手控制；必须在全请求验证成功后才写状态/开始计算，失败装载不能损伤旧声部，不能早槽commit后再报晚槽错。目标100MHz、满载bank/engine<=1800周期不变；简单把II3改II4会超过预算，不接受。原2A与原ROM/浮点参考不修改。

## 3. 输出与CDC约束需按真实契约重建

- 最坏汇总setup路径实际是`playback_ready→amp_sd`：full-body绝对arrival17.522ns、required7ns、slack -10.522ns。其中clock insertion8.925ns、数据路径8.596ns。**SD是异步慢配置/关断信号，不是外部100MHz采样接口**；该伪外部每拍约束影响Fmax汇总，不能把48.729MHz完全解释成内部算术极限。应建立实际SD settle/mute延时门槛并覆盖playback_ready/按钮/lock直达路径，不滥用全局false_path。
- BCLK/LRC/DIN在当前audio-reference min=-15ns模型下有约-6.8ns hold flag。它施加的是audio时钟沿后15ns保持，而MAX实际在**forwarded BCLK rising**采样；不能直接当MAX真实hold，也不能删掉flags就宣布外部通过。
- Gowin无virtual clock并不意味着无法给外部边沿证明：RTL正常运行时DIN/LRC在BCLK falling对应的audio边沿变化，前后BCLK rising各距2个80ns周期，即160ns。可对BCLK/DIN/LRC建立完整PVT/双转沿的clock-source→pin最坏delay envelope，再做独立差分：
  `setup >= 160ns + D_bclk_min - D_data_max - board/jitter_margin`
  `hold  >= 160ns + D_data_min - D_bclk_max - board/jitter_margin`。
  例如**若**完整STA证明所有D在0..40ns、另留10ns板skew/jitter，则两个下界均110ns，超过MAX最小10ns；这目前只是建议边界，不是已取得的工具结果。必须列出完整path集合/角值/约束出处并独立检算，复位局部帧保持静音；不能用“缺virtual clock”或“flag少了”代替证明。
- prebody还出现Gray指针到stage1跨域约-0.05ns hold。目标是异步同步器，需要针对真实stage1 endpoint建明确CDC例外，同时保留Gray max-delay/skew门槛和stage1→stage2本域setup/hold；不能把两个clock整个设false_path而覆盖Gray边界。

父会话新增只读`sim/review_i2s_pin_delays.py`：专用实测模式严格拆分原Slow/setup和Fast/hold分析段，三个pin齐全才可按绝对arrival减source launch-edge offset提取D（保留clock insertion/c2q/routes/pad）。**禁止把Fast hold路径复制成Slow setup报告**，同拓扑不代表两个PVT角数值相同。

另提供`--certified-report <原完整STA>`保守上界模式：必须完整STA setup/hold0、实际audio80ns、三pin的max40/min0均为工具Actived、无覆盖输出的额外例外/放宽；才能以required80−40=40及非负slack推导D∈0..40，再独立差分得MAX下界110ns。明确标注**Certified bound NOT measured paths**，不是伪造专用路径，且仍需独立审核路径覆盖/例外/RTL边沿与板skew预算，不能据此单独放行整机。旧时序失败报告已在该入口实际退出1拒收。

最新合成夹具`sim/test_i2s_delay_review.py` **21/21通过**，包括混用快慢角、错误clock、缺pin、忽略约束、全局false-path、内部serializer/stage2切断、负removal及已有STA违例拒绝。数据CDC自动certificate只允许显式hold-only、已知stage1 D目标；独立审核专用reset链之后才可显式`--reviewed-reset-sync-exceptions`承认有限白名单CLEAR例外，结果记录该人工审核声明，它本身不是复位安全证明。普通body/history CLEAR、stage2 D、空集合均拒绝，不放宽Gray setup最大延时或本域stage1→stage2。尚无该入口已接受的真实外部证明。

父会话另实际亲跑nominal引脚边沿检查，冻结v3+lane13e7版本、真实engine/body/I2S、512样本/33事件：8143次DIN/WS变化全部发生在BCLK falling，前后rising至少160ns（12.5MHz），稳定欠载0；`/tmp/opencode/body-review/parent-v3-pin-edge-proof/results.xml`。这验证上述160ns名义关系，**不提供PVT/板skew/jitter实际值**。

## 4. 新增body流水v3独立复验

RTL hash `00d8e13d3d695f14f1b8c709b17c8a923f09968cd737bfcfc77f052ffbcf9456`，端口/所有系数/DFI/68Q34历史及饱和保持。每乘积S_OP/S_MUL/S_ACC三拍，round/clamp/update/final conversion分段，无中间舍入。父会话亲跑四乐器独立各2/2（含4713样本、完整68bit状态、reset新增0..127关键阶段）、正式10/10、拒绝4/4、数值/ROM3/3，实测74核心周期；功能范围接受。证据`/tmp/opencode/body-review/parent-pipeline-v3-*`。

隔离body真实STA父会话已亲读proj3与proj4。proj3仅低3bit输出观察，121.176MHz不能作为完整输出最终裕量；补证proj4观察全部64bit输出/全部sat及握手，通过单100MHz内部STA、setup/hold0/0，**Fmax100.266MHz，最坏setup+0.026ns/hold+0.247ns**。完整输出导致裕量显著收紧，不能只引用较好看的proj3数据。两隔离harness输出引脚未给外部延时约束，故只证明其所保留内部路径；实际PLL、整机布局、适配/FIFO/外部时序仍须全量新构建。报告`/tmp/opencode/body-timing/proj4/body_timing/impl/pnr/body_timing.tr`。

父会话另**亲跑真实Gowin**，冻结同v3 RTL，在`/tmp/opencode/body-parent-timing-v3/`复制完整输出harness，修正其7bit par_ctl XOR到1bit的截断为reduction XOR，未改生产算法。syn/pnr退出0，真实报告setup/hold **0/0**、Fmax **124.787MHz**、setup最坏+1.986ns、hold+0.247ns，1703FF/1689logic/2SDPB/3MULT27X36。这是新harness布局测值，不替代proj4小裕量或完整板最终STA。EX3204(isunknown仿真保护不支持综合)与PR1014(隔离直接clk generic routing)已明确记录；无ROM警告/工具error。Qt默认/offscreen启动失败两次保留日志，使用进程环境minimal后成功，没有修改工具安装/license。最终证据`/tmp/opencode/body-parent-timing-v3/build/parent_body/impl/pnr/parent_body.{tr,rpt.txt}`、`flow-minimal-qt.log`。

父会话再用该真实网表+未修改GW5A vendor功能模型对原SOS独立黄金，**1736完整64bit输出/22次section饱和/74周期逐位一致，1/1通过**，包含busy/reset。测试明确不验证隔离harness已constant-fold的clear/coeff_error、不用mock DSP/ROM，不是路由SDF。XML：`/tmp/opencode/body-review/parent-v3-gowin-netlist-fullscale/results.xml`。

v3冻结整机组合（lane=`13e7f6ab…17fe0`）也已父会话亲跑目标48k(ps-rounded)/12.5MHz诊断各4096样本，最长1038周期、稳定欠载0；真实生产wrapper默认参数/路径首256样本引脚补证通过。原SOS黄金、source snapshot与完整结果见[`body_review_report.md`](body_review_report.md)。这些对冻结组合成立，不自动判以后core物理优化版本通过。

同冻结lane13e7版本的bank/engine SKIP0/1父会话各3/3（共12/12）亦亲跑通过；bank满载1536饱和和150帧/117504 commits，1473周期；engine113帧/163776 commits，1474周期，失败load/晚槽错误/reset保持原子契约。XML/源hash在`/tmp/opencode/body-review/parent-v3-frozen-{bank,engine}-skip{0,1}/`，后续核心版本不能自动继承这些结果。

## 5. 77.315MHz版本父会话补验及下一轮边界

父会话独立冻结实际交付hash：lane=`13e7f6ab…17fe0`、engine=`525012d5…cccf`、bank=`5c618d7f…3ccd`、body=`00d8e13d…9456`。初次复制遇到实现者已开始新修改，hash断言及时拒绝；保留该部分捕获，另以先前同hash lane快照及临时engine注释还原重建**精确SHA一致**交付版本（仅TEMP，无生产代码回退）。manifest在`/tmp/opencode/core77-review/delivered77/parent_source_snapshot/sources.json`。

父会话亲跑bank/engine SKIP0/1各3/3，共**12/12通过**；bank1536满载饱和、150帧/117504 commits最大1473周期；engine113帧/163776 commits最大1474周期。bodyON/12.5MHz4096样本原SOS整链**1/1通过**，257事件/4097外部帧、1启动欠载/0稳定欠载、最长1038周期；66903次DIN/WS变化仅在BCLK falling，前后rising至少160ns。证据`/tmp/opencode/core77-review/parent-{bank,engine}-skip{0,1}/review.xml`、`parent-chain12m5/results.xml`。不是全板STA通过，也不自动接受后续core版本。

父会话将独立raw-bank拒绝检查从“96拍内最终报错”收紧为冻结契约：**握手edge立即error、busy=0、三ready不插入stall、operational act/nm/x/acc/state/vcur以及全部四lane state_valid/完整缓存不变**，并连续下一edge再拒绝；未来候选scratch仅允许未提交token，不计作operational有效payload。对上述精确77MHz版本SKIP0/1重新各3/3通过（`parent-bank-strict-reject-skip{0,1}/review.xml`）。这避免新流水以“无commit但延迟报错”蒙混通过父会话入口。

同精确交付SHA下，父会话另亲跑缓存no-change/read-first模板对拍矩阵 **24/24通过**（V/N=1/1、3/7、32/48，各4lane×SKIP0/1），每cycle输出/commit相等，写拍rdata保持，reset覆盖全部流水相位；这是当前lane与其只更换RAM模板的测试克隆等价，不假称任意旧lane控制实现逐cycle等价。XML在`/tmp/opencode/core77-review/lane-matrix/v*-n*-l*-s*/results.xml`。板级真实引擎/body512样本+坏装载静音**2/2**，生产wrapper默认参数首256样本**1/1**，行为PLL不证明物理PLL。

专用数字reset相位补验 **1/1通过**：24次button/core-lock/audio-lock扰动（core/audio边沿前后2ps），实际六条同步链1489524次边沿逐拍核对、异步静音/清token、重新产出后才能使能。注意真实RTL：板级3FF仅由!locked异步清，button组合压低board rst_n并清下游core/transport/FIFO的2FF；不误称button也清板级3FF。XML：`/tmp/opencode/core77-review/parent-reset-phases/reset-phases/results.xml`。该项只验证数字契约，**不模拟亚稳态、MTBF、物理恢复/移除裕量或证明reset例外已合法启用**。

真实STA最坏三类分开修复：
- `bank state→mix_acc.CE`数据12.656ns/slack−2.934ns，以及`nm_vec_r→x_r/nm_r.CE`：precheck与宽payload寄存器enable高扇出，不能把拒绝改成延迟报错；允许仅合法握手后增加PREP周期，先同edge原error/busy拒绝契约，再注册许可驱动真正payload及累加器。
- `lane n1423_s→state_valid.CE`约−2.929ns：原网表n1423_s是**clear/load voice×12地址MULT12X12**（A=sp_load_voice，B=12），不是all_done或主模态DSP。建议编译期static每voice slice decoder替换动态clear slice，避免生成此地址DSP，保持pending write优先级。
- 汇总hold7的具体负slack在`Removal Paths Table:185–191`，源PLL_INIT clk50m锁定状态→专用reset sync CLEAR，最坏−0.709ns；`Hold Paths Table`最坏+0.247ns。只能按实际async-assert/sync-release架构审核专用CLEAR例外，不误切Gray D；保留reset末级→普通body状态/DSP的recovery/removal以及同步链D本域检查，未证明时仍OPEN。

这三个方向已交由原DS继续，禁止降低100MHz、更改II3/数值、牺牲同握手拒绝/失败保状态，满载上限1800不变。新版本待最终交付后父会话重新验收。

## 6. 当前工作归属与验收

body DS负责局部流水、自己的测试/数值/独立临时vendor构建；平台DS负责模态/银行必要物理优化及外部/CDC模型，并保留两套失败证据。两方不同时编辑body。流水完成后合并真实board_top(BODY=1)，父会话再亲跑功能、周期、完整歌曲/I2S、板级真实引擎/箱体引脚与真实构建，独立检查全部资源与STA/外部差分证明。

物理器件仍未确认（AES/B只是provisional目标）。12.5MHz只用于用户允许的48.828125kHz诊断出声，原参数仍48kHz，不称48k保真。**没有烧录、听音或>=60s实板记录。**
