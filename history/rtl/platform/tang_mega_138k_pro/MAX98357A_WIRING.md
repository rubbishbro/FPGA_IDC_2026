# 7针MAX98357A → 3W/8Ω无源喇叭：冻结Demo接线

适用当前Tang Mega 138K Pro **Dock Rev1.2原理图**与冻结CST。紫色模块有多个厂家版本，**以实际VIN/GND/BCLK/LRC/DIN/SD/GAIN丝印为准，不按颜色或从左数针序接线**。本说明不是烧录或未验收bitstream放行。

## 1. 断电再接

拔掉板卡USB与其他电源后接线；如果MAX模块也有独立电源，先一起断开。不要带电插拔GPIO。使用独立杜邦线，信号线尽量短（约10cm以内）。模块针脚必须焊接可靠，不用松动插触代替焊接。

## 2. 接线表

### 实板上怎样找J26

`J26`是**原理图位号**，不保证实板印有“J26”或“PMOD2”。官方Dock外观图中，将PCIe金手指朝下、SFP金属笼/RJ45朝左，则顶边有三个黑色2×6孔PMOD插座；**最右侧、ADC右边、MIPI-CSI0排线座左边的那个**是本原理图对应的PMOD2/J26。其附近成对丝印应为`C21/B21`、`B20/A20`、`B19/A19`、`A17/A18`、`GND/GND`和`3V3/3V3`，可用来核对，而不是去找ADC/CSI/DSI座接线。

来源：[Sipeed官方Dock外观图](https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/assets/mega_138k_pro_top.png)。这是**参考板位置**，不是用户实物已确认；如果插座数量、相邻接口或丝印不同，停下并提供实板正面照片，不按参考图强行接线。针脚前/后排和电源方向仍需实板核对。

只用**PMOD2/J26**。表中数字为底板原理图J26针号，**不是从照片左侧起数的顺序**；先核实实板Pin1标记/方向，必要时用断电导通检查核对GND。

| MAX98357A丝印 | 接到哪里 | 冻结GPIO/说明 |
|---|---|---|
| `VIN`（某些板写`VCC`） | J26 pin1或pin2：3V3，任选一个 | 本轮固定3.3V，不用5V |
| `GND` | J26 pin3或pin4：GND，任选一个 | 与FPGA共地 |
| `BCLK`（`BCK`） | J26 pin11：PMOD2_IO0 | FPGA C21，`amp_bclk` |
| `LRC`（`LRCLK`/`WS`） | J26 pin9：PMOD2_IO1 | FPGA B20，`amp_lrc` |
| `DIN`（`DATA`） | J26 pin7：PMOD2_IO2 | FPGA B19，`amp_din` |
| `SD`（`SD_MODE`） | J26 pin5：PMOD2_IO3 | FPGA A17，`amp_sd`；低关断，高选左声道 |
| `GAIN` | **初次留空** | 标准MAX98357A默认9dB；不接FPGA GPIO |

J26的pin6/8/10/12是其他GPIO，本次不使用。**不要套用常见PMOD“1–4是信号、5是地、6是电源”的编号**，本工程依据的Dock原理图编号不是这个排列。

`SD`要由FPGA控制，不要同时硬接VIN/GND；当前设计在PLL未锁、按钮复位或未产出有效样本时关断。左右slot发送相同mono，因此选左声道即可。SD虽然模块可能有弱上拉，但不代表能与额外硬接电源的线同时接GPIO。

如需降低模拟增益，在确认模块GAIN未被板上硬连到其他电位后，可**断电**将GAIN直接接该模块VIN，标准器件选择6dB；100kΩ接VIN是3dB。GAIN直接接GND反而是12dB，不是“降低音量”。本轮不改冻结软件音量参数。第三方模块板载电阻有差异，若GAIN已设定则按其电路核实，不能单凭紫色断言。

## 3. 喇叭接功放输出，不接GPIO/GND

