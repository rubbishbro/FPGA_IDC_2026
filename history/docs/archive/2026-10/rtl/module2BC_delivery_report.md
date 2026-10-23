# 模块2B/2C与音频首阶段交付报告

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期2026-10-04。**当前状态：箱体流水v3独立功能/冻结整机4096样本及隔离Gowin100MHz已亲跑通过，含真实DSP/ROM网表数值补证。完整工程真实ROM与no-change缓存映射已修复，但此前整机P&R均未满足100MHz，父会话独立拒收；核心地址/控制链物理优化仍在进行，最终整机与外部时序尚未放行。尚无可用于实板验收的烧录文件或出声结果。**

**用户暂停后的最新验收收口：**84.083MHz交付SHA的冻结副本已父会话亲跑bank/engine SKIP0/1共12/12，最大1474/1475周期；箱体ON/12.5MHz诊断4096黄金样本整链1/1、0稳定欠载，最长1039周期。完整STA仍setup571、最坏−1.893ns，虽hold/removal0仍拒收，不能烧录。DS后续仅改到一半，工作区lane/bank已不同于验收SHA，VSELECT的VNEXT接入尚未完成；保留但明确未验收，不擅自回退。已暂停新开发/构建，详细SHA、XML与工作区警告见[`hardware_timing_review.md`](hardware_timing_review.md)开头。本轮不复用旧版本测试为当前半成品背书。

**用户随后要求恢复、加快完成，已执行重新分配：**先补完半成品和相关快回归再真实P&R，最终候选才长链全验收，不放宽100MHz/II3/数值/原子拒绝/1800周期门槛。父会话补查旧84MHz原报告还有clock最小脉宽负裕量（−0.769ns），完整时序验收除setup/hold/recovery/removal还须检查MPW与忽略约束；已加独立拒绝门槛，不因此前未提及而放行。详见时序审查开头恢复记录。没有烧录。

**最新恢复实测：**DS已补完VSELECT/组合defaults，进一步实现engine候选PREP及bank最低missing缓存预检。父会话精确冻结新SHA，亲跑bank/engine SKIP0/1共12/12（1506/1508周期）、新增乱序cfg性质检查、RAM模板矩阵24/24、板级512样本/拒绝静音2/2、生产wrapper首256样本1/1及数字reset相位1/1通过；新核心4096样本bodyON/12.5MHz整链已亲验1/1通过、0稳定欠载、最长1072周期。未修改正式默认32×48 bank9/9、engine7/7亦父会话亲跑通过。父会话**真实完整Gowin亲跑**setup/hold0/0、Fmax100.024MHz、最坏setup+0.002ns；不再是仅DS自述或隔离body。clock MPW仍−0.514ns，故完整报告和外部certificate均拒收，**不能烧录**。具体SHA、原报告/XML及后续clock修复范围见[`hardware_timing_review.md`](hardware_timing_review.md)首节；暂停半成品警告只作为旧版本历史。

父会话随后补齐正式参数矩阵**36/36**（bank counts/engine digest指定入口，N1/7/48×V1/3/32×SKIP0/1），九组engine SKIP digest相同；独立engine还加强同握手/连续拒绝及完整operational/metadata/cache不变检查，32×48和1×1各3/3通过。clock MPW门槛不因新增功能通过而取消。

**最新SDC候选未接受：**DS用PLL source-latency共同名义值3.765ns让MPW转正(+2.117ns)，但父会话亲读SUG940后确认只有命令语法，缺少替换真实PVT极值的物理依据。该候选已完整归档并由报告/pin门槛实际拒收；生产SDC移除本次未证明覆盖，保留核心优化和准确reset注释，有效约束命令与core100亲跑基线相同。当前MPW仍按原模型−0.514ns/OPEN，不能称整机STA全部闭环；DS只读继续核查器件保证值/厂商建模依据，不烧录。

2026-10-05已找到并亲读公开DS1239 PLL duty/jitter规格；形成的只能是带适用条件的MPW预算，不能自动覆盖ES/B/实际输入条件。同步setup额外PLL uncertainty也待审，不能把+0.002ns解释为可靠裕量。所需芯片/晶振确认与厂商问题、原PDF SHA见[`clock_model_review.md`](clock_model_review.md)；DS只读审查已结束，没有正在运行的新优化或烧录。

**用户随后同意先冻结并准备7针MAX98357A/3W8Ω接线：**当前39个工程输入/验收工具已独立快照，PLL/IP/SDC及CST一致性实际核对通过，停止额外RTL优化，不修改频率/ROM/数值。冻结记录见[`demo_freeze_20261005.md`](demo_freeze_20261005.md)，接线以[`platform/tang_mega_138k_pro/MAX98357A_WIRING.md`](../../../../rtl/platform/tang_mega_138k_pro/MAX98357A_WIRING.md)为准；通电前仍核Pin1/模块丝印，物理part仍未确认，无Programmer/完整时序放行。

