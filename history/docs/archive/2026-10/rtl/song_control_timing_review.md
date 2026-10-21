# 首帧修复后：100MHz配置地址时序收敛

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

当前整机资源汇总见[歌曲合成工程资源占用（v5）](../../../工程汇报.md)，源码/验证/试验入口见[项目文档导航](../../../README.md)。2026年10月9日整理时采用用户决定的“先实板试验，模型分析继续留作报告”顺序；下文模型门槛与历史拒收记录保留，不等同撤销有限SRAM试验授权，也不补写尚未收到的实板测量结果。

**后续用户要求查PLL/时钟树：**只读查证发现v5的50MHz输入`clk_d`存在PR1014普通布线警告，核心100MHz输出仍为PRIMARY；`tCL`官方定义为clock source latency，不能将其早晚差全称PLL本体失真。名义50%/分频配置合法，源路径分量及MPW相关性处理仍待证明。详见[PLL脉宽查证](pll_clock_pulse_audit.md)。本次不改生产RTL/IP/约束或重新构建。

2026-10-07，接续[装载元数据修复](song_metadata_fix_review.md)。用户授权继续，保持100MHz、II3、32×48、逐位数值和≤1800周期；不降频、不改约束、不操作硬件。

## 真实路径证据

已验v1的最坏setup路径为loader voice寄存器→配置地址常数乘DSP→加法/地址选择→lane工作BSRAM地址：

`/tmp/opencode/song-metadata-core100-20261007/build/song_metadata_core100/impl/pnr/song_metadata_core100.tr` 第234–267行显示`n1423_s` DSP本体延迟3.779ns、最坏slack−0.274ns。综合网表另一个`vb_next_0_s`也为`MULT12X12`，输入/输出寄存器均BYPASS。

因此本轮不再猜前缀编码，保留已验v1逐voice元数据寄存器，只将`poly_modal_lane.sv`中的两处常数寻址乘法改为显式窄位移位/加法。

## v4代码范围

- `voice_base(v)`将常数`LOCAL_MODES`按二进制展开，累加`SVW'(v)<<k`，`vb_next`使用该函数。
- 配置地址用`cfg_base + cfg_local`得到窄位slot，再移位一位作为系数字地址；保留32bit观测线，低ADDRW位与原式一致。
- 合法地址完整相等，所有可表达非法code低地址位也按模2^ADDRW相等。不硬编码LOCAL_MODES=12。
- 不增加寄存器、不延迟cfg写，不改no-change RAM模板、状态有效位、clear、采样合同、DSP数值乘法及II3调度。

代码表达未使用乘法运算符，不代表综合器一定不用DSP；实际映射必须重新检查。

## 构建与测试

冻结构建：`/tmp/opencode/song-control-core100-v4-20261007/`。

`sim/build_song_metadata_review.py`新增显式`--allow-rtl-change`参数，本轮只允许bank元数据及lane寻址文件变化；其他生产RTL/IP去注释逐token比较、CST/SDC有效命令和ROM检查不放宽。原始输入、ROM副本重定位SHA记录在快照manifest，未覆盖旧候选。

父会话测试目录：`/tmp/opencode/song-control-v4-review/`。独立重新编译固定快照，34项RTL回归及60组地址矩阵均通过，非空XML数量及无failure/error/skip已另外检查。满载bank/engine仍最大1506/1508周期，原数值/握手契约不变。

v4真实生产综合网表＋完整未改vendor库的两个启动/reset阶段已亲跑通过：34个完整I2S帧、34个完整64bit模态和、30个非零音频帧与独立黄金一致。证据`fixed-gate/{run.log,result.json}`。仍仅是首音符功能范围，不宣称完整整曲或32声部全模态网表回归已经通过；后者正在补独立bank综合测试。

v4综合网表确认两处`MULT12X12`地址乘法都消失，四lane及箱体的7个`MULT27X36`实例仍在，1728个metadata DFF仍在。资源：15416logic、8911FF、0latch、52BSRAM、14DSP（物理DSP单元统计不等同于乘法原语实例数）。网表SHA=`186fba9f3582a0d7975543fde452fe9cedbbedea05bb48dc0bdbd90d793d38fe`。

## 真实P&R当前结果

- 100MHz核心setup **0违例**，Fmax **100.007MHz**，最坏slack **+0.001ns**；裕量很小，不称宽裕或额外jitter闭环。
- hold **2违例**：TX FIFO `wgray_0/1_s0/Q → wgray_s1_0/1_s0/D`，跨core→audio第一级同步器，最坏 **−0.160ns**。
- MPW **−0.612ns**，箱体乘法器高脉宽表actual0.288ns/required0.900ns，继续OPEN。
- 时钟、source latency、CST/SDC均保持原模型。本轮地址修复没有自动关闭CDC/PLL动态抖动/外部I2S最终审核。

