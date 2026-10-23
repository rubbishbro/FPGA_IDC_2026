# PLL / 时钟树最小脉宽：只读查证

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期：2026-10-07。对象：v5真实Gowin构建，`GW5AST-LV138FPG676AES`、B库、V1.9.12.04。用户要求“查一查”。本次未修改生产RTL/IP/CST/SDC，未用source latency覆盖，未重建或下载硬件。父会话亲读原始报告/官方文档，并独立复核DS审查；不采纳未经证实的“工具一定过度悲观”结论。

## 结论优先

1. **核心PLL输出已使用PRIMARY全局时钟网络，不能把问题说成100MHz核心时钟全部走普通数据布线。**
2. **但50MHz输入确有PR1014普通布线警告；P16是EMCCLK复用脚，不是当前器件表里的PLL专用输入脚。**它的源路径是具体的排查对象，不是已证明的MPW根因。
3. **`tCL`是clock source latency，不是纯PLL单元延迟。**当前5.383/2.496ns的内部组成未在这份报告中展开，不能声称两者都是PLL本体实测或独立的占空比失真。
4. 当前PLL分频/频率和名义50%配置有官方依据，没有发现它被设置成错误频率或Bypass奇数分频模式。
5. 未找到Gowin公开文档对MPW的共同路径悲观去除适用规则；**这不证明工具内部没有做该处理，也不证明全部违例都属假警报。**MPW仍OPEN。

## 1. 实际时钟资源与输入路径

v5原始`impl/pnr/song_metadata_core100.rpt.txt`第82–102行：

```text
PRIMARY 3/8；PLL 2/12；GCLK_PIN 0/24
clk_d           PRIMARY  PTR0 PTR1 PBR3
u_top/clk_core  PRIMARY  PTR0 PTR1 PTR2 PTR3 PBR0 PBR1 PBR2 PBR3
u_top/clk_audio PRIMARY  PBR1
```

这证明PLL输出侧的核心时钟已使用专用全局资源。PRIMARY区域覆盖不是“最优布局”的证明；`clk_d`也列为PRIMARY不表示其每条到PLL的分支都走专用路径。

同一构建PNR log第15行明确存在：

```text
WARN (PR1014): Generic routing resource will be used to clock signal 'clk_d'
by the specified constraint. And then it may lead to the excessive delay or skew
```

原始综合网表：`IBUF clk_ibuf`将`clk`输入连接至`clk_d`，两个PLL的`CLKIN`均接`clk_d`。没有在这条可见RTL/网表逻辑上发现LUT分频或逻辑门控时钟。

父会话独立读取实际安装器件表`IDE/data/device/GW5AST-138B/FCPBGA676A.json`：

```json
{"INDEX":"P16","NAME":"IOR103B","TYPE":"I/O","BANK":3,"CFG":"EMCCLK"}
```

相同表的PLL专用引脚会明确带`RPLL*_T_IN*`等CFG标记，P16没有。当前CST的P16与Sipeed官方TangMega-138KPro音频例子相同：
<https://raw.githubusercontent.com/sipeed/TangMega-138KPro-example/main/audio/audio_sinewave/src/audio.cst>

**不能为了让工具用专用输入而擅自更改IO_LOC到另一根脚**：物理晶振接线不会跟着CST变动。普通路由警告是否主要来自P16→PLL分支、哪些路径贡献多少延迟，还需要详细路由/源延迟分解或厂商说明。

## 2. tCL / MPW定义及解释纠正

官方SUG940-2.0.5E §4.2.3，printed45页：

- `tCL: Time of clock latency; clock source latency.`
- `tINS: Time of module instance; component delay.`
- `tNET: Time of net; the delay of net.`

因此前面对5.383/2.496ns简称“PLL库延迟”的解释不够准确，纠正为**工具在PLL输出生成时钟定义点报告的源时钟延迟**。源定义为外部`clk`，生成点为`PLL_inst/CLKOUT0`，其传输模型可能涉及IBUF/参考输入路径等；不能在无分解数据时断言2.887ns差全是PLL器件本体的上升/下降延迟差。

SUG940 §4.2.4，printed49页定义：

```text
Actual Width = Early clock Path − Late clock Path
Slack = Actual Width − Required Width
```

v5最坏MPW路径原文第4685–4711行：

| 项目 | late-rise路径 | early-fall路径 |
|---|---:|---:|
| 名义边沿 | 0.000ns | 5.000ns |
| 输出生成点tCL | 5.383ns | 2.496ns |
| 生成点到端点tNET | 3.342ns | 1.517ns |
| 端点到达时刻 | 8.725ns | 约9.014ns |