## 范围与分工

- 2B：系数/索引硬件ROM、声部装载及缺项拒绝。
- 2C：32声部、每声部48模态、四共享lane及独立状态/总和。
- 音频首阶段：自动事件歌曲→标准I2S→外接MAX98357A功放→喇叭的数字链路；板载PT8211为可选输出格式。
- 用户最终澄清“就是FPGA→喇叭播放”，本次不需要麦克风采集/监听。初期监听规划不是必交目标，未确认麦克风不再构成阻塞。
- 用户已拍板缺项拒绝报错，原声部保持，不移调/换力度档。
- 实现模型均为用户指定 `opencode-go/deepseek-v4.1-flash`；2BC会话 `ses_efbcabfffffec7xikH4ckRYH0b`，音频会话 `ses_efbc48868ffezacVqEr4ABaNsx`。父会话编写规格、独立补测及报告，不将模型自述当作复测结果。

## 设计与测试文件

- `rtl/module2BC_design.md`：ROM布局、装载契约、32声部存储/帧调度与测试门槛。
- `rtl/audio_bringup_design.md`：自动歌曲、音频时钟/串行/CDC规格及实物验收。
- `sim/test_modal_engine_review.py`：父会话独立引擎测试；只使用公开端口与原系数文件。
- `sim/test_modal_poly_bank_review.py`：父会话独立raw-bank测试，覆盖1536次饱和计数/64bit和、n_modes变化及历史保持、晚槽错误的原子拒绝。
- `rtl/body_design.md`及`sim/test_body_filter_review.py`：新增批准的guitar共享箱体规格/父会话独立测试，尚未列为通过。

## 实际结果

### 2B/2C文件与架构审查

DS创建：`python/modal_sim/gen_hw_rom.py`、`rtl/rom/modal_coeff.mem`、`modal_index.mem`、`modal_manifest.json`、`rtl/core/coeff_loader.sv`、`poly_modal_lane.sv`、`modal_poly_bank.sv`、`modal_engine.sv`、`sim/test_coeff_loader.py`、`test_modal_poly_bank.py`、`test_modal_engine.py`、`sim/_test_runner.py`。

父会话完整审阅生成器、loader、poly lane、bank、engine和共用runner。ROM同步读取，load先验证再clear/cfg，最后握手完成后load_done；缺项不改变旧声部。32声部复用四lane，每lane仅一个26×32数据路径乘法点及一个同步单端口72bit工作缓存，RAM不复位；目标声部state_valid分片清零。default工作缓存每lane768×72bit，四路共221184bit（含padding）。计算按声部运行并排空，II=3，状态地址包括voice维度。整个帧先验证，不允许晚槽非法但前槽已更新。

ROM默认路径相对仓库根；正式测试runner显式使用仓库根test_dir，另一个工程/cwd须覆写COEFF_FILE/INDEX_FILE或正确配置初始化文件。项目作者仍需确认接口及最终硬件映射。

### 父会话实际复跑正式回归

实际命令均使用torch312环境，build目录前缀 `/tmp/opencode/module2bc-review/formal-retest/`，父会话逐次解析XML确认用例数/无失败：

| 命令（另加--build-dir） | 用例 | 退出码 | 主要结果 |
|---|---:|---:|---|
| `python sim/test_coeff_loader.py` | **9/9 PASS** | 0 | 全250有效/774缺项、背压、复位；load最坏100拍<=216，错误2拍<=16 |
| `python sim/test_modal_poly_bank.py` | **9/9 PASS** | 0 | 32×48×100帧、153600提交；最坏1473拍<=1800 |
| `python sim/test_modal_engine.py --skip-zero-input 0` | **7/7 PASS** | 0 | 32×48真实整数模型100帧、8混合声部2048采样 |
| `python sim/test_modal_engine.py --skip-zero-input 1` | **7/7 PASS** | 0 | 同上；32声部最坏1474拍、8声部混合最坏304拍 |

loader/index生成器检查包含坏JSON、非法MIDI/档位、偏移/覆盖/重叠以及结构N小于表项拒绝，不能把N=1时的错误路径称为可发声测试（原表最小n=2）。

### 父会话独立补测

实际命令模板，日志和XML在 `/tmp/opencode/module2bc-review/parent-independent/`：

```bash
python sim/test_modal_engine_review.py --n-modes 48 --voices 32 --skip-zero-input 1 \
  --build-dir /tmp/opencode/module2bc-review/parent-independent/engine32
python sim/test_modal_poly_bank_review.py --n-modes 48 --voices 32 --skip-zero-input 1 \
  --build-dir /tmp/opencode/module2bc-review/parent-independent/bank32
```

