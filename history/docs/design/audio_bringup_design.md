# 上板首阶段：自动歌曲与MAX98357A喇叭播放

日期2026-10-04。用户本次目标经澄清为：2B/2C完成之外，烧录后先自动播放歌曲，并打通FPGA到MAX98357A及喇叭的链路，不要求麦克风输入。**板级尚未验收；本文件不把接口名称、引脚数量当作器件识别依据。**

## 当前硬件与交付目标（早期板载/监听方案仅作备选）

**用户最终澄清：就是FPGA→喇叭播放，之前把功放叫成了麦克风。本次不要求麦克风采集或监听。** 主验收为2B/2C实时合成自动歌曲，经标准I2S到MAX98357A及喇叭；下文最初的MIC_MONITOR/RX/监听测试仅保留作历史设计备选，不是本次阻塞项或必交功能。不要为未要求的麦克风采购/协议继续扩展任务。

用户已读出外接模块型号 **MAX98357A**，引脚包括LRC、BCLK、DIN、GAIN、SD、GND及疑似VIN。该器件是**标准I2S输入的单声道Class-D功放，不是麦克风**。用户的2pin喇叭可由它驱动；因此首选播放目标改为 `FPGA→标准I2S TX→MAX98357A→喇叭`，板载PT8211仅为可选的第二输出，不把LSBJ用于MAX98357A。

新增音频实现文件 `rtl/audio/i2s_amp_tx.sv`：音频参考12.288MHz，BCLK=3.072MHz、LRC=48kHz、32bit/slot；16bit有符号示例音频在WS变化后一拍MSB先发送，余下位为0，左右复制同一mono示例。FIFO一对16bit接口可沿用，不冻结C7；transport/demo增加静态输出格式参数，默认**MAX98357A标准I2S**，PT8211须显式选择。两种格式分别用独立解码器验证，不能仅换WS标号。

ADI官方资料确认MAX98357A不需MCLK；SD是关断/声道选择，GAIN设功放增益，均不是音频数据。扬声器输出为桥接，两端均不能接地/接FPGA GPIO。用户已确认VIN、3.3V供电与3W/8Ω喇叭，实际接线及电源带载能力尚需上板检查；不猜模块最后一个未辨识引脚。来源：https://www.analog.com/en/products/max98357a.html ，模块示例引脚参考：https://learn.adafruit.com/adafruit-max98357-i2s-class-d-mono-amp/pinouts （不能自动认定用户板与Adafruit电阻配置相同）。

早期曾询问“麦克风播放链路”是否指监听；用户已明确取消该理解。以下麦克风RX仅为条件性预备模块，不能据此声称已有实物麦克风。

上述目标问题已由用户回答“就是FPGA→喇叭播放”，因此无需麦克风输入器件。尚需确认的是MAX98357A模块供电/接线、FPGA物理输出脚、时钟/工具链和实板自动出声。

用户进一步确认：VIN标注范围**2.5–5.5V**，喇叭额定**3W/8Ω**。该范围不是用户实际已选定的供电电压；电源能力和实接电压仍需核实。按器件手册，5V/8Ω下典型输出约1.4W(THD+N=1%)或1.8W(10%)，不能把喇叭3W额定值等同于此功放必定输出3W。

随后的用户选择已明确：**实际供电3.3V，信号使用空闲PMOD2**。原理图Rev1.2页17的PMOD2插座为J26，供电脚1/2=+3V3、3/4=GND；IO0(C21)=11脚、IO1(B20)=9脚、IO2(B19)=7脚、IO3(A17)=5脚。编号必须结合实板Pin1标记/插座朝向确认，不按照片左右方位猜测。

拟定接线：BCLK→PMOD2_IO0，LRC→IO1，DIN→IO2，SD→IO3（FPGA低=静音关断，高=选left；示例两声道同样数据）。VIN接满足功率/电流要求的3.3V电源、GND共地；PMOD供电能力尚未实际测量，不能以允许3.3V输入就保证带扬声器负载不掉压。GAIN不作为音频数据/动态GPIO；按模块实际电阻/接线确认增益。

