# 2026-10-05 Demo版本冻结与时钟核对

用户同意先冻结当前实现、核对时钟并准备MAX98357A/3W8Ω喇叭接线。**此次不是烧录授权、不是完整物理时序放行，也不再继续为setup余量数字优化RTL。**

## 冻结内容

已在独立目录保存39个输入：全部生产sources.f列出的RTL及真实PLL/IP、三ROM、CST/SDC、工程入口/manifest/preflight，以及独立验收工具。未修改RTL、ROM、PLL或有效时钟约束，未commit/push/Programmer，未回退工作区。

- 快照：`/tmp/opencode/demo-freeze-20261005/parent_source_snapshot/`
- 完整逐文件SHA清单：上述目录中的`sources.json`。
- 清单SHA256：`f860d35233d5a55f5e6d57eaac4706ab19457d8fed8f46646308516822ca6359`
- 冻结摘要：`/tmp/opencode/demo-freeze-20261005/freeze_summary.json`
- 原始亲跑core100报告原样复制：`/tmp/opencode/demo-freeze-20261005/reviewed_core100_reports/`

| 关键输入 | SHA256 |
|---|---|
| `rtl/core/poly_modal_lane.sv` | `bad892593e965e85ebbc811550d4cca0b8cc37ee3eca57f1cee6f9e453cf5b75` |
| `rtl/core/modal_poly_bank.sv` | `0a812b8c5b135e13899e90dcc59b50473575d75dbc7c5a556e75ecda8f9cd907` |
| `rtl/core/modal_engine.sv` | `1834637cd746df125598f05ae018a9d6a3856618e342854c5019f9a7df6a6e9a` |
| `rtl/core/body_filter.sv` | `00d8e13d3d695f14f1b8c709b17c8a923f09968cd737bfcfc77f052ffbcf9456` |
| 平台SDC | `291a01f79e7781a41233952f2e5caa411ef5ec1fb503724f49a5b649ee7be7f3` |
| 平台CST | `9e8b93110a81a4b09bd0cffb8dc7028e2db9c07981787bb395f82c9170166b8c` |

已逐项核对：生产RTL/IP与此前父会话亲跑core100快照相同，只有其TEMP `board_top`三ROM绝对路径曾作构建目录重定位；ROM/CST逐byte相同，SDC有效命令相同（注释更新所以文件SHA不同）。不把说明文件更新当新功能构建结果，也没有为了注释重跑syn/PnR。

## 时钟核对结果

| 项目 | 冻结配置/预期 | 核对依据 |
|---|---|---|
| 板上输入 | 50MHz，周期20ns | PLL FCLKIN、SDC、clk=P16 |
| 核心 | 100MHz，周期10ns | integer PLL：50×14/7=100；SDC×2；真实STA Clock Summary |
| 核心VCO | 700MHz | MDIV14、IDIV/FBDIV1，位于手册650–1300MHz范围 |
| 音频参考 | 12.5MHz，周期80ns | integer PLL：50×13/52=12.5；SDC×25/100；真实STA |
| 音频VCO | 650MHz | MDIV13，手册范围下限 |
| BCLK | 3.125MHz，周期320ns | 标准I2S TX CLK_DIV=4 |
| LRC/WS | 48,828.125Hz，周期20.48µs | 每frame64个BCLK，32bit/slot |
| 数据 | 16bit mono复制到左右slot，WS后1bit delay | 冻结I2S RTL和已亲跑引脚解码测试 |

两个PLL都为INTERNAL feedback、fractional值0、DT_STEP0的名义duty配置，使用真实`PLL`原语。IP接口`clkin/init_clk/clkout0/lock`与wrapper一致；并未接外部100MHz或用Fmax替代PLL配置。MAX98357A不需要MCLK，**不要把50/100/12.5MHz参考时钟接到其BCLK**。

审查日志`/tmp/opencode/demo-freeze-20261005/clock-pin-audit.log`核对了快照全部SHA、PLL计算、SDC比例、I2S divider及CST。`preflight.py --no-tool`实际退出0，日志同目录`structural-preflight.log`；此门槛不启动Gowin、不等于物理STA通过。

频率仍为诊断口径：48k系数以48,828.125Hz输出，比48k快约1.725%，不是48k保真或实测频率。

## 验收边界

功能/周期/矩阵/4096样本证据保留，详见[`hardware_timing_review.md`](hardware_timing_review.md)。完整真实构建的setup/hold为0/0、最坏setup约+0.002ns；MPW仍按未覆盖模型−0.514ns/OPEN，PLL动态uncertainty覆盖待审。未恢复被拒收的共同名义source-latency。

后续重点为准确part/时钟模型核对和明确授权后的实板demo，不反复改数值算法或追求漂亮Fmax。当前仍无实板出声/稳定性结论，物理part和PMOD方向未知。

接线说明见[`platform/tang_mega_138k_pro/MAX98357A_WIRING.md`](platform/tang_mega_138k_pro/MAX98357A_WIRING.md)。用户可按丝印准备断电接线；通电前需确认J26 Pin1、模块针名与板卡供电，不将“先冻结、告诉接线”视为自动烧录授权。
