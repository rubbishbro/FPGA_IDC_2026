# 歌曲首帧无声：装载元数据修复与验收

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期：2026-10-07。原失败的逐拍证据见[网表启动复审](song_startup_netlist_review.md)。本文件记录修复，不覆盖原歌曲文件或独立测试音。

**本轮最终状态：保留v1最小功能修复，撤回本轮v2/v3优化试验（均保存在独立快照）。首帧功能错误已关闭；100MHz物理时序未关闭，没有可上板放行的新文件。当前bank与已验v1逐Verilog token一致，仅precheck说明文字不同。**

用户随后授权继续；最新基于真实DSP地址路径的收敛工作见[控制/配置地址时序验收](song_control_timing_review.md)。本文件v1–v3作为历史证据保留。

## 1. 实际故障与修复范围

原生产网表中，首音符27次cfg的系数存在位确实写入RAM；但原网表从RAM读回到`lowest_missing`下一值的组合计算在mode17～26不等价。最终`low_unloaded[0]=16`，与引擎记录的27不一致，bank拒绝首帧、engine等待永不完成、没有PCM写入、`playback_ready=0`。不是音频FIFO写ready无法变高，也不是需要强拉SD。

修复仅改变`rtl/core/modal_poly_bank.sv`的元数据实现：

- 用`g_meta[voice]`的常量索引，每声部独立的packed `loaded_r`/`prefix_r`寄存器。
- 合法cfg握手时，独立寄存器自反馈加入该mode，再从**含本次配置位**的位图计算前缀。
- 删除主FSM中的动态索引元数据写入/复位，避免多驱动。
- 顶层`coeff_loaded`/`low_unloaded`数组保留只读观测连接。

同步reset优先、clear保系数、任意顺序/重复配置、非法请求无副作用、下一拍看到新前缀，全部保持。**不改合法性检查、引擎等待策略、ROM、lane算术/II3、body、FIFO、I2S、PLL或约束。**用户正在添加的中文阅读注释保留；修复外生产RTL/IP经去除注释及ROM路径重定位后，与原冻结版本逐token一致。

## 2. 父会话独立RTL验收

以下为v1验收：使用源快照`/tmp/opencode/song-metadata-core100-20261007/parent_source_snapshot/`重新编译、运行并检查非空XML。没有将DS执行结果直接作为父验收。

| 项目 | 当前结果 |
|---|---|
| 元数据矩阵：32×48、1×1/17/33、3×1/17/33 | **21/21通过** |
| 满载bank SKIP0/1 | **6/6通过**，最大1506周期 |
| 满载engine SKIP0/1 | **6/6通过**，最大1508周期≤1800 |
| 实际生产wrapper，256黄金样本、guitar箱体、12.5MHz | **1/1通过**；257外部I2S帧，启动后输出，锁失/复位静音 |

元数据覆盖乱序、边界15/16/17/23/24/31/32/47、补洞、重复配置、交错声部、clear保留、非法mode/voice、缺mode同握手拒绝、busy期间cfg不接收、reset/cfg和clear/cfg优先级。

既有bank/engine测试还检查完整64bit黄金和、历史提交、饱和计数、冻结声部、失败load保持和严格拒绝副作用；没有用“能出声”替代数值验收。

测试目录：`/tmp/opencode/song-metadata-fix-review/{metadata-with-interleave,bank-skip0,bank-skip1,engine-skip0,engine-skip1,production-rtl}/`。

## 3. 新增真实网表功能门槛

新增`sim/test_song_netlist_review.py`，直接实例化原生产综合网表中的`audio_demo_core`，使用**完整、未修改的厂商原语库**和实际100MHz/12.5MHz测试时钟。

- 64bit模态和与原始系数独立黄金模型比较。
- 从外部BCLK/WS/DIN按标准I2S逐位解码，检查左右mono一致、延迟位/填充零、样本顺序及非零PCM。
- 检查启动、复位清ready、复位后重新装载并输出。
- 不用force、不替换bank/lane/body/ROM/FIFO、不放宽黄金。
- 边界：零延迟功能仿真，PLL/PLL_INIT/板级reset和真实PVT不在此夹具内；不是实板已出声证明。