`rtl/platform/tang_mega_138k_pro/audio_pmod2.cst`是经原理图核对的**外设约束片段**，使用amp_bclk/amp_lrc/amp_din/amp_sd端口。板级封装已新增top/clock_reset/CST/SDC/预检与构建说明，正在独立审查；真实Gowin生成的两个PLL IP、综合/布局布线仍缺失，片段或行为PLL仿真不能用于认定可烧录通过。

用户提到“TDM模式GAIN固定12dB”，与MAX98357A/B数据手册一致，但这只是**TDM模式规格**，不证明模块目前处于TDM或要求本工程使用TDM。首版继续标准I2S/PCM（LRC为48kHz左右声道方波，BCLK为64×LRC），无需8-slot TDM。I2S模式GAIN_SLOT决定3/6/9/12/15dB档位，实际GAIN脚接法尚未知，不能默认固定12dB。2C内部32声部时分复用与外部音频TDM帧格式是不同概念；内部先混音，再发送左右相同的单声道PCM。

手册来源：`https://www.analog.com/media/en/technical-documentation/data-sheets/max98357a-max98357b.pdf`，包括TDM自动检测(按LRCLK波形)、TDM每帧128/256个BCLK与固定12dB、I2S时序、GAIN档位及8Ω功率表。上板起步保留数字衰减，从低音量测试；喇叭OUTP/OUTN桥接、不接地，不从FPGA GPIO供电。实际Pin/Bank约束及电源接法未核定前不生成假定接线表。

## 1. 板载备选资料与当前阻塞项

本地 `reference_agent_readfirst/tang_mega_138k_pro_basic_resources/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf`，Rev1.2，2024-10-10，页18/19：

- U6=`PT8211-S`，16bit DAC，数字引脚BCK/WS/DIN；PT8211数据手册规定Japanese/LSBJ格式，**不是标准I2S**。
- FPGA标号：DAC_BCK=E22，DAC_WS=F24，DAC_DIN=G24，PA_EN=H17。均是资料查得，不是按其他Mega版本套用。尚需核对用户板修订版、官方完整约束/Bank电压。
- U32=XPT4809，J30为2pin模拟扬声器输出；耳机插入检测可能影响扬声器信号路由。**不能把喇叭直接接FPGA GPIO，也不能将扬声器输出接成逻辑输入。**
- 页17的MIC ARRAY为10pin接口，MIC_D0=N17,D1=L22,D2=L24,D3=R16,WS=T24,BCK=R17，与PMOD0部分复用。
- 早期“7pin麦克风接2pin喇叭”的描述不能作为Sipeed6+1阵列识别依据；现已根据用户确认改为外接MAX98357A功放，不再等待麦克风器件。

来源：官方Wiki链接到 `sipeed/TangMega-138KPro-example` 的 `audio/audio_sinewave/src/audio.cst`，确认E22/F24/G24以及50MHz输入P16、复位U4；官方示例的近似分频**不复用**为48kHz设计。PT8211数据手册：https://www.pjrc.com/store/pt8211.pdf ，WS低为右、高为左，与常见I2S左右标号不同，测试应明确这一点。

**环境最新更正：用户确认Gowin IDE/Programmer已安装于`~/gowin`，license已验证；父会话实际找到`/home/rubbishbro/gowin/IDE/bin/gw_sh`等工具。** 正在接入真实PLL生成与综合流程；此前“无Gowin”的早期检查结果不再作为当前阻塞。当前尚未取得本工程的vendor PLL、综合/布局布线/时序结果；板卡未连接，完整器件后缀、实际PMOD2朝向/接线、3.3V带载与GAIN接法未现场核实。工具存在或用户验证license不等于本工程已能生成可烧录且满足时序的文件。

## 2. 主验收与条件性备选

默认上电`SONG`：ROM音符事件→2B装载→升余弦短激励→2C实时合成→输出适配→异步FIFO→**标准I2S→MAX98357A→扬声器**。板载PT8211另选格式，不接本次MAX功放。

`MIC_MONITOR`历史备选（非本次必交）：确认协议后的麦克风→串行接收→异步FIFO→核心域增益/量化→输出FIFO→按器件选择的串行格式→功放→扬声器。

先分开切换，不默认麦克风与歌曲混音，不默认录音、声源定位或音高识别。现场监听应先低增益/耳机，防声反馈；板载耳机口的MIC触点不是已证明可用的ADC输入。