正在只读审核两条hold的真实异步第一级端点及max_delay有效覆盖；只有经证明的、限定第一级D的hold模型例外才可能提出，不切同域stage2或Graybus setup/max_delay。未经真实重跑不宣称hold已消失。

## v5：已审查的异步第一级hold建模

DS只读review后，父会话又独立核对RTL及原生产网表：TX FIFO两向Gray各5位都来自源域DFF，跨域到第一级，再到同域第二级；最高位Gray=bin最高位，综合共享了bin寄存器，并非组合Gray输入。节拍toggle同样源域寄存、两级接收。生产RX FIFO、诊断事件同步器被优化移除，不给不存在端点增加例外。

只追加11条`set_false_path -hold -to <stage1/D>`：两向5bit Gray与一个节拍第一级；不追加stage2/D，不切FIFO存储数据/mono路径，不改reset/CLEAR既有7条或setup/max_delay。两个独立PLL没有经过保证的锁后捕获相位，FIFO本身按异步协议设计；第一级的同步hold相位检查并非它的闭环要求，亚稳态仍须由真实器件/MTBF审查。这是模型分类修正，不是声称物理hold修好。

v4原始STA的`3.7.1`已有两个方向的实际max_delay路径：core→audio的存储数据→mono路径，audio→core的全部5位读Gray→第一级路径，不只“Actived”标签。v5重建必须保留真实setup路径证据，并保留第二级同域时序。

新增`sim/review_song_cdc.py`只读门槛：逐一检查源寄存器/时钟、stage1/2连接、完整11个D端点与既有7个CLEAR范围、无clock-group/source-latency覆盖、两条max_delay命令及各自真实setup路径证据、setup/hold计数。不把此子集检查称MTBF或整机通过。合成夹具`sim/test_song_cdc_review.py` **6/6通过**，拒绝切stage2、未知CLEAR、无-hold的setup切割、缺失传播界/真实路径、组合或错误时钟源，以及错误/ignored计数。

v5真实构建目录：`/tmp/opencode/song-control-core100-v5-20261007/`。源沿用v4，仅经明确`--allow-constraint-change`许可的SDC变化，构建器记录旧/新约束SHA而非静默跳过。

**v5真实重建已完成：setup0/hold0、Fmax100.007MHz、最坏setup+0.001ns。**`review_song_cdc.py`对v5原始网表/实际SDC/原始STA已亲跑通过，全部11个D端点命中、两向max_delay实际setup路径仍存在，第二级同域连接及例外范围保留。结果`/tmp/opencode/song-control-v5-review/cdc_review.json`。

SDC-only重建网表与v4除了两处经逐项检查的ALU carry/instance标识重命名外，逐Verilog token完全相同，INIT/逻辑无变化，证据`/tmp/opencode/song-control-v5-review/source_build_identity.json`；v5自身网表黄金音频仿真仍另外执行，不仅依赖标识对照。

v5自身真实网表＋完整未改vendor库的两个启动/reset阶段也已亲跑完成：34个完整I2S帧/34个完整64bit模态和/30个非零音频帧全部与黄金一致，`playback_ready`复位清0并重新置1。日志及输入SHA：`/tmp/opencode/song-control-v5-review/fixed-gate/{run.log,result.json}`，不是仅复用v4结果。

另对v5固定RTL快照亲跑实际生产wrapper32黄金样本及数字reset相位检查，分别1/1通过、非空XML核实；24个按钮/core-lock/audio-lock扰动验证同步释放、即时静音、无幽灵输出及重启。日志`/tmp/opencode/song-control-v5-review/reset-phase-runner.log`。这使用测试PLL行为时钟及数字force扰动，不冒称模拟PLL/亚稳态/MTBF或硅片复位证明；生产网表音频对照仍使用未改vendor库且无force。

**MPW仍−0.612ns，完整报告门槛仍拒收。**父对v5全部真实综合/资源/PNR/STA报告调用既有严格`review_gowin_reports.py`，剩余拒收项全部是负MPW路径；未修改门槛忽略它们，也未采用source-latency覆盖、PLL nominal50%或降频。证据`/tmp/opencode/song-control-v5-review/report-gate/result.json`。这表示普通setup/hold与CDC建模收敛，不表示PVT/PLL/整机放行或实板歌曲已验收。

最终工作区bank/lane分别与真实构建快照逐字节一致，SHA：

- `modal_poly_bank.sv`：`2f52e0077fc2eebd92ed9c074ebd75a3c2be547ae92af7f3edd7a0a904c23c47`。
- `poly_modal_lane.sv`：`353645be12571a56fd85082de1d4d6c8e41c1f145cff694ec4300a44089fbe08`。