门槛负控制：原歌曲网表在frame2失败，`L=0000 R=0000 want=0010`；说明能抓住原静音故障，不是只检查ready。对应夹具以原冻结RTL适配相同端口，两个复位阶段均通过，确认解码/黄金对齐正确。

**v1真实综合/P&R及网表功能检查已完成；loaded_r/prefix_r为寄存器，coeff_loaded/low_unloaded不再被提取为RAM。网表功能通过，但v1的100MHz时序未通过，不能交付。**

父会话亲跑v1原始综合网表＋完整未修改vendor库：上电和reset后重启各16个有效PCM样本，合计34个完整外部I2S帧（含两次启动静音帧）、34个完整64bit模态和、30个非零帧，均与独立黄金一致。`playback_ready`正常置1、复位清0、重新装载再次输出；没有force或RTL替换。结果`SONG_GATE_FUNCTION_PASS`，证据`/tmp/opencode/song-metadata-fix-review/fixed-gate-v1/{run.log,result.json}`。

v1报告：setup186、hold0，Fmax97.329MHz，最坏setup−0.274ns/TNS−21.915ns；15397logic、8921FF、0latch、52BSRAM、15DSP。MPW−0.512ns。新增全局cfg_mode到逐voice prefix计算的路径也进入负裕量表，且更大的布局影响原lane路径。

后续v2仅针对元数据反馈：由于存在位只置1，只有填上当前最低缺失位时前缀才会推进；无需让全局cfg_mode每次参与每voice的完整优先编码。不改时钟和约束，不将v1生成.fs视为放行。

## 4. 构建与交付边界

新增`sim/build_song_metadata_review.py`：拒绝覆盖已有证据目录，冻结实际源和ROM，仅在副本重定位ROM绝对路径；使用原core100器件/工具选项、100MHz及12.5MHz和原CST/SDC，无latency覆盖、降频或时序切割。

v1真实构建目录：`/tmp/opencode/song-metadata-core100-20261007/`。实际输入SHA与原路径保存在`parent_source_snapshot/sources.json`；v1 bank SHA=`9368747a1918995e38e3a7897e64ddb6577ecfe34b8830fb56649a22fcd6c990`。

原主工程MPW、PLL动态抖动覆盖和完整外部时序/CDC最终审核仍单独OPEN；修复元数据不自动解决这些问题。若新报告失败，必须具体记录，不能把“生成.fs”写成“STA通过”。

**目前没有交付新bitstream，也没有操作Programmer或写Flash。**

## 5. v2：只在填上当前最低缺失位时推进

v2代码仍为逐voice寄存器，只改前缀更新：

```systemverilog
loaded_r <= loaded_r | (MODE_ONE << cfg_mode);
if (cfg_mode == prefix_r)
    prefix_r <= lowest_missing(loaded_r | (MODE_ONE << prefix_r));
```

等价性：mode小于prefix时，该位本已存在；大于prefix时最低空洞仍存在，两种情况下prefix都不变。等于prefix时两个移位量完全相同，必须在同边沿推进。prefix=N_MODES时所有位已存在，合法mode不可能等于该哨兵，不会越界更新。

因此全局cfg_mode不再穿过每voice的48bit前缀计算D路径，只参与loaded置位及短的prefix等值判断；前缀数据路径改为局部寄存器反馈。不新增调度周期，不降低非法帧要求。

v2源快照：`/tmp/opencode/song-metadata-core100-v2-20261007/parent_source_snapshot/`；bank SHA=`d3a41832320600fc7ebb5151bbbe3341ff72306076619263a1cbcfde0c7ea449`。

父会话已对v2重新编译、独立跑完并检查非空XML：**34/34通过**，包含上述21个元数据、bank/engine SKIP0/1共12个和生产wrapper256黄金样本1个测试。证据`/tmp/opencode/song-metadata-fix-v2-review/parent_rtl_acceptance.json`，不是复用v1结果。

