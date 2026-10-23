# PLL时钟模型独立审查：尚未放行

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期：2026-10-05。本文区分**真实工具报告的结果**与**时钟模型的物理依据**，不是烧录授权，也不是实板测量记录。

## 当前结论

- 当前核心已完成实际优化、独立功能/满载/4096样本整链验收。父会话真实完整Gowin构建：100MHz目标，setup/hold0/0，最坏setup约+0.002ns，clock MPW最坏−0.514ns。
- DS后续共同名义PLL source-latency候选虽报告setup/hold/MPW均非负，父会话**未接受**：`set_clock_latency -source 3.765`替换了器件early/late source extremes，没有已审查的物理依据。已保留候选与报告并移除仅本次新增覆盖，未回退核心/箱体/用户工作。
- 生产SDC有效命令与亲跑core100基线相同；准确的专用reset链全部CLEAR注释保留。没有改频率、原系数、数值算法或II3，未烧录。
- 新找到公开数据手册，可讨论**条件脉宽预算**；尚不能据此自动宣布完整STA/整机可靠性闭环。器件、输入源、电源条件与规格覆盖仍待确认。

## 公开厂商原文

[DS1239E：GW5AST series of FPGA Products Data Sheet](https://cdn.gowinsemi.com.cn/DS1239E.pdf)，实际PDF封面**DS1239-1.0.3E，2025-10-24**。官网目录列2026-08-14，但该日期不是本次取得PDF的内容日期。

父会话2026-10-05获取原始PDF：790149bytes，SHA256=`6930ad832b626a1f4256a759152daf056af56abea8409e055cd7ef060a93dc68`，原文件/文本/下载元数据位于`/tmp/opencode/core100-review/vendor-public/`。未登录、未绕过受限下载入口，采用公开CDN。

### Table 3-18，printed44–45页，GW5AST-138

表的C2/I1与C1/I0两列给出相同值：

| 参数 | 原文数值 | 本次审查边界 |
|---|---|---|
| PLL VCO | 650–1300MHz | 当前700MHz在范围内 |
| Input/PFD | 输入19–800MHz，PFD19–81.25MHz | 当前50MHz满足名义配置条件 |
| `TSTATPHAOFFSET` | ±50ps | 不证明两个独立PLL的误差相关 |
| PCLK输出cycle-cycle/period jitter，≥100MHz | <400ps | Note[3]基于低抖动晶振；并非无条件实板值 |
| HCLK对应jitter，≥100MHz | <300ps | 不把HCLK值套用到未核对的PCLK路线 |
| `TOUTDUTY`占空比精度 | <50mUI，Note[1],[4] | 文档未在该表明确测量点、误差组合规则或ES/B覆盖 |

Note[1]：测试数据来自integer frequency divider outputs；Note[3]：输出jitter与输入源有关，本数据基于low-jitter crystal；Note[4]：IO端观察的duty cycle受Clock Tree影响。表列有界数值，但不是“nominal50%等于任意条件下精确50%”的证明。

当前`gowin_pll_core_100m_mod.v`采用Arora V `PLL`原语：FCLKIN50、MDIV14、ODIV0=7、fractional配置0、INTERNAL feedback、DT_STEP0；VCO700/output100MHz为integer配置。不要把该原语误称`PLL_ADV`，或将其他器件系列PLL规格直接套用。

Table3-2，printed33页：GW5AST-138 VCC0.87–1.03V、VCCX1.71–1.89V、商业结温0–85℃；VCC ripple可影响PLL jitter。MAX98357A的3.3V供电不代表FPGA内部VCC/VCCX已经测量合规。

## 为什么共同名义延时不能放行

SUG940-2.0.5E §4.2.4（49页）定义MPW=early clock path−late clock path；§5.2.3（60–61页）定义source latency、rise/fall、early/late选项。**语法可用不等于某个值物理正确**，没有找到厂商允许将source极值取中点消悲观的规则。

未覆盖的真实MPW路径中，PLL source spread=`5.080−2.449=2.631ns`，clock-net spread=`3.564−1.582≈1.982ns`。名义半周期5ns减两项约为0.387ns，报告实际0.386ns（内部精度/显示舍入）。要求0.900ns，报告slack−0.514ns。

候选MPW路径`FINAL.tr:4872–4895`将两个PLL source项都变为3.765ns，route项未变，所以width3.017/slack+2.117ns只是**这个新模型下**的结果。路径数46819不变、period20/10/80不变并不证明PVT误差没有被删掉。

原始候选报告SHA=`5e30247650d1f7aea222a881287ad2f4159db6ea8b7f0e919a0a1b880b88b413`；父会话归档`/tmp/opencode/core100-review/rejected-latency-model/`。报告门槛与外部pin certificate均实际退出1拒收，未为它新增自动绕过开关。

## 条件预算，不是已证明极值

若假设50mUI指output UI、可保守作为±0.05T的source duty误差，400ps可作为相关高脉冲时间的额外缩短预算，且将厂商source规格与工具clock-net spread独立组合，则100MHz下：

```text
min_high_at_load >= 5.000 - 0.500 - 0.400 - 1.982 = 2.118 ns
conditional MPW margin >= 2.118 - 0.900 = 1.218 ns
```

**这些组合/适用前提尚未确认，因此本式不是最终通过证据。** 周期/cycle-cycle jitter不是单edge绝对时间误差，也不能凭同一个数字自动推导两edge或多cycle界；需核实measurement point及是否与tree/duty指标重叠。即便另做更保守0.8ns假设仍数学为正，也不能用“多扣一点”替代缺失的规格定义和器件覆盖。

### 同步setup的另外一个待审门槛

父会话亲读core100最坏路径`timing_report.tr:239–274`：10ns关系、source同corner相消、route skew和DSP setup均分析，但**没有额外tUnc项**；生产SDC无显式setup uncertainty。当前+0.002ns不能默认已经包含datasheet的PLL动态抖动。

若经器件/工具模型审查决定还需额外400ps setup预算，则该路径将约为−0.398ns，需要继续真实优化。**没有擅自把条件预算写入生产约束，也没有假称该预算已验证。** 标准STA静态PVT极值与动态jitter是否已覆盖需分别说明；物理修复后必须重验全部setup/hold/reset/CDC/IO，不能套用旧布局结果。

## 下一步需要的确认

1. 用户提供FPGA完整丝印（含ES/速度等级等）及板上50MHz晶振清晰照片/型号；接线前另核PMOD2 Pin1方向。此请求不授权重新插板或烧录。
2. 核对该器件的实际VCC/VCCX与输入晶振jitter条件，不把板卡名称当准确part证据。
3. 厂商/适用文档明确50mUI的UI基准、误差定义/测量点，以及integer PLL在当前器件/ES/B/温压范围的适用性。
4. 明确PLL source共同路径悲观的合法处理方法（若有CPPR/PLL起点规则，请给真实工具版本适用依据），同时保留Gray物理界与stage2/普通状态时序。
5. 明确Gowin当前STA是否包含PLL period jitter；若未包含，选择有依据的setup uncertainty预算并再优化，目标仍100MHz。

以上是**待确认问题清单**，未替用户联系厂商、未外发工程、未操作Programmer。完整功能/周期/XML/STA证据见[`hardware_timing_review.md`](hardware_timing_review.md)首节。
