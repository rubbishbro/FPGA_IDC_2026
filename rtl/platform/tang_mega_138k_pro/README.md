# Tang Mega 138K Pro 整版第一阶段

## 当前版本

当前源码已合入远端 `main@f7958d1b`。六音色、headroom=3、逐音Q12/复音补偿及最大侧单位增益保持；新增录制回传、fmap显示和混响完整位宽修正。编号、Flash地址和参数只维护在[音频设计](../../../docs/音频设计.md)。

本轮未编译或烧录。板上最新已校验包仍为 `build/performance_led_joy_flash`，UserCode `0x00003ED7`，包含LED位序和摇杆上下修复。烧录/时序证据、历史headroom配置及音量偏小排查统一见[调试记录](../../../docs/调试记录.md)；实板步骤见[上板测试](../../../docs/上板测试.md)。

统一入口 `instrument_board_top` 只实例化一套 `instrument_system` / `midi_voice_top`，内含双引擎选择、双UART、压力/摇杆、真实UI、Flash loader、I2S/PT8211和PCM显示。FFT/波形/极坐标在像素域处理，不反压音频；首次完整显示发布前保持零。

## 时钟、复位及资源

| 域 | 来源/频率 | 用途 |
|---|---|---|
| clk | P16板载50MHz | 单个真实厂商PLL的参考 |
| clk_core | 50MHz | 通信、压力驱动、UI loop/dispatch、MIDI、合成 |
| clk_audio | 12.5MHz | I2S分频4，BCLK=3.125MHz，Fs=48.828125kHz |
| clk_pix | 33.333MHz | LCD扫描/字模/菜单快照 |

12.5MHz是已可实现的上电调试参考，48kHz资源播放速度/音高有+1.725%偏差。不能称精确48k；旧50MHz→12.288MHz的非法PFD配置不在本工程。ip/内厂商PLL及PLL_INIT使用800MHz VCO，三个输出分别除16、64、24；功能域分别运行50MHz、12.5MHz、33.333MHz，CDC握手保持独立。生产清单无history依赖、无行为PLL。独立厂商GW5A模型已验证完整初始化后的三路频率及50%占空比；该结果不能代替布线后的最小脉宽检查。

PLL失锁或rst_n拉低，所有域共同异步断言复位；各域独立三级同步释放，sidebar及音频内部仍保留各自的CDC复位，voice_router对七个高扇出DSP子树分别同步释放。日常清音改为同步请求和实际清理完成屏障，不通过业务逻辑生成异步复位。功放SD在复位/失锁/音频故障时拉低，BCLK/WS在正常配置和装载期间持续发送静音。

默认RESOURCE_MASK=12'hC2B、NOTE_BANKS=0，使用六音色混合镜像及固定16音映射。UI不开放未安装资源的音色；32音需明确重新生成与验收，不能只改NOTE_BANKS。

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
| 外接功放 I2S BCLK/WS/DIN / SD | PMOD2，按当前instrument_board.cst | A19/A18/A20/A17；当前CST无GAIN约束，A21/B21未分配 |
| 板载PT8211 BCK/WS/DIN | 底板U6 → J29 | E22/F24/G24 |
| 板载耳放使能 | U32 XPT4809，PA_EN | H17，高有效 |
| HC-05 TX→FPGA RX | PMOD0 | R16（uart_rx[1]） |
| HC-05 RX←FPGA TX | PMOD0 | R17（uart_tx[1]） |
| HC-05 STATE→FPGA | PMOD0，可选 | T24；默认BT_HAS_STATE=0，接并启用后才检测物理断连 |

蓝牙会话 v2 试验入口：板级参数 `BT_PROTOCOL_V2=1`，手机按
[v2 合同](../../../docs/蓝牙协议.md) 握手后才能发送业务；默认仍为 v1。
接好 STATE 后另设 `BT_HAS_STATE=1`；未接 STATE 时 v2 仍可依靠心跳撤销会话，
HELLO 可在来源隔离期间到达，不依赖板级固定为 0 的 `session_restart`。
本次协议仿真不构成该参数组合的整板时序或实物验收。

三个PMOD的pin1/2为+3V3，pin3/4为GND，接线按板上Pin1标记核对。本版使用板载Flash，PMOD0改接蓝牙。Flash须装入匹配镜像；loader每次加载前发送06h及01h（SR1=00、SR2=02）开启QE，并等待20ms，再执行6Bh读表。该过程会写状态寄存器，不写系数区；必须确认镜像所在地址不会与FPGA配置数据重叠。