v2综合映射独立检查：32个声部都可见独立metadata DFF，合计1728个命名metadata DFF（48+6位×32）；未发现metadata RAM实例。原始综合网表SHA=`996771300c25c83c7765c28054e164a87d25eed7f7cd7cf2e564576b1d4b24dc`，结构证据`metadata_mapping_check.json`。

v2真实网表功能亦亲跑通过：两个启动/reset阶段各16个有效PCM，34个完整I2S帧/34个64bit模态和/30个非零帧均与黄金一致，日志`fixed-gate/{run.log,result.json}`。**但v2物理结果更差，拒收**：17612logic、8921FF、0latch、52BSRAM、15DSP；setup623、hold2、Fmax91.346MHz、最坏setup−0.947ns、MPW−0.512ns。两条hold实际在TX FIFO Gray指针到音频域第一级同步器，最坏−0.132ns，不误称为removal，不新增例外掩盖。

v2增加的局部变量移位仍带来逻辑/布局开销，不能因“局部反馈”这个理论方向声称优化有效。随后v3只在同一元数据块内改为静态平衡树，从位图求第二低空洞索引，在填上第一低空洞时采用该值；结果如下，未因理论复杂度更低而放行。

## 6. v3拒收与最终代码选择

v3独立RTL回归**34/34通过**，32声部metadata仍为1728个DFF，没有metadata RAM；证据`/tmp/opencode/song-metadata-fix-v3-review/{parent_rtl_acceptance.json,metadata_mapping_check.json}`。

但真实P&R再次恶化：18116logic、8921FF、0latch、52BSRAM、15DSP；setup2652/hold0，Fmax72.940MHz，最坏setup−3.710ns，TNS−2639.168ns。最坏从engine n_modes寄存器到bank状态CE，说明不能只盯元数据局部D路径而忽略全局布局/控制扇出。

v3网表音频夹具**在编译前端口检查处停止，未执行功能仿真**：Gowin将原`n11_5`复位输入改名/拆成`n11_6/n11_7`，夹具按严格端口校验拒绝自动猜连接。这是测试适配待查，不是已证明的v3数据功能失败，也不算v3网表通过。因物理时序已明确不合格，本轮不为拒收候选继续扩展夹具或修改冻结lane。

最终仅撤回本轮v2/v3引入的元数据函数和更新表达式，保留v1逐voice寄存器修复。用户在修复范围外的源码/注释全部保留，不还原整个文件或工作区。

- 当前bank SHA：`2f52e0077fc2eebd92ed9c074ebd75a3c2be547ae92af7f3edd7a0a904c23c47`。
- 已测试v1 bank SHA：`9368747a1918995e38e3a7897e64ddb6577ecfe34b8830fb56649a22fcd6c990`。
- 独立检查当前与v1全部Verilog token完全相同，只将旧注释的`lowest_missing[v]`纠正为实际数组名`low_unloaded[v]`。证据`/tmp/opencode/song-metadata-fix-review/final_source_selection.json`；不为注释变化重新构建后冒称有新的物理结果。

| 候选 | 独立RTL | 真实网表功能 | 真实100MHz物理 | 最终处理 |
|---|---|---|---|---|
| v1 | 34/34 | 两次启动/重启、34帧黄金通过 | 97.329MHz，setup186 | **保留代码修复，拒收下载放行** |
| v2 | 34/34 | 同样34帧通过 | 91.346MHz，setup623/hold2 | 撤回本轮优化，仅保留证据 |
| v3 | 34/34 | 端口校验停止，未执行 | 72.940MHz，setup2652 | 撤回本轮优化，仅保留证据 |

下一步需要合法的100MHz控制扇出/布局/元数据结构时序收敛，并继续审查原MPW/PLL/CDC模型；不以改变Fs/core频率、关检查、切路径或直接试听替代。**本次未完成到可交付实板歌曲版本，不能使用原失败.fs期待修复自动生效，也不能将临时构建目录里的.fs当作已验收文件。**