适用两根线的3W/8Ω动圈无源喇叭：

```text
MAX模块 OUT+ / SPK+ / +  ── 喇叭一端（通常红线）
MAX模块 OUT- / SPK- / -  ── 喇叭另一端（通常黑线）
```

- 通常就是模块的两位螺丝端子；以模块输出标记为准。
- **黑线也不是地：两个输出都是桥接驱动，任何一端均不能接GND、VIN或FPGA。**
- 不要接耳机、电脑音频口、带VCC/GND/IN的有源音箱模块。
- 3W是喇叭承受能力，3.3V/8Ω不能输出满3W；以小音量demo为目标。
- 示波器普通接地夹只接公共GND，不能夹OUT+/OUT-；测喇叭两端需合适差分方式，否则可能短接功放输出。

## 4. 电源边界

优先沿用用户选定的同板3.3V小音量验证，但**J26的3.3V带载电流能力/实际压降尚未测量**，本表不保证可长期满功率。电源/GND线可靠，首次通电关注异常发热、板卡掉电重启和声音随供电变化。

如模块没有足够去耦，可在VIN与GND附近加正确极性的10–100µF电容，并配100nF陶瓷去耦；不把电容当电源容量不足的解决办法。遇到异常先断电检查，后续需要独立稳压3.3V时，模块与FPGA共地，但**不要把两个电源的3.3V输出直接并联**。本轮不改用5V，也不从GPIO供电。

## 5. 预期波形与后续验收

### 实板复位键纠正（首次下载无声排查）

**不要把底板S1当作当前工程复位键。** Dock Rev1.2原理图的BUTTON电路中，S0/S1/S2/S3分别接K16/F15/G15/G16；S1是`USR_KEY.1`（F15）。当前冻结CST把`reset`接到U4，底板BTB页标为`CPU_RST`低有效网络（原图带反相标记）；不能根据官方音频例程的“S1按键”注释推断实物按键位置或极性。本工程假定U4高有效，其实际按钮/极性还需核对，此为板级审查缺口，不修改冻结RTL来掩盖。

SRAM下载后设计应自动启动，无需先按S1；先测模块VIN和SD对公共GND的直流电压，若SD低再定位复位/PLL/首样本。不要尝试RECONFIG，避免重新加载Flash旧程序。未执行新的下载或任何硬件操作。

冻结配置：BCLK3.125MHz（320ns），LRC48,828.125Hz（20.48µs），64BCLK/frame；标准I2S、32bit/slot，16bit mono左右复制。无需MCLK，不接I2C SDA/SCL，不接外部50/100MHz时钟。

先拍清楚**模块正反面丝印、板上PMOD2/J26附近Pin1标记与FPGA完整丝印**，核对无误再通电；物理芯片与板卡方向确认不能由本表代替。此次未授权/未执行Programmer，当前时序模型OPEN项见[`../../../docs/archive/2026-10/rtl/clock_model_review.md`](../../../docs/archive/2026-10/rtl/clock_model_review.md)。以后明确授权并核对构建后，才进行实板启动、多次复位和至少60s播放验收，不以试听证明全温压时序。

## 核对来源

- 本地`reference_agent_readfirst/tang_mega_138k_pro_basic_resources/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf`，sheet17/19：J26针号、电源及PMOD2 IO；冻结`audio_pmod2.cst`/完整CST为C21/B20/B19/A17。
- [Adafruit MAX98357A pinouts](https://learn.adafruit.com/adafruit-max98357-i2s-class-d-mono-amp/pinouts)：VIN范围、SD/channel、GAIN配置、BTL喇叭输出。此资料说明标准器件/其breakout行为，不声称紫色第三方模块电阻完全相同。
- 冻结输入/时钟核对摘要见[`../../../docs/archive/2026-10/rtl/demo_freeze_20261005.md`](../../../docs/archive/2026-10/rtl/demo_freeze_20261005.md)。
