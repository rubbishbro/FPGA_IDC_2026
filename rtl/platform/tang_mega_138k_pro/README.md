# Tang Mega 138K Pro 整版第一阶段

统一入口为instrument_board_top：压力/摇杆、双UART通信、真实UI配置后端、loader/双bank合成和I2S接在同一工程。没有并列例化pad_voice_top，只有一套midi_voice_top/voice_router。

2026-10-30迁移origin/board50@6183395d后，LCD同时接真实菜单、4×4引导及合成PCM的FFT/波形/极坐标历史页。PCM抽头使用独立24bit异步FIFO进入像素域；FFT及全部显示后处理留在同一像素时钟域，不反压I2S/PT8211。首次完整频谱发布前输出零，不读取未初始化显示bank。

2026-10-31 操作方向及音量更新：板级默认 `PCM_HEADROOM_BITS=1`（原3，未限幅信号振幅提高4倍，约+12dB，保留舍入/饱和），`LCD_ROTATE_180=1`；摇杆设置为交换XY并同时反转两轴，相对旧方向为下→左、上→右、左→上、右→下。频谱列索引和极坐标扫描补偿随旋转同步调整。5项专项测试、v2 整板综合/PnR 及 SRAM 下载均通过，用户确认当前音量/方向版本实测通过；下载记录见[编辑器插件与板级下载](../../../docs/history/2026-10-31/编辑器v2插件与板级下载_2026-10-31.md)，功能验证详见[本轮记录](../../../docs/history/2026-10-31/板级音量与方向调整_2026-10-31.md)。

2026-11-01 音量追加调整：当前板级默认 `PCM_HEADROOM_BITS=-1`，相对 10 月 31 日已验收的 1 再提高约 12dB（振幅 ×4），保持饱和限幅。构建采用上次已验收提交加本次增益修改的隔离快照，不包含工作区的压力垫实验改动；[本轮记录](../../../docs/history/2026-11-01/音量追加12dB.md)。

## 时钟、复位及资源

| 域 | 来源/频率 | 用途 |
|---|---|---|
| clk | P16板载50MHz | 单个真实厂商PLL的参考 |
| clk_core | 50MHz | 通信、压力驱动、UI loop/dispatch、MIDI、合成 |
| clk_audio | 12.5MHz | I2S分频4，BCLK=3.125MHz，Fs=48.828125kHz |
| clk_pix | 33.333MHz | LCD扫描/字模/菜单快照 |

12.5MHz是已可实现的上电调试参考，48kHz资源播放速度/音高有+1.725%偏差。不能称精确48k；旧50MHz→12.288MHz的非法PFD配置不在本工程。ip/内厂商PLL及PLL_INIT使用800MHz VCO，三个输出分别除16、64、24；功能域分别运行50MHz、12.5MHz、33.333MHz，CDC握手保持独立。生产清单无history依赖、无行为PLL。独立厂商GW5A模型已验证完整初始化后的三路频率及50%占空比；该结果不能代替布线后的最小脉宽检查。

PLL失锁或rst_n拉低，所有域共同异步断言复位；各域独立三级同步释放，sidebar及音频内部仍保留各自的CDC复位，voice_router对七个高扇出DSP子树分别同步释放。日常清音改为同步请求和实际清理完成屏障，不通过业务逻辑生成异步复位。功放SD在复位/失锁/音频故障时拉低，BCLK/WS在正常配置和装载期间持续发送静音。

默认RESOURCE_MASK仅钢琴、NOTE_BANKS=0，兼容当前入库16音piano_flash.bin。UI不会开放不可用的音色和音组。正式六音色32音镜像合并后，再设置NOTE_BANKS=1、FIRST_MIDI及对应RESOURCE_MASK；不在第一阶段擅自更换布局或烧录。

## 建议接线

LCD/按键沿用现行ui_demo.cst；压力/LED采用origin/boardtest的4abc8b19逻辑修复；压力行与MUX管脚采用origin/board50的af4afc7a实板修正。PMOD、ADCV、DBG_UART逐项对照仓库Dock原理图第5/16页。所有数字信号为3.3V。

