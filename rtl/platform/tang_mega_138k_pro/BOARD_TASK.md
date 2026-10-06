# 自动歌曲上板封装任务与硬件验收边界

用户已选择：Tang Mega 138K Pro、外接MAX98357A、3.3V供电、3W/8Ω喇叭、空闲PMOD2。外部格式标准I2S而非TDM，不需要麦克风。2BC已独立功能/周期验证通过，音频数字模块正在另一会话实现。本任务只做platform目录的新板级封装/说明与必要的专属sim测试，不修改算法或音频会话文件。

**最新环境更正（优先于下文早期“无Gowin”假设）：用户确认Gowin IDE、Programmer均在`~/gowin`，license已验证。父会话实际找到`/home/rubbishbro/gowin/IDE/bin/gw_sh`、GowinModGen/GowinSynthesis和本地文档；当前PATH也可找到gw_sh。继续尝试真实vendor PLL生成及综合/布局布线，不改用户license或安装配置，不输出license内容，不用行为PLL混入生产源。暂不执行Programmer烧录；板卡未连接/完整part仍需核对。工具找到不等于本工程license/PLL/综合/时序已通过，必须实际记录执行结果。此前预检缺工具测试需隔离PATH模拟，不可假设用户一直没有工具。**

## 1. 需要交付

- board top：真实50MHz晶振输入、复位按钮、BCLK/LRC/DIN/SD四输出，默认自动歌曲；连接audio_demo_core。不能让100MHz/12.288MHz测试时钟冒充真实板晶振直接接Pin。
- clock/reset wrapper：实例化用户须由Gowin生成的两个明确命名PLL IP，输出core100MHz及audio12.288MHz、lock；缺少IP时构建应失败，不以黑盒/直通晶振静默“成功”。不能假造已由Gowin生成或已经锁定。
- 完整CST（可复用已存在audio_pmod2.cst的内容/来源，但不要修改父会话文件），SDC时钟/CDC约束说明、Gowin文件列表/构建入口或导入说明，ROM初始化正确路径。
- preflight脚本：缺IP/文件/工具时准确非零；验证source/ROM/PLL模块名/端口/器件选择的一致性，不用预检通过代替综合或Fmax。
- 仿真板级封装（独立test-only PLL行为模型，明确不在综合文件列表中）验证lock之前SD低、复位立即关断、释放后自动播放、波形时钟比例/完整通路连接；行为PLL不验证物理锁定/PFD/VCO/时序。
- 上板README：精确接线、供电与GAIN/SD选择、IP生成步骤、实际命令/结果、哪些尚未完成。

## 2. 资料与可用管脚

本地原理图Rev1.2：`reference_agent_readfirst/tang_mega_138k_pro_basic_resources/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf` 页17/19，PMOD2=J26：BCLK=IO0/C21（11脚）、LRC=IO1/B20（9脚）、DIN=IO2/B19（7脚）、SD=IO3/A17（5脚），供电1/2=3V3，3/4=GND。必须结合实板Pin1标记确认方向，不能依据左右猜测。各信号Bank5，LVCMOS33。

官方138K Pro音频例程的audio.cst：clk=P16、reset=U4；top.v使用50MHz输入、reset按键高有效。来源：https://raw.githubusercontent.com/sipeed/TangMega-138KPro-example/main/audio/audio_sinewave/src/audio.cst 。使用这些已核实来源而非别的Mega封装。不额外分配未核实LED/按键。

MAX98357A SD高选择left，低关断；示例左右相同数据，避免选路混淆。SD默认低，时钟锁定及有效样本就绪后才高；外部reset/失锁立即关断。GAIN脚实际电阻/接法未确认，手册标准I2S可3/6/9/12/15dB，不能因为TDM固定12dB就假定I2S也是12dB。扬声器OUTP/OUTN桥接均不接地；3.3V供电承载电流尚未验证，数字起步低幅，实际供电/增益确认由上板验收完成。

## 3. PLL生成而非猜测

目标器件GW5AST-LV138FPG676A、Device Version B，最终完整part由用户实板及Gowin确认，不能用PG484/其他Mega版或默默使用ES器件代替。

已读到官方GW5AST-138B生成PLL接口：Gowin_PLL(lock,clkout0,clkout1,clkout2,clkin,reset,enclk0,enclk1,enclk2)，primitive=PLL，不是GW1N的rPLL。来源：https://raw.githubusercontent.com/sipeed/TangMega-138KPro-example/main/ddr_test/Micron_400MHz/src/gowin_pll/gowin_pll.v 。不要复制400MHz参数到音频。

UG306公式（官方可搜索 https://cdn.gowinsemi.com.cn/UG306E.pdf）：Fpfd=Fin/IDIV，Fclkfb=Fpfd*FBDIV，Fvco=Fclkfb*MDIV，Fout0=Fvco/(ODIV0+ODIV0_FRAC/8)；MDIV2..128、IDIV/FBDIV1..64、输出0支持1/8分数。输出核心和音频可用两个PLL分别处理。

数学候选：core输入50MHz，IDIV1/FBDIV1/MDIV16/VCO800/ODIV8=100MHz；audio输入50MHz，IDIV5/FBDIV1/MDIV96/VCO960/ODIV78+1/8=12.288MHz。**audio的PFD10MHz是否合法/工具是否接受、实际filter/合法性仍未核实**；候选不能直接冒充有效vendor IP。若工具不能精确生成，需重新规划（如级联或精确外部参考），不能把近似12MHz当12.288MHz。用户不是必须选择这些参数，而是生成/验证工具需要确认。

本机无Gowin/License/可识别下载器，交付IP缺失时应明确“需要用户在Gowin生成IP并重新预检/综合”，不宣称可烧录bitstream已生成。行为模型只能验证封装控制逻辑。

## 4. 约束与验证

输入50MHz create_clock20ns；实际PLL输出时钟由Gowin derive/generated-clock正确约束，core10ns/audio81.380208ns，不能掩盖失配。跨域FIFO/Gray/toggle的同步路径按明确对象约束，不能盲目把所有路径false-path后称时序通过；说明工具真实层级需核对。约束语法用Gowin支持的资料/示例，未经Gowin实际执行明确标为待校验。

可验证项：wrapper结构、仿真复位/lock/SD及音频接口连接、预检缺失/成功路径。必须未完成项：真实IP生成、综合/布局布线资源及时序、ROM物理推断、I/O电气/供电、烧录后听音。最终验收自动上电播放>=60s，记录BCLK3.072MHz/LRC48kHz、诊断计数、工具/bitstream版本。不把逻辑仿真通过作为实际出声证明。