另运行engine V=3,N=7,skip=0，以及raw bank V=1,N=1,skip=0。四组均**3/3通过，共12/12**，没有跳过，退出码0。

- engine默认：113帧、163776次状态提交逐位相等，最大1474周期；加载期间毒化输入、失败装载保留状态、未装载晚槽原子拒绝、reset取消查表/写入/计算。
- raw bank默认：总饱和计数**1536**准确，正和为`1536*(2^31-1)`、负和为`-1536*2^31`，不截断到int32；150次变更模态计数帧、117504次状态提交、仅清目标声部及尾部历史保持，最大1473周期。
- 小结构：engine V3/N7最大41周期；raw bank V1/N1最大14周期，覆盖参数化地址和零/非零模态数。

### 参数矩阵、ROM一致性与失败入口

父会话实际执行三个 `--matrix`，产物前缀 `/tmp/opencode/module2bc-review/parameter-matrix/`：loader **9/9**配置、bank **18/18**、engine **18/18**，共45配置退出码0且XML无失败。范围N=1/7/48,V=1/3/32；bank/engine另含skip0/1。engine矩阵还校验同一(N,V)的skip摘要一致。

独立将生成器输出到两个临时目录，与交付ROM逐文件byte-for-byte比较；三文件一致。父会话不用生成器的索引构造函数，直接从原四个mem/JSON重建：**5483系数、1024索引（250有效、774缺项）全部一致**。证据目录 `/tmp/opencode/module2bc-review/rom-integrity/`，ROM系数SHA256=`df6375213e1236f265ad654c603f5ab00ad926a845fc2ac1d3ab89f1cb8e6e81`，索引SHA256=`75c84224a6287ab6d27049d164f6f5b0f86bea93f90d2cdb88450c05ca601552`。

父会话对V=1/3/32、N=1..48、skip0/1，共**288组**独立-g2012/-Wall编译通过；除Icarus always_comb常量敏感列表提示外无diagnostic。编译产物确认默认四工作数组各`768×72bit`。这不是物理BSRAM映射证明。

共用runner已审阅，always=True、绝对build路径、删除旧XML、明确XML门槛。父会话实际用临时故意失败用例和不存在的testcase过滤器复测，两种**均退出1**；日志 `/tmp/opencode/module2bc-review/failure-gates/`。临时失败用例不是正式回归失败。

### 音频链路

音频实现者已交付7个RTL模块、3个正式测试入口及`rtl/audio_delivery_report.md`。默认标准I2S，PT8211显式可选；麦克风保留备选但不构成本次主交付。

父会话新增 `sim/test_audio_chain_review.py`：直接从**原始**`guitar_coeff.mem`/JSON提取系数，自行计算7采样升余弦脉冲、各声部状态及最终int16；不复用实现者黄金函数，也不以观察到的RTL输入推导歌曲时间线。检查load事件/真实引擎输出/核心TX握手/CDC FIFO出队，以及只依赖引脚的标准I2S边沿解码。按首级FIFO读握手确定启动静音位置，不搜索一个“恰好匹配”的数据块。参数V32、NOTE_GAP16，1352个黄金样本、85个事件，覆盖全部42个音符与再次循环、声部复用。首次实际复跑**1/1通过**，1353帧外部解码、仅1帧启动欠载、稳定期欠载0；核心100MHz、音频周期81.380ns（仿真ps取整，约2.56ppm量化误差），LRC间隔20830/20840ns核心节拍。日志 `/tmp/opencode/audio-chain-review.log`、XML `/tmp/opencode/audio-review/chain32/results.xml`。

该独立测试随后改为事件驱动以减少空闲核心边沿开销；两次复跑的数据断言通过，但退出时分别遇到cocotb嵌套First任务cancel清理错误、停止协程不同时导致末尾监测多读一次，**这些退出1的测试驱动版本不计通过**。已改为显式停止标志、唤醒后立即结束并等待协程正常退出。最终版本父会话实际重跑**1/1通过，退出0**，仍为1352个黄金样本、85事件、1353帧、1启动欠载与0稳定欠载；日志 `/tmp/opencode/audio-chain-reviewed.log`、XML `/tmp/opencode/audio-review/chain32-reviewed/results.xml`。此前使用旧清理逻辑的长测试被主动取消(143)，不列通过或RTL失败。

**默认间隔真实边界复测也已通过**：`python sim/test_audio_chain_review.py --voices 32 --gap 12000 --samples 12008 --build-dir /tmp/opencode/audio-review/default-gap-reviewed`，**1/1通过，退出0**；12008个黄金样本、2事件、12009个外部I2S帧，1启动欠载、稳定欠载0，模拟约0.250秒。覆盖默认250ms音符间隔、长衰减与下个事件重装；不是整个默认10.5秒曲长的实时时域验证，更不是>=60s实板稳定性。日志 `/tmp/opencode/audio-default-gap-reviewed.log`。