PMOD0和板载UART RX含SSPI/CPU复用脚，build.tcl显式启用use_sspi_as_gpio/use_cpu_as_gpio/use_mspi_as_gpio；本设计不使用AE350或SSPI硬核。MSPI管脚在用户逻辑运行时用于读取板载Flash，下载与启动行为须按板卡流程验证；JTAG仍用于调试。SSPI复用选项见[Gowin Tcl官方手册](https://cdn.gowinsemi.com.cn/SUG1220E.pdf)。

## 输入及配置接线

pad_driver保留主线的泄放/建立/完成沿sticky/超时重试FSM，未用分支旧定时盲读替换。板级LED由`pad_led_effects`以200Hz全查表渲染明暗行波和16条sinc波纹，64像素写满后交给带busy/frame_done的串行驱动；逻辑坐标保持行=y、列=x，每垫对应2×2灯区。原始ADC字节16约0.5V：板级将正压力乘4并饱和，on/off门限64/48对应原始16/12；负电压噪声按零处理。灯效共用该标定后的压力：>64触发、<48释放，门限之间保持原状态；按下时以该垫左上灯在已显示背景帧中的相位锁定整条波纹的颜色，主峰/旁瓣只变亮度。波宽0.65格、速度6格/s，满16条替换最旧记录，重叠取占优波纹。ROM原始数据14.625KiB，无运行时乘法器；实现说明见[PAD_LED_EFFECTS.md](../../drivers/PAD_LED_EFFECTS.md)。该灯效及位序修复在3ED7快照已有数字验证和烧录；本次合并未重跑，具体边界见调试记录。原始fmap/摇杆快照仍可检查；最终压力标定需实板测量。

sidebar的摇杆启用逐轴死区输出：未进入方向的轴输出0，采用board50实板参数200进入/100退出的迟滞，板级当前采用JOY_SWAP_XY=1、JOY_INVERT_X=1、JOY_INVERT_Y=0（2026-11-01仅上下对调，左右保留），防止横推时另一轴噪声移动光标。默认joystick_adapter行为保留兼容。LCD扫描为严格800×480，板级逻辑坐标旋转180°，菜单布局/字模分拍计算，RGB/DE统一延迟4个像素时钟后输出；数值及滑条位置在消隐期准备。通用未旋转sidebar的两张画面像素哈希保持不变，板级旋转另有逐像素验证。

comm事件data/source直接接真实MIDI消费者，quarantine接source_cleanup_req；真实source_cleanup_done/source_ops_idle/midi_ops_idle反馈到session_ctrl。未选来源事件明确消费，按键菜单切换PAD/有线/蓝牙，不伪造音符。

本地“输入→演奏来源”选择有线／蓝牙后，可在“演奏方式”选择“引导演奏”：MIDI只点亮目标，压力垫沿用所选通道音色发声；切换来源将方式原子复位为自动。引导显示有独立整包CDC、实际16键音高表和压力门控反馈。选项在PAD来源下禁用，不改变v1线上协议。详见[MIDI引导合同](../../../docs/MIDI接入.md#midi-guide)。

线上CONFIG包含REVERB_SET（映射0200并等待真实音频后端结果）以及新合入的有线录制起停12/13；保留物理来源、SEQ、command、长度和shadow至退休。EQ返回NOT_READY，不伪造DSP提交；权限0502由本地菜单设置，bit0有线/bit1蓝牙，拒绝远程自授权，协议没有DENIED时映射NOT_READY。重复配置缓存仍由原parser维护。

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

完整日期化结果统一见[工程验证](../../../docs/工程验证.md)，后续整机问题维护在[台账](../../../docs/bugs.md)。本阶段的构建/仿真不代表实物接线、模拟ADC、音高准确性或DAC听感通过。

以下为迁移前100MHz版本的历史结果，不是当前50MHz源码的时序验收：

2026-10-29时钟域修改后：28个RTL测试顶层通过，另有3项Python时序门禁测试；整板用例含3722帧I2S线端对拍、555帧非零。真实Gowin综合/放置/布线完成，47端口无引脚冲突、单PLL三输出合法。**时序验收仍失败**：core报告Fmax72.019MHz（目标100），pix46.540MHz（目标33.333，已通过）；4774个setup违反端点，hold为0，recovery/removal最差分别+0.938/+0.256ns，最小脉宽slack=-0.551ns。最差数据路径已转移到ADSR和混响，具体代码位置见[本轮验证](../../../docs/工程验证.md#clock-domains-2026-10-29)。

资源为47913/138240逻辑（35%）、20516/139140寄存器（15%）、110/340 BSRAM、146/298 DSP、1/12 PLL。相对第一阶段36627逻辑/19065寄存器，逻辑增加11286、寄存器增加1451；包含实现流水及工具的时序优化/复制成本，不能称零占用变化。系数/状态RAM格式与BSRAM数量不变。最终报告在build/instrument_board，本轮存档和源指纹在build/clock_review/phase7。

check_board.py --timing读取实际报告，任何违反返回非零；build.tcl保留实现结果，但将失败的.fs标为.fs.UNVALIDATED并终止验收。不要将“PnR生成文件”当作满足目标频率。旧版本是否通过与是否下载须按对应快照判断；最新源码/固件状态见页首及调试记录。

## 输出与Flash

板级声像参数默认居中，`instrument_system.pan_position` 可接动态0..32位置；`STEREO_AUTO_SWEEP=1` 为演示扫动，3072帧前进一档。此入口没有将菜单摇杆直接作为声像控制。算法及数值合同见[音频设计](../../../docs/音频设计.md)。

外部I2S和板载PT8211共享同一对FIFO样本，串行格式不同；3.5mm接口为J29。外接DIN按当前CST为A20，旧DIN=B21/GAIN=A20接线仅属历史转接板，不能沿用。

固件写入Flash地址0，六音色资源BIN写入0x800000；BIN不含8MiB前缀。分别擦写所占扇区并校验，更新一项须保留另一区域，禁止全片擦除。固定16音布局与打包入口仅维护在[音频设计](../../../docs/音频设计.md)和[资源说明](../../router/tools/performance/README.md)。32音改变每乐器区域大小，须配套新镜像，不能沿用16音步长。

较早的对齐、方向、PT8211和分区迁移记录统一见[调试记录](../../../docs/调试记录.md#早期板级调试索引)。构建命令保留供后续使用，本轮按用户要求不执行编译或下载。