注意参考分支README曾把压力连接器写成J22/PMOD1；按原理图实际为**J24/PMOD1**，J22是PMOD0。本工程按FPGA管脚核对，使用正确连接器标号。

| 外设 | 接口 | FPGA管脚/信号 |
|---|---|---|
| LCD、复位、两按键 | 原LCD排线与板载按键 | 完整RGB/DE/CLK映射见instrument_board.cst；rst_n=G16、key0=F15、key1=G15，均低有效 |
| 有线串口 | 板载USB-UART | FPGA RX=N16，FPGA TX=P15；主机115200 8N1，SLIP/CRC协议v1 |
| 压力行0/1/2/3 | J24 pin11/9/7/5 | H14/L17/E25/C24 |
| MUX SEL0/1/2 | J24 pin12/10/8 | D25/L18/B24 |
| 点阵LED DIN | J24 pin6 | H15 |
| 压力板模拟输出 | ADCV_P / ADCV_N | N12接模拟输出、P11接GND；专用ADC引脚不写普通IO_LOC |
| 板载128Mbit Flash CS/SCK | 板载MSPI | P18/H13 |
| Flash DQ0/1/2/3 | 板载MSPI | R14/R15/P14/N14，分别SI/SO/WP/HOLD |
| 外接功放 I2S BCLK/WS/DIN / SD | PMOD2，83d7c223新版转接板 | A19/A18/B21/A17；GAIN=A20由外部接3V3，FPGA不驱动 |
| 板载PT8211 BCK/WS/DIN | 底板U6 → J29 | E22/F24/G24 |
| 板载耳放使能 | U32 XPT4809，PA_EN | H17，高有效 |
| HC-05 TX→FPGA RX | PMOD0 | R16（uart_rx[1]） |
| HC-05 RX←FPGA TX | PMOD0 | R17（uart_tx[1]） |
| HC-05 STATE→FPGA | PMOD0，可选 | T24；默认BT_HAS_STATE=0，接并启用后才检测物理断连 |

蓝牙会话 v2 试验入口：板级参数 `BT_PROTOCOL_V2=1`，手机按
[v2 合同](../../../docs/蓝牙会话协议v2_实现约定.md) 握手后才能发送业务；默认仍为 v1。
接好 STATE 后另设 `BT_HAS_STATE=1`；未接 STATE 时 v2 仍可依靠心跳撤销会话，
HELLO 可在来源隔离期间到达，不依赖板级固定为 0 的 `session_restart`。
本次协议仿真不构成该参数组合的整板时序或实物验收。

三个PMOD的pin1/2为+3V3，pin3/4为GND，接线按板上Pin1标记核对。本版使用板载Flash，PMOD0改接蓝牙。Flash须装入匹配镜像；loader每次加载前发送06h及01h（SR1=00、SR2=02）开启QE，并等待20ms，再执行6Bh读表。该过程会写状态寄存器，不写系数区；必须确认镜像所在地址不会与FPGA配置数据重叠。

