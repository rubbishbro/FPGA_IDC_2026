# 共享箱体首版设计与验收规格

本轮用户已选“工程＋箱体”，进一步选择**先闭环guitar**。目标是补齐当前guitar歌曲的显式残余箱体滤波；四乐器分别生成系数并单测，不在此轮增加多乐器混奏分组，不宣称噪声/note_off/声部分配/方案C已迁移。

## 1. 参考与边界

- 参考`python/modal_sim/params.py`的`Patch(name).sos`与`BodyFilter.process`，默认48kHz、4个biquad/8阶。只读调用现有拟合函数，不修改参考/原始FFT参数/原模态ROM。
- `params.py:212–216`实际权重已含录音中的箱体着色；本模块补参考中的去趋势残余滤波，不是重新添加全部箱体频响。
- 原`engine.py:231`噪声在独立支路整形后与箱体输出相加，本轮不把噪声误放到箱体前，也不假称加箱体就完成原始算法所有迁移。
- 四种乐器有不同SOS。共享是同一乐器所有声部共享，不能把四乐器全局混音统一过guitar滤波器。本轮演示只有guitar。
- 正式数学参考仍48kHz。用户另允许12.5MHz音频时钟**仅用于先出声诊断**（实际48,828.125Hz），不据此重新拟合/修改系数，不宣称48k保真已通过。

## 2. 数值方案（局部模块，不改原冻结列表）

父会话实际检查四个Patch.sos：全部(4,6)，a0均1；最大系数绝对值分别guitar1.9357073、piano1.9836901、banjo1.8373200、mandolin1.9493552；最大极点半径分别约0.969547/0.992042/0.960082/0.973618。

- 系数为有符号32bit **Q2.30**，离线`floor(c*2^30+0.5)`。每section存b0,b1,b2,a1,a2，a0规范化为1；严禁静默夹系数，越界/非有限/不稳定应拒绝。
- 输入和输出为有符号64bit、30小数位，与现有`mix_sum`一致；**内部增加4个小数保护位，所有section的x1/x2/y1/y2为signed68/Q34**。首级输入无损左移4，四section之间连续使用Q34，仅末级输出转换回signed64/Q30。不能提前压成原模态32bit状态，否则32×48混音被截断。
- Direct Form I，section顺序与原SOS一致：
  `acc=b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2`。
- 五个乘积各有符号100bit（68×32），累加器至少104bit，所有项先显式符号扩展再相加/相减；每section仅最终一次舍入`(acc+2^29)>>>30`，饱和到signed68，更新该section状态。末级再`(y+8)>>>4`转为Q30并饱和signed64；最终转换饱和并入section3的bit。记录每帧4个section的饱和bit/count（同section至多计1），不能用wrap冒充正常结果。
- DFI与Scipy内部TDFII在无限精度下等效，但有限精度不同：RTL必须与新增DFI整数模型逐位一致，整数模型另与**原始SOS浮点sosfilt**评估误差；不要求RTL与浮点bit-for-bit。
- 复位取消全部token并清所有历史；可设置单独同步clear，仅空闲接受，保留系数。参数/接口需明确reset/clear/sample优先级，忙时不许写历史或接收新样本。

局部数值修正依据：父会话对四原SOS独立运行1冲激+4096随机±0.5+65536静默。初始内部Q30方案piano残余约1.0617e-6，超过2e-7门槛；不能靠zero阈值或改原浮点参考消除。改为上述内部68/Q34后四乐器峰值误差分别约9.77e-9/7.79e-8/8.37e-9/3.88e-8，末4096样本残余分别7.45e-9/5.77e-8/1.86e-9/4.66e-9，均满足门槛。此为父会话数值预检，不是尚未交付的RTL测试通过。

## 3. 数据通路与接口

新增`rtl/core/body_filter.sv`；一个共享68×32乘法数据路径，顺序调度4×5=20个乘积，可显式流水以满足100MHz。允许FF实现小状态阵列；不声称只需一个物理DSP（Gowin DSP宽度可能拆分）。