## 3. 时钟及传输模块（先实现可仿真部分）

核心100MHz；音频参考**精确12.288MHz**，独立PLL/外部参考wrapper后续核定；不能用100MHz整数分频近似48kHz。音频参考/256=48k帧率。

新文件由音频实现任务独占：`rtl/audio/audio_async_fifo.sv`、`i2s_amp_tx.sv`、`pt8211_tx.sv`、`i2s_mic_rx.sv`、`audio_transport.sv`、`song_player.sv`、`audio_demo_core.sv`。传输与歌曲调度测试现位于`sim/unit/audio/`，早期demo隔离测试归档到`sim/archive/bringup_mock/`；运行入口见`sim/README.md`。不修改2A/2BC/冻结清单。板级封装独占platform目录，PLL由真实工具生成，不能以test-only模型替代。

- async_fifo：标准双时钟Gray指针+2FF同步，power-of-two深度>=4；读写valid/ready握手，满不覆盖、空不读取。统一全链路reset，两个域分别同步释放；不声称任意单域reset能保持数据。
- 标准I2S TX（默认）：BCLK3.072MHz、64BCLK/frame、WS低left高right，WS变更后一BCLK才采样payload MSB；16bit有符号mono复制到两slot，剩余位为0。欠载整帧零，脉冲/sticky报告；clear与新欠载同拍由欠载置位优先，clear与有效帧同拍必须清零。
- PT8211 TX：12.288MHz时钟，BCK1.536MHz(音频clk/8)，32bit/frame，两声道各16bit；MSB先，下降沿更改DIN/WS，接收端上升沿采样。每slot**没有I2S一拍延迟**；WS低发送right，高发送left。每帧从FIFO接收一对32bit，帧内固定，欠载整帧输出零且给诊断脉冲。数据LSB对应slot最后一个上升沿，WS在下一slot首bit前下降沿切换。单声道示例两边复制，避免板上扬声器右通道选路误解。
- mic RX：**条件性标准I2S数字麦克风适配器，待实物确认**；BCK3.072MHz、WS48kHz，32bit/slot，MSB在WS改变后一拍，24bit有符号payload，零填充bit不计入数据。FPGA输出WS/BCK，输入SD在BCK上升沿采样。选一个通道，输出24bit sample_valid；高阻/未知模拟输入在有效payload时仿真应可检测。不是PDM/TDM/模拟ADC，也不接功放输出。
- 两串行接口由同一精确音频参考派生，仅核心↔音频跨域；内部用audio_clk clock-enable，不把逻辑生成BCLK用于普通FF时钟。
- transport顶层接受clk_core/clk_audio及共享reset、core_tx_valid/ready/data[32]、core_rx_valid/ready/data[24]、mic_sd；输出DAC_BCK/WS/DIN、MIC_BCK/WS、core_sample_tick(帧边界toggle经2FF同步)、诊断欠载/溢出。TX FIFO默认16对样本，RX默认16样本；状态诊断跨域同步累计或sticky，不能单拍脉冲直穿CDC。rx满丢新样本并sticky报告，不悄悄覆盖旧样本。
- core_sample_tick的toggle跨域前提明确：core100MHz连续运行，采样间隔20.8us；同步链最坏延迟远小于间隔；不承诺核心停钟仍能保留所有tick。
- diag_clear是核心域事件，不能用短脉冲的裸电平2FF同步到慢audio域。当前改为源端上升沿toggle、audio端同步再检出；连续两次清除须留足同步间隔（建议>=1us），不承诺无限速率事件无损。core可见欠载/溢出是已同步的audio sticky，不能额外重复锁存导致清除后旧值再置位。
- 输出适配仅局部示例：Q30内部sum有符号64bit，demo先衰减3bit，再+2^14右移15，共shift18，再饱和int16；系数/状态不变、不冻结C7。mic int24转int16加2^7右移8再饱和；起步额外衰减2bit，现场可参数化调低。不得24/16bit raw unsigned截断。

## 4. 自动歌曲前端

默认曲目为公版《小星星》的短旋律；guitar forte的MIDI60/62/64/65/67/69均在现有系数表覆盖，不移调、不换力度档、不播放PCM。ROM存事件而非波形；脚本或显式常量保存音符序列，可回归核对。