父会话新增 `sim/test_audio_transport_review.py`，当前**3/3通过**，覆盖reset期间不能虚报写握手、I2S恰在帧边界的clear优先级、一核心拍clear在12个不同时钟相位的跨域传递及后续错误重置位。XML `/tmp/opencode/audio-review/transport-independent/{fifo,tx,cdc}/results.xml`，日志 `/tmp/opencode/audio-transport-review-final.log`。第一轮CDC测试在下次空帧边界前几十ns就检查错误重置位导致测试时间窗不足，已将等待从100us增加到120us重跑通过，并非修改RTL来掩盖数据错误。

父会话正式入口中间复跑曾发生real-engine新增clear测试失败（最终定位为测试驱动竞态，见修复段）。**最终实际复跑全部通过**，build/log前缀 `/tmp/opencode/audio-review/formal-final/`，父会话解析所有XML确认准确用例数/无失败：

| 命令（另加绝对--build-dir） | 最终用例 | 退出码 |
|---|---:|---:|
| `python sim/test_song_player.py` | **5/5 PASS** | 0 |
| `python sim/test_audio_transport.py` | **20/20 PASS**（16主/4备选MIC） | 0 |
| `python sim/test_audio_demo.py` | **4/4 PASS**（mock歌曲/playback_ready/备选MIC/真实引擎歌曲） | 0 |

正式real-engine用例4096样本逐位对拍，8声部、NOTE_GAP512，engine busy最大254核心周期，测试每帧预算2048拍（比实用2083拍更紧）；启动sticky=1（2个前导静音帧包括首个零激励样本），清除后稳定underflow=0，deadline/overflow/engine error均0。不能把前导静音帧数与真正FIFO欠载事件数混为一谈。

父会话另实际重跑原2A **14/14 PASS、退出0**，XML `/tmp/opencode/audio-review/baseline-2a-final/results.xml`。音频独立transport最后一次复跑仍**3/3 PASS**，XML `/tmp/opencode/audio-review/transport-reviewed-final/{fifo,tx,cdc}/results.xml`。

### 板级封装独立补测（行为PLL，不是硬件PLL）

板级DS创建top/clock_reset/board_audio_core、CST/SDC、源文件列表、预检/构建入口及说明；正在修复预检及SDC审查意见。父会话新增 `sim/test_audio_board_review.py`，**实际生产版board_audio_core + 真实modal_engine/ROM**（不是mock）搭配明确test-only行为PLL，32声部、NOTE_GAP16、256个黄金样本与16事件，观察外部amp引脚逐位核对、核心/CDC握手不丢重。强制audio PLL的lock丢失立即静音、恢复后再次启动及按钮复位立即静音均通过。第二配置N_MODES1：真实表项结构拒绝、时钟锁定并过12帧后，功放仍保持静音。父会话实际**2/2通过，退出0**，日志 `/tmp/opencode/audio-board-independent-final.log`、XML `/tmp/opencode/audio-review/board-independent-final/{real,reject}/results.xml`。

该测试只验证板级封装的连接/控制及真实计算链路，行为PLL不证明合法PFD/VCO、物理锁定、频率、抖动、Gowin资源/时序或已上板。此段是早期仿真证据；目前真实vendor core100MHz/audio12.5MHz IP已创建，器件与完整构建验收仍按下文单独判定。

父会话实际复跑 `python sim/test_audio_board.py --build-dir /tmp/opencode/audio-review/board-formal-final` **6/6 PASS、退出0**，采用行为PLL/计算mock的正式板级控制测试；不得替代上面的真实引擎独立测试。板级预检另新增父会话 `sim/test_audio_board_preflight_review.py`，8项恶意/损坏临时夹具测试，首轮暴露3项漏检（Verilog延迟被注释清理抹除、ROM同一行额外词、生成IP仅匹配后缀）。DS修复后父会话亲自重跑**8/8通过、退出0**，日志 `/tmp/opencode/audio-board-preflight-reviewed-final.log`，三项已关闭。

正式preflight套件父会话早期复跑时“missing_tool_nonzero”用例发现rc0（日志 `/tmp/opencode/audio-board-preflight-formal-final.log`）；同时用户明确更正Gowin已安装，属于测试依赖“环境没有工具”的错误假设，已要求DS隔离PATH后再测，不修改用户工具或license使测试人为通过。**最新父会话亲跑`python sim/test_audio_board_preflight.py`已10/10通过、退出0**，日志`/tmp/opencode/board-preflight-latest-parent.log`，该脚本生成XML为`sim/build/audio_board_preflight/results.xml`（未写`sim/results.xml`）。