建议端口：clk/rst_n、clear_valid/clear_ready、in_valid/in_ready/in_sum[63:0]、out_valid/out_sum[63:0]、out_sat[3:0]/sat_count[2:0]。输出out_valid单拍、无反压，与现有engine契约一致；输入只在valid&&ready接受。参数BODY_INSTRUMENT=0..3、BODY_FILE，静态instrument只在复位前改变，每个实例只保存一个箱体状态。ROM文件为80×32bit、顺序instrument(guitar/piano/banjo/mandolin)→section0..3→b0/b1/b2/a1/a2。可实现同步ROM预加载后再提供ready，禁止初始化文件丢失时伪造有效零滤波。

**周期门槛：单帧从输入握手到out_valid<=128个100MHz核心周期**；必须实测，连续发送方必须等ready而不是看到out_valid就假定同拍可再次接收。

新增离线生成器`python/modal_sim/gen_body_rom.py`，新增独立整数模型`python/modal_sim/body_fixed_point.py`、`rtl/rom/body_coeff.mem`/`body_manifest.json`。不改旧fixed_point.py、params.py、engine.py、gen_hw_rom或原模态ROM。manifest含浮点SOS、量化整数、布局、来源/参数、量化极点半径、文件hash。生成可重现，坏源/非法参数不可写一半污染旧输出。

## 4. 集成（单独闭环，不破坏旧回归）

在`audio_demo_core`增加静态ENABLE_BODY参数，旧回归默认0保留基线；ENABLE_BODY=1且MODE_SONG时，真实modal mix先过body再进入sum_to_i16。BODY_INSTRUMENT=0用于guitar；MIC备选不自动经过本箱体。允许输入保持缓冲吸收engine单拍out_valid，不能默默丢样/覆盖。忙或TX无法及时接收的新样本应sticky诊断，并实际测试正常48k稳定期不触发。

本轮实现者可修改`rtl/audio/audio_demo_core.sv`及自己的新增body测试，但**不得修改平台文件、父会话review、原2A/2BC/core计算或旧正式tests**。板级实现会话同时修真实构建，父会话在body功能审查后再安排平台BODY开关，避免交付混用旧网表。

## 5. 测试门槛

1. 生成器从四个原Patch.sos逐系数量化一致，80词布局/位宽/稳定性/可重现/hash准确；非法系数和非有限/unstable拒绝且不破坏已有输出。
2. 四instrument各冲激/负冲激/阶跃/交替符号/确定随机序列（至少4096样本）、多种幅度（含32bit外的64bit输入）、静默尾巴，RTL每section/最终状态与DFI整数模型逐位一致。至少一个正负64bit饱和案例、饱和计数准确，不提前int32截断。
3. reset各计算阶段取消，无幽灵out_valid；clear仅清历史，不改系数；busy毒化in_sum不影响已接受输入；输出只一次；周期<=128；准备信号复位期间不虚报握手。
4. 整数与原Scipy SOS比较：至少冲激/随机/当前真实guitar模态歌曲；正常幅度无饱和；报告绝对峰值误差、RMS误差、频响误差及量化极点稳定性，初始门槛单位输入幅度下峰值误差<=1e-5、20Hz..20kHz频响误差<=0.01dB。不足门槛须解释/修数值方案，不能改原浮点参考。
5. 长静默检查（至少65536采样整数模型，RTL可选抽样/较短尾巴但明确区分），记录极限环残余，与当前FS30一致控制：目标输出绝对值<=2e-7（归一化单位），不得自动zero阈值篡改递推。
6. 真实guitar歌曲→modal_engine→body→适配→FIFO→标准I2S，至少4096样本对新增完整整数链逐位一致；包含多事件与重装，不重置共享箱体历史；启动静音与稳定欠载分开报告，稳定欠载/deadline/overflow为0，测整帧预算。
7. old ENABLE_BODY=0的原音频回归不回退；runner绝对build目录、always=True、-g2012/-Wall、XML失败/空用例非零、有限超时、不写sim/results.xml；实际工具结果不以自述代替父会话复跑。

## 6. 硬件与交付

body功能验证完成后，再对接Gowin顶层重新综合/布局布线；不能把此前ROM没加载、阵列被优化掉的provisional bitstream视作本模块硬件结果。无需板卡即可做前述工作；上板出声/完整part确认由实物验收负责。

交付中文实现报告：文件/接口/资源逻辑说明、测试命令/退出码/XML/周期、float↔integer误差与残余、修复闭环、未完成噪声/控制/混奏/实板范围。父会话独立审查与补测后才判定接受。
