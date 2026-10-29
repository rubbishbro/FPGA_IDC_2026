# Tang Mega 138K Pro 整版第一阶段

统一入口为instrument_board_top：压力/摇杆、双UART通信、真实UI配置后端、loader/双bank合成和I2S接在同一工程。没有并列例化pad_voice_top，只有一套midi_voice_top/voice_router。

本阶段LCD显示真实菜单、实际配置和故障；频谱/波形读口明确为零，没有接测试正弦波冒充合成PCM。真实PCM到FFT的独立CDC属于下一阶段。instrument_system保留sample_valid/sample_value，供后续接入。

## 时钟、复位及资源

| 域 | 来源/频率 | 用途 |
|---|---|---|
| clk | P16板载50MHz | 单个真实厂商PLL的参考 |
| clk_core | 100MHz | 通信、压力驱动、UI loop/dispatch、MIDI、合成 |
| clk_audio | 12.5MHz | I2S分频4，BCLK=3.125MHz，Fs=48.828125kHz |
| clk_pix | 33.333MHz | LCD扫描/字模/菜单快照 |

12.5MHz是已可实现的上电调试参考，48kHz资源播放速度/音高有+1.725%偏差。不能称精确48k；旧50MHz→12.288MHz的非法PFD配置不在本工程。ip/内厂商PLL及PLL_INIT使用800MHz VCO，三个输出分别除8、64、24；功能域仍分别运行100MHz、12.5MHz、33.333MHz，CDC握手保持独立。生产清单无history依赖、无行为PLL。独立厂商GW5A模型已验证完整初始化后的三路频率及50%占空比；该结果不能代替布线后的最小脉宽检查。

PLL失锁或rst_n拉低，所有域共同异步断言复位；各域独立三级同步释放，sidebar及音频内部仍保留各自的CDC复位，voice_router对七个高扇出DSP子树分别同步释放。日常清音改为同步请求和实际清理完成屏障，不通过业务逻辑生成异步复位。功放SD在复位/失锁/音频故障时拉低，BCLK/WS在正常配置和装载期间持续发送静音。

默认RESOURCE_MASK仅钢琴、NOTE_BANKS=0，兼容当前入库16音piano_flash.bin。UI不会开放不可用的音色和音组。正式六音色32音镜像合并后，再设置NOTE_BANKS=1、FIRST_MIDI及对应RESOURCE_MASK；不在第一阶段擅自更换布局或烧录。

## 建议接线

LCD/按键沿用现行ui_demo.cst；压力/LED沿用origin/boardtest的4abc8b19修复及实测引脚。PMOD、ADCV、DBG_UART逐项对照仓库Dock原理图第5/16页。所有数字信号为3.3V。

注意参考分支README曾把压力连接器写成J22/PMOD1；按原理图实际为**J24/PMOD1**，J22是PMOD0。本工程按FPGA管脚核对，使用正确连接器标号。

| 外设 | 接口 | FPGA管脚/信号 |
|---|---|---|
| LCD、复位、两按键 | 原LCD排线与板载按键 | 完整RGB/DE/CLK映射见instrument_board.cst；rst_n=G16、key0=F15、key1=G15，均低有效 |
| 有线串口 | 板载USB-UART | FPGA RX=N16，FPGA TX=P15；主机115200 8N1，SLIP/CRC协议v1 |
| 压力行0/1/2/3 | J24 pin11/9/7/5 | C24/E25/L17/H14 |
| MUX SEL0/1/2 | J24 pin12/10/8 | B24/D25/L18 |
| 点阵LED DIN | J24 pin6 | H15 |
| 压力板模拟输出 | ADCV_P / ADCV_N | N12接模拟输出、P11接GND；专用ADC引脚不写普通IO_LOC |
| 外接Flash CS/SCK | J22 pin8/7 | L24/R16 |
| Flash DQ0/1/2/3 | J22 pin10/11/5/6 | N17/N18/R17/T24，分别SI/SO/WP/HOLD |
| MAX98357A BCLK/WS/DIN/SD | J26 pin11/9/7/5 | C21/B20/B19/A17 |
| HC-05 TX→FPGA RX | J26 pin10 | A20（uart_rx[1]） |
| HC-05 RX←FPGA TX | J26 pin12 | B21（uart_tx[1]） |
| HC-05 STATE→FPGA | J26 pin8，可选 | A19；默认BT_HAS_STATE=0，接并启用后才检测物理断连 |

三个PMOD的pin1/2为+3V3，pin3/4为GND，接线按板上Pin1标记核对。Flash与麦克风阵列共用PMOD0线网，本方案不同时接麦克风阵列。Flash预先开启QE、装入匹配镜像；当前loader只读6Bh，不替代芯片初始化/烧录器。