工具使用内部未舍入精度得到actual0.288ns、required0.900ns、slack−0.612ns。它不是实测波形；列出的三位小数相减可能相差1ps。

SUG940公开公式未列CPPR项，全文检索未见CPPR/CRPR说明。`-max_common_paths`只是限制报告路径数量，**不是**开启共同路径相关性分析的选项。不能凭无文档就证明工具“没做CPPR”，更不能自行减去全部source spread。

## 3. PLL配置有没有明显错误

现core IP及真实网表的参数/项目器件标记一致：B、ES目标、同工具版本。实际板上芯片完整尾缀/速度级仍未核实，不能将项目一致当作实物确认。

core：`FCLKIN=50, IDIV=1, FBDIV=1, MDIV=14, ODIV0=7`，内部反馈、VCO输入选择、非Bypass/CAS，无扩频/动态分频/相移。

UG306-1.0.9E §5.1（printed36–37页）频率公式给出：

```text
FPFD = 50/1 = 50MHz
FVCO = 50×1×14 = 700MHz
FOUT0 = 700/7 = 100MHz
```

DS1239 Table3-18的FPFD范围19–81.25MHz、VCO范围650–1300MHz均包含这些值。音频PLL为650MHz/52=12.5MHz。

UG306 Table5-3，printed47页：`DE0_EN=FALSE`对应ODIV0=2–128时50% duty；本IP同时`DT_STEP=0`，所以名义50%配置有明确依据。§5.1 printed53页“奇数ODIV(>2)不是50%”说明限定Bypass-in/CAS模式，本设计为VCO模式，不能套用该条断言ODIV7有错。

UG306 printed43/54页：静态DT细调每步50ps，取值0/1/2/4，最多200ps，**不能仅用当前静态细调覆盖612ps缺口**。手册还支持另一套动态占空比调整；其存在不意味着可以只改SDC占空比求通过，启用会改变真实PLL硬件/控制及分析，未在本只读任务实施。

## 4. 数据手册能证明什么

DS1239-1.0.3E Table3-18，printed44–45页：

- PLL整数输出占空比精度`<50mUI`，100MHz下对应0.5ns量级。
- PCLK输出≥100MHz的period/cycle-cycle jitter `<400ps`。
- 脚注[1]为整数分频输出测试数据；[3]抖动数据基于低抖动晶振；[4]IO观察的duty受Clock Tree影响。

这些规格提示**源相位延迟界与真正占空比精度不是同一个量**，值得向厂商核对模型一致性。但测试条件、ES/B/速度级及内部端点适用性未完整证明，不能直接拿0.5ns代替tCL spread、补一个固定uncertainty后宣称整机通过。

## 5. 下一步可以有依据地做什么

先取得/核对以下数据，而不是盲改算法或时钟延迟：

1. v5源路径从P16/IBUF到两个PLL CLKIN/CLKOUT0的实际时钟路由分解；明确PR1014对应分支和tCL组成。
2. 工具对同一PLL生成时钟的late-rise/early-fall是否允许共同源相位抵消，对MPW如何处理；不能用setup/hold的CPPR经验直接套用。
3. B/ES器件实际速度级的PLL duty/jitter、参考输入路由及端点脉宽模型适用规则。
4. 若确认当前源路径模型合法且可优化，才试专用资源/PLL位置/布局路径的候选，并重跑完整STA、功能和周期；本次不猜未公开的CST/CLI参数。

真实示波器观察输出引脚可补证当前板上波形，但引出时钟会改变映射且引脚不等于内部DSP/RAM时钟端点，也不能一块板常温测量代替全PVT证明。本任务未添加调试输出或要求用户拆散热片。

## 原始依据

- [SUG940官方时序指南](https://cdn.gowinsemi.com.cn/SUG940E.pdf)，本机2.0.5E，§4.2.3/4.2.4/5.2.3。
- [UG306官方Arora V时钟指南](https://cdn.gowinsemi.com.cn/UG306E.pdf)，本机1.0.9E，§2.1/5.1、Table5-3/5-10；公开CDN版本可能不同，以引用的本机版本/页码为准。
- [DS1239官方器件数据手册](https://cdn.gowinsemi.com.cn/DS1239E.pdf)，本机已归档1.0.3E，Table3-18。
- 真实v5报告：`/tmp/opencode/song-control-core100-v5-20261007/build/song_metadata_core100/impl/pnr/`。
- 父文本摘录：`/tmp/opencode/pll-pulse-parent-audit/`；DS修订复审：`/tmp/opencode/pll-pulse-ds-audit.md`。

**本次结论：找到了50MHz输入普通路由的具体警告，并纠正了tCL解释；尚未证明612ps缺口可以合法消除，未改生产文件，MPW未放行。**