vendor PLL接口改为`clkin/init_clk/clkout0/lock`并新增`_mod.v`伴随文件后，父会话已适配自己独立夹具；最新增加body结构拒绝，亲跑`python sim/test_audio_board_preflight_review.py`，**13/13 PASS、退出0**。这是结构/拒绝路径门槛，不验证PLL数学合法性或外部时序模型正确性。

父会话另新增只读报告门槛`sim/review_gowin_reports.py`，检查缺报告、工具错误/ROM缺失、四lane及其RAM/乘法映射，现已增加STA setup/hold、Recovery/Removal负slack、实际clock period及`--require-body`箱体资源检查；旧ROM缺失产物、第二轮PA2122及真实阵列时序失败均**非零拒收**。最新`python sim/test_gowin_report_gate_review.py` **15/15通过、退出0**，全部采用临时合成夹具而非硬件证据。外部快慢角/certificate夹具21/21通过，但不是外部真实时序接受。即使该门槛通过，也不能替代外部setup-hold/CDC例外与Gray边界/未约束路径/网表功能/实物型号验收。

### 实现期间的基线复测（已执行）

`python sim/test_modal_bank.py --build-dir /tmp/opencode/module2bc-review/baseline-2a/formal`：14/14通过，XML无失败、退出0。

`python sim/test_modal_bank_independent_review.py --build-dir /tmp/opencode/module2bc-review/baseline-2a/independent`：4/4通过，XML无失败、退出0。

这些只确认原2A基线，不表示新增2B/2C或音频链路已完成。

## 审查修复

实现者运行父会话编写的独立engine测试时发现：loader的注册error被engine再次注册转发，出现sample_ready已回空闲而错误尚未可见的窗口。DS已在交付前修复为直接转发loader/bank注册错误，未装载active错误仍由engine注册。父会话审查的是修复后源码，并亲自重跑当前版本正式/独立套件通过；**不把DS代跑父会话脚本称为父会话亲自执行**。

当前独立复测未发现未关闭的2B/2C功能/周期阻塞项。大范围组合预检查、地址译码与64bit加法树的硬件时序仍需Gowin确认；通用runner的通过不能消除该风险。

音频源码审查反馈的三项RTL风险已由DS修复：FIFO本域复位释放前wready/rvalid门控；diag_clear改事件toggle跨域，core不重复锁存旧audio sticky；TX帧边界clear/new-underflow优先级。父会话独立transport3/3已关闭上述路径。正式demo后续出现的clear失败是2ns核心测试钟下边沿驱动竞态，DS改为下降沿拉高、跨完整上升沿、下一下降沿撤销；父会话最终正式29/29已通过。新增playback_ready供板级SD门控，避免装载失败只计WS帧就打开功放；父会话N1真实ROM拒绝案例已独立验证。

## 板级重要发现与阻塞

### 当前真实Gowin结果：临时产物未接受

DS已用本机Gowin V1.9.12.04生成core100MHz PLL，并执行真实syn/pnr、生成provisional fs/bin，报告在`rtl/platform/tang_mega_138k_pro/reports/provisional/`。**工具流程执行成功不等于设计验收成功**。父会话实际打开报告发现：

1. `synthesis.log:49–50`有两个`WARN(EX3988) Cannot open file`，分别为`rtl/rom/modal_coeff.mem`和`modal_index.mem`。综合CWD与初始化相对路径失配，不能用“已run syn”掩盖。
2. `synthesis_resources.xml`中的u_engine仅124 FF/222 LUT，u_bank只保留lane0的1个FF；pnr资源776 logic/621FF、无实际模态DSP/BSRAM。这与32×48有效工作阵列不符，说明数据通路已被优化掉。**这些资源/Fmax数据不能证明真实模态引擎映射或100MHz时序满足**。
3. 精确12.288MHz单级配置被工具P&R拒绝，PA2078说明PFD范围19..81.25MHz，原数学候选50/5=10MHz不合法。临时生成使用12.5MHz而约束曾仍按12.288MHz；输出还有40项hold flag，必须重新约束/修复，不能自动按“artifact”豁免。

父会话已把以上拒收项反馈DS：修复ROM真实路径、将ROM读取警告设为构建失败门槛，确认两ROM与四lane/DSP/工作缓存真实保留；按真实使用频率重建约束、setup/hold和未约束路径均检查，重新syn/pnr及功能证据。现有provisional bitstream**不作为可用出声文件交付**，不执行Programmer。

**第二轮实际报告已独立读取**：`reports/attempt2_romfixed_syn_ok_pnr_blocked/flow.log`明确顶层`board_top`使用绝对ROM路径参数，综合不再报EX3988；资源XML保留6227 FF、11966 LUT、976 ALU、4×MULT27X36和5×MULT12X12、49 BSRAM（loader33、四lane各4）。这关闭了此前“ROM打不开导致阵列消失”的综合现象，但不是全部ROM内容/网表功能或最终时序验收。