PMOD0和板载UART RX含SSPI/CPU复用脚，build.tcl显式启用use_sspi_as_gpio/use_cpu_as_gpio；本设计不使用AE350或SSPI硬核。仍保留JTAG/MSPI下载能力。SSPI复用选项见[Gowin Tcl官方手册](https://cdn.gowinsemi.com.cn/SUG1220E.pdf)。

## 输入及配置接线

pad_driver保留主线的泄放/建立/完成沿sticky/超时重试FSM，未用分支旧定时盲读替换。板级LED恢复“行=y/2、列=x/2”的2×2映射，64像素写入后留6000个400ns拍传输。原始ADC字节16约0.5V：板级将正压力乘4并饱和，on/off门限64/48对应原始16/12；负电压噪声按零处理。原始fmap/摇杆快照仍可检查；最终压力标定需实板测量。

sidebar的摇杆启用逐轴死区输出：未进入方向的轴输出0，保留1400进入/900退出的迟滞，防止横推时另一轴噪声移动光标。默认joystick_adapter行为保留兼容。LCD扫描修正为严格800×480，菜单布局/字模分拍计算，RGB/DE统一延迟4个像素时钟后输出；数值及滑条位置在消隐期准备。两张完整画面的像素哈希与改动前基准一致。

comm事件data/source直接接真实MIDI消费者，quarantine接source_cleanup_req；真实source_cleanup_done/source_ops_idle/midi_ops_idle反馈到session_ctrl。未选来源事件明确消费，按键菜单切换PAD/有线/蓝牙，不伪造音符。

线上CONFIG首版只有REVERB_SET映射0200并经UI loop/dispatch及真实音频后端完成，最后才回v1结果；保留物理来源、SEQ、command、长度和shadow至退休。EQ返回NOT_READY，不伪造DSP提交；权限0502由本地菜单设置，bit0有线/bit1蓝牙，拒绝远程自授权，协议没有DENIED时映射NOT_READY。重复配置缓存仍由原parser维护。

加载故障时MIDI屏障保持阻塞；使用本地菜单“清音”(8001)或整板复位恢复后，再继续远程配置。CRC/串口故障按源清理并隔离：有线用整板复位重建会话；HC-05启用STATE后可由重新连接产生restart。8002通信重启菜单尚无消费者，不开放该能力。

## 构建与验证

在仓库根目录：

```bash
python3 rtl/platform/tang_mega_138k_pro/check_board.py --out build/board_sim/pins.json
python3 sim/run_board.py
QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software BOARD_PNR=1 \
  /home/rubbishbro/gowin/IDE/bin/gw_sh rtl/platform/tang_mega_138k_pro/build.tcl
```

sources.f为唯一完整板级源清单，构建产物在build/instrument_board，未执行烧录。仿真只替换PLL、ADC和Flash外设，UART字节驱动、解析、实体按键、PAD扫描、菜单、UI后端、loader/引擎、I2S和LCD使用生产RTL。独立LCD单测检查两帧的800×480有效像素和1192×533时钟；摇杆单测检查横向/对角进入、迟滞退出、回中及失联。附加回归覆盖停钟/复位CDC、同步效果器清理、两引擎满16槽供样、PCM逐位等价、配置范围/比较等价及LED线端波形等价。`python3 sim/run_board_pll.py`独立使用厂商GW5A模型，不使用板级行为PLL。

完整日期化结果统一见[工程验证](../../../docs/工程评审与验证.md)，后续整机问题维护在[台账](../../../docs/bugs.md)。本阶段的构建/仿真不代表实物接线、模拟ADC、音高准确性或DAC听感通过。

2026-10-29时钟域修改后：28个RTL测试顶层通过，另有3项Python时序门禁测试；整板用例含3722帧I2S线端对拍、555帧非零。真实Gowin综合/放置/布线完成，47端口无引脚冲突、单PLL三输出合法。**时序验收仍失败**：core报告Fmax72.019MHz（目标100），pix46.540MHz（目标33.333，已通过）；4774个setup违反端点，hold为0，recovery/removal最差分别+0.938/+0.256ns，最小脉宽slack=-0.551ns。最差数据路径已转移到ADSR和混响，具体代码位置见[本轮验证](../../../docs/工程评审与验证.md#clock-domains-2026-10-29)。

资源为47913/138240逻辑（35%）、20516/139140寄存器（15%）、110/340 BSRAM、146/298 DSP、1/12 PLL。相对第一阶段36627逻辑/19065寄存器，逻辑增加11286、寄存器增加1451；包含实现流水及工具的时序优化/复制成本，不能称零占用变化。系数/状态RAM格式与BSRAM数量不变。最终报告在build/instrument_board，本轮存档和源指纹在build/clock_review/phase7。

check_board.py --timing读取实际报告，任何违反返回非零；build.tcl保留实现结果，但将失败的.fs标为.fs.UNVALIDATED并终止验收。不要将“PnR生成文件”当作满足目标频率。第一阶段接线/功能已完成，物理时序问题归I04，尚未烧录。