原歌曲和已实板出声的测试音交付目录均未覆盖，未操作Programmer、未写Flash。临时v5证据目录明确附`NOT_ACCEPTED.md`，不能把里面自动生成的.fs当作已放行交付。

## 网表夹具复位适配

此前v3输入变为`n11_6/n11_7`并非可以按名字猜极性。父会话已检查原始`clock_reset`：`LUT2 n11_s1`将两者做NAND（INIT=4'h7）生成原高有效`n11_5`复位。因此测试绑定`(rst_n,1)`等价于旧`~rst_n`。原始单线版本保持原连接。

`sim/test_song_netlist_review.py`只支持这两个已审查编码，split编码必须从原网表确认NAND实例/引脚及INIT；其他重命名一律拒绝，不自动猜连线。新增夹具单测`sim/test_song_fixture_review.py` **3/3通过**，含错误truth table、缺失gate、未知/额外输入拒绝。该测试复位仍隔离物理PLL，不宣称PLL/PVT/reset实板通过。

**当前未放行新的bitstream；功能、物理setup/hold和原MPW/PLL/CDC模型分别验收。**

## 隔离bank综合网表全范围回归：父独立功能验收通过

DS交付了`sim/test_bank_netlist_review.py`，其旧证据`/tmp/opencode/song-bank-netlist-ds/`记录真实Gowin独立综合及三个公共端口黄金测试通过，最大1506周期。**这只是实现方证据，不计为父会话已经验收。**

父审发现旧工具的“holes16/32/48”日志过度声称：它并未实际制造count48有洞的请求。要求DS仅修订新测试工具，增加显式15/31/47空洞、reverse/even-odd/shuffle每次cfg下一边沿拒绝检查、最终cfg立即合法采样、低洞填充跨16/32、重复cfg、合法voice0与非法voice31整帧拒绝，并硬化三用例XML数量、覆盖marker、非32×48参数/过滤器拒跑及参考文件SHA。旧DS证据不覆盖，不能作为修订版测试结果。

父已另外冻结修订测试、复用测试及数值参考，核实完整未改vendor库SHA及v4/v5/工作区bank/lane逐字节相同。独立重新综合/仿真在`/tmp/opencode/song-bank-netlist-parent-review-20261007/`完成，生产参数`SKIP_ZERO_INPUT=1`。**收到完成通知后，父又独立解析原始XML、检查日志及各输入/输出SHA，确认恰好三个不同用例、无failure/error/skip，全部通过。**

结果：满载最大1506周期，正负饱和帧每帧1536条状态提交及完整64位声部和/混音和黄金相符；变长度测试150帧、117504条状态提交；第三测试明确制造16/32/48空洞、三种乱序配置后下一边沿检查、低洞填充跨16/32、重复cfg、clear/reset/reload及后序非法voice31整帧拒绝，baseline/injected的384条提交完全相同。日志的`commits_logged=117888`是两条日志计数的加和，不是整套测试所有实际提交的总数。

冻结工具SHA：`a486917fb2f3b99d62a59947692ee96c938ef0e6751332ce16521b5f48debc13`；父综合网表SHA：`dde1453c06d74d44ebaaf79055c2312f763e32aedca88af6f405724550be2e33`。输入manifest为`parent_manifest.json`，独立复核结论为`parent_acceptance.json`，原始结果在`run/{result.json,results.xml,run.log,flow.log}`。

隔离bank综合不做P&R、无CST/SDC，不产生或下载新bitstream。这只补模态bank功能覆盖，不证明生产歌曲全曲或完整STA/实板通过，也不是尚未实施的并行有效位译码候选验收；生产MPW仍未放行。

## 2026-10-08：用户授权先做有限SRAM实板试验

用户明确建议先上板测量，分析继续留作报告。按这个新决定，已将**原v5 bitstream逐字节复制**到独立`build/song_sram_trial_v5_20261008/song_sram_trial_v5.fs`，SHA `0981c613cb881247d6381ce2e87f16a919f377a201f729e60ae496d44c0911c2`。不重新综合/P&R，不改RTL/IP/约束、音量、激励、箱体或时钟，不写Flash、不操作Programmer；旧歌曲和测试音SHA保持不变。

此文件仅供用户明确授权的临时SRAM试验，**不是MPW/PVT完整签核放行**，原v5证据目录的拒收记录继续保留。README及manifest明确setup仅1ps、MPW−0.612ns、器件/复位物理条件未核实，并给出≥60s播放、循环、重复启动及I2S测量记录表。实板结果目前待用户反馈。

当前版本没有100MHz观测输出。BCLK属于12.5MHz音频域，不能从其脉宽推断内部100MHz DSP/RAM端点MPW。另做核心时钟观测版须单独标记、重跑P&R、检查IO/探头影响；常温出声不能自动代表全PVT签核。