该轮P&R在`flow.log:129–144`报**PA2122：四lane的SPX9 WRITE_MODE=2'b10不支持**。当时`poly_modal_lane.sv`同步缓存在写拍仍读取旧内容，从而推断read-first。DS已按父会话授权将该模块RAM模板改为no-change/写拍保持输出；未更改递推、周期、声部隔离或数值参考。父会话已亲跑以下独立修复验证，但真实P&R映射是否合法仍须新Gowin报告证明。原2A `modal_lane.sv`不在此修复范围。

#### 缓存修复的父会话独立复测

- 新增`sim/test_poly_lane_ram_equivalence_review.py`，在临时build目录生成**原read-first模板**的测试专用lane，和当前lane同输入逐周期比较全部公开commit/64bit和/饱和/done，并断言当前写拍rdata保持。覆盖相邻配置写、多声部随机模式数、清历史、输入毒化、所有流水相位reset；**24/24配置通过**：V/N=(1/1,3/5,32/48)×四lane×SKIP0/1，XML/日志在`/tmp/opencode/ram-review/parent-equivalence-matrix/`。这证明模板替换在所测轨迹下不改变可观察功能，而非证明物理缓存资源本身。
- raw-bank独立SKIP0/1各**3/3通过**，满载1536次正负饱和计数、64bit和、150帧/117504 commits的模式数变化与历史保持，最大**1473周期**。XML：`/tmp/opencode/ram-review/parent-bank-skip{0,1}/review.xml`。
- engine独立SKIP0/1各**3/3通过**，每组113帧/163776 commits、失败装载保原声部/原子拒绝/reset，最大**1474周期**。XML：`/tmp/opencode/ram-review/parent-engine-skip{0,1}/review.xml`。
- pre-body 32声部、gap16、12.5MHz诊断时钟独立真实引擎→I2S **1/1通过**：1352黄金样本/85事件/1353外部帧，1启动欠载/0稳定欠载，最长963核心周期。XML：`/tmp/opencode/ram-review/parent-prebody-chain32/results.xml`。
- 新PLL接口/12.5MHz行为模型下板级真实引擎引脚独立**2/2通过**：256黄金样本/17事件/257帧、unlock/reset立即静音，以及N_MODES=1装载拒绝后始终静音。XML：`/tmp/opencode/ram-review/parent-board-12m5/{real,reject}/results.xml`；行为PLL仍不能证明硬件PLL。

此外，第二轮SDC虽然已按12.5MHz修改，但将BCLK/DIN/LRC全部约束到内部audio clock、不建立MAX的外部BCLK采样关系，**不足以证明source-synchronous setup/hold满足10ns**。不能只凭原40个hold flag消失宣布关闭；仍需正确forwarded-clock/相位模型或独立最坏输出路径差分证明，并核查新`u_top`层次下PLL get_pins确实命中。父会话已反馈，当前输出时序仍未接受。

用户晨间明确选择 **“12.5MHz仅先验证出声”**：该时钟合法，但实际Fs=12.5MHz/256=48,828.125Hz，较48k高1.7252604%，相同系数的音高约升29.6音分。允许其用于诊断播放，不允许称48kHz保真通过；SOS/模态系数仍按48k参考，不擅自重拟合。必须把实际12.5MHz/80ns、BCLK3.125MHz及48.828k frame与目标48k区分记录。完整器件型号仍未确认，用户仅能确认138K Pro Dock/8GT/s x4，ES/A后缀须实物核对；按AES进行的构建只能标provisional。

### 新增箱体工作范围

**最新流水v3独立复验：**body hash=`00d8e13d…9456`，单帧74周期；父会话独立四乐器8/8、正式10/10、拒绝4/4、数值3/3通过。冻结lane=`13e7f6ab…17fe0`组合在目标48k(ps-rounded)/12.5MHz诊断各4096样本的完整64bitbody/FIFO/外部I2S对拍均通过，最长1038周期、稳定欠载0；生产`board_top`默认bodyON/gap12000/真实绝对路径256样本首事件也通过。父会话**实际亲跑**隔离Gowin100MHz syn/pnr，setup/hold0/0，124.787MHz/+1.986ns；更进一步真实网表+未修改vendor DSP/ROM功能库1736输出/22饱和/74周期逐位通过。隔离数据不是完整PLL/整机STA或SDF验收；当前核心物理优化版本变动须重新验收。详见[`body_review_report.md`](body_review_report.md)及[`hardware_timing_review.md`](hardware_timing_review.md)。