song_player输出与`modal_engine`兼容的load_valid/voice/instrument/midi/dyn，sample_valid/active_mask/x_vec，接收相应ready、load_done/voice、engine out_valid/mix_sum。audio_demo_core示例默认8，board top采用32，可参数化；事件voice按曲内事件序号%NUM_VOICES分配，曲末回到事件0，**不是阶段4自动分配器**。每事件先加载目标槽，成功后在下一次样本开始激励；其他槽尾音保留。当前demo采用42个等间隔事件、note gap默认12000样本，末尾经过同样间隔后循环，不是带完整长短音符时值的演奏谱；默认上电自动开始，不能用忙等冻结音频采样时间线。

固定7采样升余弦脉冲，幅度demo=0.2(Q30)，表值用当前整数模型同样round规则离线生成；计数只在sample请求真正接受时递增，不因valid未握手跳过激励。sample_tick由音频边界发起，pending在有限队列容量内保留；若上一帧未结束或装载未完成导致不能及时处理，置deadline_error并测试，不能无声跳过采样。当前8bit pending满255后饱和，属于已报告的过载，不承诺无限积压无损；正常演示必须不触发deadline。帧/装载在每tick内需要完成，新note操作需预留足够周期；实际整机仿真必须量化，而不是沿用2C1800拍预算就宣称歌曲带装载已满足。

audio_demo_core以两个精确时钟输入集成engine+transport+song_player，mode_song为核心域稳定配置；MIC模式不跑合成帧，rx数据按握手送tx。模式切换在核心域需停止旧producer、排空/统一reset相关数据通路，不能留下歌曲旧帧被当成麦克风样本；首版允许**模式只在reset前设定**，测试两种复位启动，按键切换另做。公开playback_ready在首个core TX真实握手后sticky置位，reset清零，表示生产已开始而非声学验收；平台SD门控必须同时要求锁定与playback_ready，按键复位/失锁立即关断。不能仅见到WS帧计数就使能，更不能always-on宣称安全。

## 5. 可判定测试

1. FIFO不同频率/初相、随机背压/满空/绕回/统一复位，逐字序列相等；实际覆盖wrap至少4次，无X。
2. **主标准I2S**独立协议解码：±边界、MSB/LSB标记、WS低left、后一拍MSB、32bit slot与零填充、BCLK/LRC比例、欠载整帧零。备选PT8211另解码验证无I2S偏移、WS低right、左右不同值。
3. 历史备选mic独立I2S源：24bit±边界、任意填充、WS后一拍、左右选通，接收数值相等；transport跨域回环包含背压/溢出sticky，不只是直接loop同一驱动。此项不阻塞本次播放。
4. song在测试缩短事件间隔下完整循环，核对音符/指定voice/顺序、load背压/sample背压、正确脉冲计数、无虚假deadline；正式事件间隔48k时域确认。
5. 集成SONG：真实ROM与engine，串行DAC解码与Python逐采样整数合成/输出适配对拍，至少4096采样及多个事件；记录每tick的装载+计算最大周期、FIFO深度/欠载。启动静音和首帧欠载允许且明确记录，稳定运行不欠载。
6. 备选集成MIC：行为麦克风源→完整RX CDC核心量化TX CDC串行，复位不能冒出旧样本；不作为本次主链路或实物验收。
7. runner绝对build路径、always=True、显式XML门槛、失败非零、超时；-g2012/-Wall。所有结果区分RTL仿真与实物。

## 6. 真实上板验收（尚待执行）

核对硬件照片/原理图及PMOD2方向→检查3.3V供电/GAIN/SD接线→生成PLL并确认精确频率/lock复位→确认pin/Bank及SDC→Gowin综合/资源/布局布线/时序CDC报告→烧录。低幅启动自动歌曲，检查MAX98357A及喇叭出声。无需麦克风或板载耳机选路。

验收记录包含板/模块型号与接线、bitstream/工具版本、资源时序报告、测得48k LRC与3.072MHz BCLK、曲目自动启动、稳定运行≥60s、启动/稳定欠载及溢出状态；确认复位静音、供电不明显掉压、不异常发热。未取得这些记录前，本项目最多标记“RTL数字链路通过，实物链路待验证”。