PMOD0和板载UART RX含SSPI/CPU复用脚，build.tcl显式启用use_sspi_as_gpio/use_cpu_as_gpio/use_mspi_as_gpio；本设计不使用AE350或SSPI硬核。MSPI管脚在用户逻辑运行时用于读取板载Flash，下载与启动行为须按板卡流程验证；JTAG仍用于调试。SSPI复用选项见[Gowin Tcl官方手册](https://cdn.gowinsemi.com.cn/SUG1220E.pdf)。

## 输入及配置接线

pad_driver保留主线的泄放/建立/完成沿sticky/超时重试FSM，未用分支旧定时盲读替换。板级LED由`pad_led_effects`以200Hz全查表渲染明暗行波和16条sinc波纹，64像素写满后交给带busy/frame_done的串行驱动；逻辑坐标保持行=y、列=x，每垫对应2×2灯区。原始ADC字节16约0.5V：板级将正压力乘4并饱和，on/off门限64/48对应原始16/12；负电压噪声按零处理。灯效共用该标定后的压力：>64触发、<48释放，门限之间保持原状态；按下时以该垫左上灯在已显示背景帧中的相位锁定整条波纹的颜色，主峰/旁瓣只变亮度。波宽0.65格、速度6格/s，满16条替换最旧记录，重叠取占优波纹。ROM原始数据14.625KiB，无运行时乘法器；实现说明见[PAD_LED_EFFECTS.md](../../drivers/PAD_LED_EFFECTS.md)。此次未重跑综合/仿真或烧录，不能将旧验收结果视为新灯效的验证。原始fmap/摇杆快照仍可检查；最终压力标定需实板测量。

sidebar的摇杆启用逐轴死区输出：未进入方向的轴输出0，采用board50实板参数200进入/100退出的迟滞，板级当前采用JOY_SWAP_XY=1、JOY_INVERT_X=1、JOY_INVERT_Y=1（2026-10-31旋转屏幕后的新坐标系），防止横推时另一轴噪声移动光标。默认joystick_adapter行为保留兼容。LCD扫描为严格800×480，板级逻辑坐标旋转180°，菜单布局/字模分拍计算，RGB/DE统一延迟4个像素时钟后输出；数值及滑条位置在消隐期准备。通用未旋转sidebar的两张画面像素哈希保持不变，板级旋转另有逐像素验证。

comm事件data/source直接接真实MIDI消费者，quarantine接source_cleanup_req；真实source_cleanup_done/source_ops_idle/midi_ops_idle反馈到session_ctrl。未选来源事件明确消费，按键菜单切换PAD/有线/蓝牙，不伪造音符。

本地“输入→演奏来源”选择有线／蓝牙后，可在“演奏方式”选择“引导演奏”：MIDI只点亮目标，压力垫沿用所选通道音色发声；切换来源将方式原子复位为自动。引导显示有独立整包CDC、实际16键音高表和压力门控反馈。选项在PAD来源下禁用，不改变v1线上协议。详见[MIDI引导合同](../../../docs/MIDI演奏与通信接入.md#midi-guide)。

线上CONFIG首版只有REVERB_SET映射0200并经UI loop/dispatch及真实音频后端完成，最后才回v1结果；保留物理来源、SEQ、command、长度和shadow至退休。EQ返回NOT_READY，不伪造DSP提交；权限0502由本地菜单设置，bit0有线/bit1蓝牙，拒绝远程自授权，协议没有DENIED时映射NOT_READY。重复配置缓存仍由原parser维护。

加载故障时MIDI屏障保持阻塞；使用本地菜单“清音”(8001)或整板复位恢复后，再继续远程配置。CRC/串口故障按源清理并隔离：有线用整板复位重建会话；HC-05启用STATE后可由重新连接产生restart。8002通信重启菜单尚无消费者，不开放该能力。

## 构建与验证

在仓库根目录：

先检查生产源清单及引脚：

```bash
python3 rtl/platform/tang_mega_138k_pro/check_board.py --out build/board_sim/pins.json
```

仅综合（显式关闭PnR，使用独立输出目录）：

```bash
QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software \
  BOARD_PNR=0 INSTRUMENT_BUILD_DIR="$PWD/build/manual_syn" \
  /home/rubbishbro/gowin/IDE/bin/gw_sh "$PWD/rtl/platform/tang_mega_138k_pro/build.tcl"
```

综合、布局布线及自动时序验收：

```bash
QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software \
  BOARD_PNR=1 INSTRUMENT_BUILD_DIR="$PWD/build/manual_pnr" \
  /home/rubbishbro/gowin/IDE/bin/gw_sh "$PWD/rtl/platform/tang_mega_138k_pro/build.tcl"
```

通过后的bitstream位于 `build/manual_pnr/instrument_board/impl/pnr/instrument_board.fs`，
验收记录为 `build/manual_pnr/acceptance.json`；时序失败时脚本返回错误，并将bitstream标为 `.fs.UNVALIDATED`。
两条构建命令不会覆盖 `build/eng1_pitch/board_pnr` 的已验收产物；重复运行会覆盖各自manual目录。
蓝牙 v2 测试构建在命令前增加 `BOARD_BT_PROTOCOL_V2=1`，并选择独立输出目录。
构建脚本在该目录生成顶层参数变体及 `build_profile.json`，有线 UART 仍使用 v1；
不传此变量则保持源码默认的蓝牙 v1。编辑器连接方式见 [上位机说明](../../../web/midi-editor/README.md#v2-会话插件与无手机测试)。
板级功能仿真入口为 `python3 sim/run_board.py`。

sources.f为唯一完整板级源清单，构建产物默认在build/instrument_board，可用INSTRUMENT_BUILD_DIR指定隔离目录；构建脚本本身不执行烧录，本轮 SRAM 下载结果见文首归档。仿真只替换PLL、ADC和Flash外设，UART字节驱动、解析、实体按键、PAD扫描、菜单、UI后端、loader/引擎、I2S和LCD使用生产RTL。独立LCD单测检查两帧的800×480有效像素和1192×533时钟；摇杆单测检查横向/对角进入、迟滞退出、回中及失联。附加回归覆盖停钟/复位CDC、同步效果器清理、两引擎满16槽供样、PCM逐位等价、配置范围/比较等价及LED线端波形等价。`python3 sim/run_board_pll.py`独立使用厂商GW5A模型，不使用板级行为PLL。

完整日期化结果统一见[工程验证](../../../docs/工程评审与验证.md)，后续整机问题维护在[台账](../../../docs/bugs.md)。本阶段的构建/仿真不代表实物接线、模拟ADC、音高准确性或DAC听感通过。

以下为迁移前100MHz版本的历史结果，不是当前50MHz源码的时序验收：

2026-10-29时钟域修改后：28个RTL测试顶层通过，另有3项Python时序门禁测试；整板用例含3722帧I2S线端对拍、555帧非零。真实Gowin综合/放置/布线完成，47端口无引脚冲突、单PLL三输出合法。**时序验收仍失败**：core报告Fmax72.019MHz（目标100），pix46.540MHz（目标33.333，已通过）；4774个setup违反端点，hold为0，recovery/removal最差分别+0.938/+0.256ns，最小脉宽slack=-0.551ns。最差数据路径已转移到ADSR和混响，具体代码位置见[本轮验证](../../../docs/工程评审与验证.md#clock-domains-2026-10-29)。

资源为47913/138240逻辑（35%）、20516/139140寄存器（15%）、110/340 BSRAM、146/298 DSP、1/12 PLL。相对第一阶段36627逻辑/19065寄存器，逻辑增加11286、寄存器增加1451；包含实现流水及工具的时序优化/复制成本，不能称零占用变化。系数/状态RAM格式与BSRAM数量不变。最终报告在build/instrument_board，本轮存档和源指纹在build/clock_review/phase7。

check_board.py --timing读取实际报告，任何违反返回非零；build.tcl保留实现结果，但将失败的.fs标为.fs.UNVALIDATED并终止验收。不要将“PnR生成文件”当作满足目标频率。第一阶段接线/功能已完成，物理时序问题归I04，尚未烧录。

## 双声道位置输出（2026-10-29）

正式板级默认 `STEREO_ENABLE=1`、`STEREO_PAN=16`、`STEREO_ITD_ENABLE=1`，居中左右各为181/256，替代旧的左右等于原始单声道。MIDI/PAD共用输出模块，原 `sample_valid/sample_value` 仍是空间处理前的单声道。位置控制不复用菜单摇杆、不新增物理引脚。

`instrument_system.pan_position` 为同 core 域0..32动态输入，`itd_enable` 为辅助时差开关；`instrument_board_top` 目前用参数 `STEREO_PAN` 提供固定位置。试听往返移动时设置 `STEREO_AUTO_SWEEP=1`；每 `SWEEP_HOLD_FRAMES=3072` 个真实I2S帧前进一档，端点自动折返，默认完整往返约4.03秒（当前48.828125kHz）。`STEREO_ENABLE=0` 显式选旧单声道复制旁路。

板载PT8211及耳放现已接入J29，可用3.5mm线接有源音箱AUX。外接MAX98357A的喇叭功率端不可接AUX。外部I2S与板载PT8211共享同一对FIFO样本，分别使用各自的串行格式。新增模块独立综合及功能回归见[双声道方案](../../../docs/双声道空间定位方案.md)。本次没有烧录，也未重新宣称整板PnR通过；上文已有时序失败仍需单独处理。

## board50 整版对齐（2026-10-29）

对齐远端 `origin/board50` 的 `d47b14df`：主PLL改为50MHz、SDC与验收目标同步更新；核心CLK_HZ=50M，按键消抖/长按仍为20ms/800ms。音频12.5MHz、像素33.333MHz保持其原频率。模块名 `Gowin_PLL_core_100M` 为兼容现有工程保留，实际输出以PLL参数和SDC为准。

ROW0..3=H14/L17/E25/C24，SEL0..2=D25/L18/B24，LED=H15。摇杆板级进入/退出阈值为200/100 ADC counts，上电校准时保持松手。蓝牙移至R16/R17/T24；Flash改用板载MSPI；外接I2S BCLK/WS/DIN现为A19/A18/B21（后续83d7c223修正），具体连接见上表。

包含 `b57778ef` 的QE初始化（每次加载增加约20ms等待）和 `d47b14df` 的I2S引脚修正。保留本地双声道、引导演奏与其他未提交功能，未用远端文件覆盖这些实现。RAM地址、系数格式和RAM布局沿用现有设计。后续已完成Flash资源基址迁移，当前板级为FLASH_BASE=0x800000、物理FLASH_BYTES=16MiB，见下文烧录说明。

50MHz板级仿真使用50MHz核心、真实20ms QE等待；Flash模型从QE=0开始，检查06h/01h顺序、写入值与随后6Bh读表。最终物理时序须重新执行本页构建及验收命令，旧100MHz报告不可用作本版签核。本次未烧录。

本次对齐验证完成：原厂PLL模型1项、50MHz板级6种配置、loader/MIDI/联合配置7项，共14项回归配置通过。16槽负载下钢琴最多734周期、eng1最多598周期，I2S采样间隔1024周期。整板覆盖QE=0启动、20ms等待、UART/蓝牙、PAD/LED、引导演奏、双声道、故障及复位。证据位于 `build/board50_alignment/verification.json`，该功能验证不替代重新布局布线。

## 50MHz控制路径修复与摇杆方向（2026-10-30）

本次PnR的22个setup违例均为channel_q[3]经乐器映射、失败重试/状态判断到声部索引g的CE，最差-1.544ns。修复将inst_use改为现有C_APPLY提交时同步写入的乐器寄存器，与channel/mode同拍生效；声部索引g的更新移到仅依赖本地状态、bank选择和混音握手的独立时序块。未增加演奏流水阶段或修改系数/RAM布局。

摇杆左右反向通过sidebar_system的JOY_INVERT_X参数处理：默认0，统一板级传1，使用joystick_adapter已有的校准后X轴反向。Y轴、校准原始值、死区200/100和菜单布局保持现有配置。其他UI变更等待实板现象讨论。

本轮仅功能仿真与隔离目录综合，明确不跑PnR；结构修复不能视为时序验收通过。记录位于build/board50_control_fix；旧.fs.UNVALIDATED仍对应修复前结果。

本轮功能回归通过：板级反向X/死区/迟滞、16槽双引擎、真实整板流程、MIDI/eng1、加载失败恢复、联合配置、旧索引规则与新索引的逐周期等价、寄存乐器与旧合同一致性、4项UI/显示回归（画面哈希一致）。Gowin仅综合通过，网表确认inst_use为4位寄存器、g的3个有效寄存器CE均为VCC；旧PnR报告哈希未变化。完整结果：build/board50_control_fix/verification.json。

## 板载3.5mm输出及新转接板（2026-10-30）

已拉取origin/board50@83d7c223：新版U5转接板BCLK=A19、LR=A18、DIN=B21，GAIN=A20外部接3V3，未列入FPGA输出。原外部功放SD=A17。

新增板载输出dac_bck=E22、dac_ws=F24、dac_din=G24，以及dac_pa_en=H17。对应Dock Rev1.2原理图第18页的PT8211和XPT4809，J29是板载3.5mm耳机插孔，可接有源音箱高阻AUX，初次试听调低音箱音量。PA_EN随复位/PLL失锁/音频无效或故障关闭。实际模拟听感与耳放启动瞬态仍需实板确认。

PT8211发送Japanese/LSBJ格式，每声道16bit、WS低右高左；BCK=12.5MHz/8=1.5625MHz。外接标准I2S仍为左右32bit时隙、BCLK=3.125MHz。两路每帧都占256个音频时钟，帧节拍一致，共享32bit成对FIFO，不新增音频队列、采样延迟或引擎作业。Fs仍为48.828125kHz。SDC把新增数字输出纳入现有40ns输出预算，未放宽原时钟目标。

`python3 sim/run_board.py --test pt8211 --test system`检查独立线端解码、左右顺序、同帧配对、停止/复位、实际PAD/MIDI发声及耳放使能。隔离PnR产物与本轮验收位于build/pt8211_bringup/pnr；工程默认输出目录仍为build/instrument_board。未烧录。

本轮PnR验收已通过（2026-10-30，Gowin V1.9.12.04）：setup/hold违例均0，最差setup +4.838ns、hold +0.181ns、recovery +12.027ns、removal +0.286ns、最小脉宽 +4.449ns。core目标50MHz，报告Fmax65.952MHz；audio目标12.5MHz/Fmax17.964MHz；pix目标33.333MHz/Fmax46.540MHz。原22个控制路径违例已消除。逻辑49882、寄存器23646、BSRAM114、DSP146；相对上一次用户50MHz构建，BSRAM/DSP数量未变，逻辑+49、寄存器+48（含本轮控制改写与新串行输出的共同影响）。

功能验证：独立PT8211/I2S双格式同帧解码、两次中途复位均通过；完整整板PT8211解码10838帧、445帧非零，PAD/MIDI/蓝牙/故障恢复/耳放静音通过。51端口76生产源检查通过。一次PnR产物为 `build/pt8211_bringup/pnr/instrument_board/impl/pnr/instrument_board.fs`；证据为 `build/pt8211_bringup/verification.json`。尚未烧录或实板试听，100MHz仍是后续优化目标。

## 摇杆光标双轴方向调整（2026-10-30）

根据最新实板反馈“上下左右均反向”，相对上一版X反向/Y默认的配置，将两轴同时翻转：当前板级JOY_INVERT_X=0、JOY_INVERT_Y=1。sidebar_system新增Y反向参数并传给已有joystick_adapter；其他入口默认值保持X/Y均0。坐标校准、200/100死区、迟滞及移动速度不变。

功能仿真实际连接joystick_adapter到sidebar_ctrl，检查光标向右X增加、向左X减少、向上Y减少、向下Y增加，以及中心抖动/迟滞退出/失联回中，通过。证据build/joystick_xy_fix/sim/results.json。本轮未执行综合或PnR，之前通过的bitstream仍对应调整前方向，需后续重编译才能上板生效。

## 2026-10-30 board50增量迁移

已fetch到origin/board50@6183395d；选择性迁移真实FFT/波形读口、CORDIC极坐标历史页（style2/page10）及所有板级mem的构建复制。保留本地双声道空间定位、PT8211、MIDI引导、菜单/字库、源清单、MSPI GPIO与构建输出隔离；没有用远端旧顶层覆盖这些功能。

上游直接采样多位数据的toggle CDC改为现有Gray指针异步FIFO（24bit×16），core端将signed64结果算术右移2并饱和为24bit，像素端逐样本消费；观察队列满时只丢观测样本并置visualizer_overflow，不阻塞发声。双方复位清队列，首级Gray同步器增加独立路由界限，未给全域添加false-path。time_pingpong原有窗口忙/ready策略未在本次改写；本轮测试使用正常采样节拍。

上游c3afa396将外接I2S DIN改为A20，与本机新版U5的GAIN线冲突。用户已确认本机仍为DIN=B21、GAIN=A20外接3V3，因此保持现CST及接线表。上游硬编码的PCM×12会改变本地双声道增益/饱和合同，亦不迁移；本地实际PCM_HEADROOM_BITS=3保持；上游改为1会减少两位余量、提高约12dB，本轮不调整增益（此前文档将本地值误记为1）。50MHz、QE初始化和其余已有引脚修复不重复覆盖。

迁移回归、失败修复及当前物理边界见[工程验证](../../../docs/工程评审与验证.md#board50-migration-2026-10-30)。含新增FFT/极坐标及一阶调制的当前50MHz整板PnR已通过，见下节；未烧录或推送。

## 当前工作区整板PNR（2026-10-30，含一阶调制与FFT）

本轮当前源码已完成整板综合、放置、布线并通过自动时序验收。core目标50MHz/Fmax53.839MHz，
audio目标12.5MHz/Fmax17.504MHz，pix目标33.333MHz/Fmax39.269MHz；setup/hold违反均0。
最差setup/hold/recovery/removal/最小脉宽分别+1.426/+0.181/+8.012/+0.275/+4.293ns。
逻辑70088、寄存器33644、BSRAM149、DSP172，0锁存；新调制器保留1个MULT27X36。

综合网表将观察FIFO的复位同步器合并到core_reset/pix_reset，因此移除无匹配节点的重复CLEAR例外，
保留现有复位及Gray指针约束。完整过程、初次解析日志和输入hash见[最新验收](../../../docs/工程评审与验证.md#eng1-pitch-pnr-2026-10-30)。

bitstream为`build/eng1_pitch/board_pnr/instrument_board/impl/pnr/instrument_board.fs`；
结果位于`build/eng1_pitch/board_pnr/verification.json`。独立目录保留旧产物，未烧录。
默认NOTE_BANKS=0且仅开放钢琴资源；B类演奏仍需安装匹配P1T1资源并开放准入。
该结果覆盖当前50MHz设计，不代表历史100MHz目标或实物听感已验收。

## 远端复核（2026-10-30，eng1调制PnR之后）

重新执行 `git fetch origin --prune` 后，main仍为724572c4，board50仍为6183395d，
没有新增提交。上述有用变化已迁入本地；保留本地一阶Q2.24调制、双声道、MIDI引导及Gray FIFO实现，
不覆盖DIN=B21/GAIN=A20的已确认接线，也不引入上游PCM增益改动。
复核时104项构建输入与 `build/eng1_pitch/board_pnr/pnr_input_sha256.json` 全部一致，
原50MHz整板PnR验收仍适用于当前硬件源码。本次仅补正文档和构建命令，没有另行运行综合/PnR。

## Flash程序／音色分区迁移（2026-10-30）

迁入远端codex/board-release-flash8m@3b799106的资源基址方案，并覆盖搬移地址仿真。板级instrument_board_top与instrument_system默认FLASH_BASE=0x800000、FLASH_BYTES=16777216（物理总容量）。参数经midi_voice_top或pad_voice_top、voice_router传到weight_loader。独立模块默认仍为基址0/8MiB以兼容原测试；板级显式传入16MiB实际容量。

实际读地址为 `FLASH_BASE + instrument * (FLASH_NOTES*N_MODES*64) + slot_offset`。相对音符范围、64byte对齐、加基址后的物理容量及24位地址上限都检查；33位计算避免24位截断回绕。只变更Flash物理位置，不变更系数格式、槽位/RAM寻址、模态步长或演奏流水。

| 内容 | Flash地址 |
|---|---|
| FPGA配置程序预留区 | 0x000000–0x7FFFFF |
| 钢琴16音资源（64KiB） | 0x800000–0x80FFFF |
| 吉他16音资源（64KiB，可选） | 0x810000–0x81FFFF |

默认RESOURCE_MASK仍只开放钢琴，未因打包可选吉他而改变现有资源准入。32音时每乐器区域变为128KiB，必须配套32音镜像和NOTE_BANKS配置，不能沿用上表的16音乐器步长。

在仓库根目录生成当前钢琴资源：

```bash
python3 rtl/router/tools/pack_board_flash.py --out build/flash_resources/piano.bin
```

可选打包已有钢琴＋吉他（仅准备文件，不修改资源掩码）：

```bash
python3 rtl/router/tools/pack_board_flash.py \
  --instrument 0=rtl/router/tools/piano_flash.bin \
  --instrument 1=rtl/router/tools/guitar_flash.bin \
  --out build/flash_resources/piano_guitar.bin
```

输出BIN不补8MiB前缀，整个文件烧在0x800000；配套JSON记录物理烧录地址、各乐器相对偏移、容量与输入/输出哈希。工具从板级源码读取FLASH_BASE/FLASH_BYTES，已有guitar_flash.bin中的一个空白乐器前缀会先提取，避免双重偏移。piano_flash.py的BIN/MEM内容仍使用相对地址，只更新容量检查、manifest和打印的烧录地址。

烧录顺序：用本次修改后的源码重新生成固件，写入Flash地址0；再把资源BIN写到0x800000并分别校验。第二步仅擦除资源所占扇区，不得全片擦除，否则会抹掉程序；更新固件也须保留资源分区。旧基址0的固件不可与0x800000的新烧录位置混用。SRAM临时下载新固件不能替代Flash固件更新与断电自启动测试。

验证位于build/flash8m_migration：原offset/timeout回归、0x800000真实SPI读址回归、7项边界检查和打包测试；整板Flash模型低地址提供程序占位数据、资源文件映射到0x800000，并拒绝读取程序区。当前轮只做功能验证，不执行PnR或烧录；之前的时序报告不代表本次地址改写已重新验收。

本轮搬移验证完成：原loader偏移/超时、0x800000搬移、7项边界、独立PAD钢琴/吉他失败恢复、完整板级及摇杆/3.5mm测试均通过；整板真实SPI读址min=0x800000/max=0x80F000。3项打包/容量测试和旧镜像自检通过；新钢琴＋吉他BIN的SHA256为2305d756eb0e84d3f84e7b5b24fd9c658c0971ebc5e021bdd4ed1ba04808b15a，与远端发布版一致。证据为build/flash8m_migration/verification.json。

## Flash分区迁移后整版PnR复测

本轮包含当前93份生产源，一次PnR及自动验收通过：setup/hold违例均0，最差setup +1.471ns、hold +0.181ns、recovery +12.998ns、removal +0.279ns、最小脉宽 +4.293ns。core50MHz/Fmax53.969MHz，audio12.5MHz/Fmax16.365MHz，pixel33.333MHz/Fmax39.803MHz。逻辑70071、寄存器33641、BSRAM149、DSP172。构建输入与存档指纹一致。最差路径为inst_use[1]到系数RAM写口，后续功能开发继续关注。

产物位于build/flash8m_migration/pnr_review/implementation/instrument_board/impl/pnr/instrument_board.fs；本轮报告与哈希为build/flash8m_migration/pnr_review/verification.json及REPORT.md。使用同一份当前源码可在默认目录重编译；固件Flash地址0、资源BIN地址0x800000。未烧录。

## 外接音频引脚按实测发布版对齐（2026-10-31）

核对origin/codex/board-release-flash8m@3b799106中的board_release_piano_guitar：外接功放BCLK=A19、WS=A18、DIN=A20、SD=A17。此前83d7c223版本的DIN=B21与该发布版不同，现修正为A20；上文“GAIN=A20外接3V3”的旧转接板说明不适用于这份发布版接线，使用前需核对实际转接板，A20现为FPGA数据输出，不得仍硬接电源。所有发布版共有端口的IO_LOC现已一致。新增板载PT8211的E22/F24/G24/H17保持当前配置，发布版没有这条通路。

本次仅改CST并检查管脚唯一性，未跑PnR；之前已生成的FS仍含DIN=B21，需要重新编译才能生效。FFT有输出说明显示链路有数据，但不证明外部功放收到正确串行数据，也不证明耳放已使能或板载DAC模拟输出正常。