**最新完整工程77.315MHz补验：**父会话亲读`pnr_body_v3_coreopt_77mhz/`，core100MHz/audio12.5MHz clock对象正确，但setup2928、汇总hold7（真实7条PLL锁定→reset同步链CLEAR **removal**），仍非零拒收。对应精确SHA engine=`525012d5…cccf`/bank=`5c618d7f…3ccd`已父会话独立bank/engine SKIP0/1共12/12、RAM对拍矩阵24/24、bodyON4096样本链、板级512样本/拒绝静音及生产wrapper默认路径通过；满载1473/1474周期、整链最长1038周期不变。数字复位相位另24次扰动/六链逐拍核对通过，不提供亚稳态/物理复位裕量证明。当前修复剩余bank高扇出enable、clear voice×12地址DSP及严格scoped专用reset CLEAR；同握手报错/busy低/失败保原状态、II3/100MHz/1800周期上限不变，最终版本须重新验收。

**最新硬件审查补充：** `reports/pnr_timing_fail_prebody/`与`reports/pnr_body_timing_fail/`实际syn/pnr完成，ROM/四lane/body保留；但STA分别setup4235/hold14、setup3991/hold10端点违例，core Fmax汇总56.051/48.729MHz而目标100MHz。父会话亲读关键路径及网表发现：body sec×5与core vcur×12常数地址运算被推成输入寄存/输出绕过的DSP，串联后续选择/主乘法；body另外需要注册宽乘法/104bit累加。SD按不存在的外部每core拍采样约束亦造成最坏汇总路径；实际内部16–19ns失败不能以调整SD模型掩盖。已重新明确分配两个DS的物理优化，保留数值和100MHz/1800周期门槛，新实现必须重新独立复测。详细证据与外部I2S/CDC修复方案见[`hardware_timing_review.md`](hardware_timing_review.md)。以下功能结果为已接受的旧v2版本，不自动代表流水新版本通过。

用户明确批准“工程＋箱体”并进一步选择“先闭环guitar”：DS会话`ses_ef9e6dd29ffe3gkZvLtsuH2t8y`实现单共享4-biquad、四乐器ROM/整数模型与guitar歌曲端到端。父会话规格`rtl/body_design.md`：外部64/Q30，内部68/Q34保护位，系数32/Q30，104bit累加，每section一次舍入饱和、末级回Q30。噪声瞬态/note_off/方案C/完整声部管理/多乐器混奏分组不包含。

父会话已独立审查实现并实际亲跑：

| 独立验证 | 结果与证据 |
|---|---|
| `sim/test_body_filter_review.py`四instrument | 各**2/2通过（共8/8）**，每乐器4713样本的64bit输出、4×4历史状态、逐section饱和mask/count与**原始Patch.sos独立黄金**逐位一致；25核心周期；reset多个计算相位/clear/busy毒化通过。XML：`/tmp/opencode/body-review/parent-{guitar,piano,banjo,mandolin}-final/results.xml`。全幅饱和压力分别观察1/14/6/11次section饱和。 |
| `sim/test_audio_chain_review.py --voices 32 --gap 16 --samples 4096 --body` | 目标48k(ps-rounded)与`--diagnostic-12m5`各**1/1通过**；原模态ROM黄金+原Patch.sos独立DFI黄金，modal mix、完整64bit箱体输出、PCM/FIFO/外部标准I2S均核对；257事件/4097帧，1启动欠载、**0稳定欠载/overflow/deadline/正常箱体饱和**，最长modal+body **989核心周期**。XML：`/tmp/opencode/body-review/parent-chain32-{48k,12m5}-full/results.xml`。 |
| `sim/test_body_numeric_review.py` | **3/3通过**：80词原SOS重建/manifest格式与源hash/临时目录可重现均正确；原SOS浮点对独立68Q34 DFI，每乐器1冲激+4096随机±0.5+65536静默，频响20Hz..20kHz、极点稳定及残余均符合局部门槛。日志`/tmp/opencode/body-review-parent-numeric-all.log`。 |
| `sim/test_body_rejection_review.py` | **4/4通过**：instrument=-1/4及缺/短ROM不虚报握手、不产生输出，coeff_error明确，reset重试仍拒绝。XML：`/tmp/opencode/body-review/parent-rejection/*/results.xml`。 |

数值结果（单位输入归一化，不是百分比）：

| 乐器 | 峰值误差 | RMS误差 | 尾4096采样残余峰值 | 频响误差上限(dB) |
|---|---:|---:|---:|---:|
| guitar | 9.77e-9 | 7.25e-9 | 7.45e-9 | 4.38e-7 |
| piano | 7.79e-8 | 5.55e-8 | 5.77e-8 | 1.45e-6 |
| banjo | 8.37e-9 | 1.90e-9 | 1.86e-9 | 3.70e-7 |
| mandolin | 3.88e-8 | 5.31e-9 | 4.66e-9 | 1.79e-6 |

父会话同时亲跑旧ENABLE_BODY=0正式song5/5、transport20/20、demo4/4（共29/29），原2A14/14通过，XML在`/tmp/opencode/body-review/parent-baseline-{song,transport,demo}/`及`/tmp/opencode/ram-review/parent-original2a/`；未修改旧tests迁就本实现。新增body正式模块入口父会话亦亲跑**10/10通过**（`/tmp/opencode/body-review/parent-formal-filter/`），正式纯Python模型/生成器入口全部检查通过、退出0；真实guitar模态歌曲输入的局部箱体float峰误差4.52e-8、RMS1.68e-8，无饱和。详细独立报告[`body_review_report.md`](body_review_report.md)。DS最终报告[`body_delivery_report.md`](body_delivery_report.md)与关键文件hash已核对，父会话接受功能范围，并已授权下一轮平台生产wrapper开启BODY及独立真实重构建；**上述功能结果不代表已完成含箱体Gowin验收**。没有新增噪声/制音/混奏控制，也不是完整原始engine.py迁移完成。

原理图Rev1.2页18/19的U6为**PT8211-S**，16bit Japanese/LSBJ，不是标准I2S。数字麦克风I2S接收与PT8211发送须分别实现。2pin喇叭是模拟功放输出，不能直接FPGA GPIO。用户7pin模块型号仍待照片、芯片丝印、引脚标注和接线确认；不能自动认定为官方10pin6+1阵列。

后续用户已读出外接模块为 **MAX98357A**：这是标准I2S单声道功放而非麦克风。首选播放路径已调整为标准I2S→外接MAX98357A→喇叭，板载PT8211成为另选格式。用户已明确不要求麦克风监听。VIN等模糊引脚/现有接线仍待照片；不能将功放DIN当作麦克风数据输出，也不能把桥接扬声器负端接地。

进一步确认VIN范围2.5–5.5V、喇叭3W/8Ω；实际供电电压仍未知。TDM模式固定12dB是器件手册的模式规格，不表示首版必须使用TDM或实物已在TDM。首版继续标准I2S；内部32声部时分复用不等于8-slot音频TDM。I2S模式实际功放增益取决于GAIN脚连接，不能默认12dB。

用户随后选择实际供电**3.3V**及空闲**PMOD2**。父会话据本地原理图页17核定J26的IO0/1/2/3分别为C21/B20/B19/A17，规划为BCLK/LRC/DIN/SD；写入外设约束片段 `rtl/platform/tang_mega_138k_pro/audio_pmod2.cst`。这不是完整Gowin工程，不含尚未生成的PLL/board wrapper/SDC，也没有证明PMOD3.3V供电足以带动该扬声器负载。接线须确认实板版本、Pin1方向及共地。

早期环境检查曾得到`gw_sh`、`openFPGALoader`不在PATH、`/opt`没有gw_sh。**用户最新更正：IDE和Programmer在主文件夹的`gowin`下，license已验证。父会话实际确认`/home/rubbishbro/gowin/IDE/bin/gw_sh`、GowinModGen/GowinSynthesis及doc存在，当前`command -v gw_sh`也返回该路径。早期“没有Gowin”不是当前事实。** 已继续向DS板级实现任务分配真实PLL生成和综合/布局布线，不改用户license、不泄露license内容；能否成功须以本工程实际执行结果判定，不能只因工具存在列通过。`lsusb`早期未显示可识别下载器，当前不执行烧录或宣称听音。

当前已执行Gowin并关闭ROM路径缺失的综合现象，第二轮有真实阵列资源证据；P&R因缓存写模式阻塞、外部时序模型仍未接受，没有可放行bitstream。未执行烧录、板级测量或实际听音。原2BC核心不含阶段4声部分配/回收/抢占；箱体已另批准新增，麦克风特征识别不在用户目标内。

## 最终结论

**2B/2C建议接受为功能/周期交付**：32×48满载集成1474拍（100MHz预算下约14.74us）低于1800拍门槛，并距最短2083拍预算余609拍。装载与计算互斥，单次最大装载100拍；不能把余量当成无上限事件队列容量，歌曲需按ready并实际测整机deadline。

**guitar箱体流水v3的独立功能、冻结整机4096样本/I2S及隔离100MHz STA通过；完整工程核心物理优化和整机/外部时序尚未接受，实板播放未执行。** “RTL功能通过”“有效硬件构建通过”“实物已出声”分别判定。烧录前仍须核对完整part与接线，拿到ROM/阵列正确映射、实际频率一致且setup/hold/未约束检查合格的bitstream。当前12.5MHz只能按用户允许的诊断出声口径验收，不是48k保真；未完成的噪声/控制/混奏及实板范围必须明确列出。
