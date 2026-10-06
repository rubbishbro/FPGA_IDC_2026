# 持续测试音：父会话独立验收与下载文件

## 交付范围

用户报告歌曲版无声、VIN/SD约3.3V、BCLK/LRC示波器可见而DIN未捕获，明确同意另外编写连续测试音。诊断实现由用户指定的`opencode-go/deepseek-v4.1-flash`完成，父会话独立审查、仿真与真实工具构建，不凭实现者自述验收。

这是单独顶层`diagnostic_tone_top`，仅用真实12.5MHz音频PLL、48帧周期的±1024方波源和未修改的生产`i2s_amp_tx`。没有核心100MHzPLL、ROM、模态引擎、箱体、FIFO、麦克风或U4/按键输入。输出约1017.252604Hz、-30.10dBFS、BCLK3.125MHz、LRC48,828.125Hz；接线与原版相同，不把成功播放诊断音称为歌曲链路通过。

## 当前唯一交付文件

`build/diagnostic_tone_20261005/diagnostic_tone.fs`

- 绝对路径：`/home/rubbishbro/Desktop/FPGA_IDC_2026/build/diagnostic_tone_20261005/diagnostic_tone.fs`
- SHA256：`4d5276bb3737ad51862bb97e105224845564c33310efffb799ecf1c3304e93a0`
- 大小：34,668,942bytes。
- 用户手动使用`GW5AST-138B / SRAM Mode / SRAM Program`；不要写Flash，不要按RECONFIG。断电后需重新SRAM下载。
- 父会话只生成文件、未调用Programmer或操作板卡；器件ID由用户日志确认为`GW5AST-138B(0x0001081B)`，不因此推断完整ES/速度等级已核实。

## 独立数字验收

测试：`sim/test_diagnostic_tone_review.py`。使用仅用于仿真的PLL clock/lock模型，对真实诊断top、tone源和未修改I2S发送器重新编译、冻结源码后运行。

- 实际退出0，非空XML：**1/1通过、SKIP0**。
- 从外部BCLK/LRC/DIN解码**288个完整帧、576个signed16左右payload**，不以源内部phase作为黄金。
- 六轮完整48帧周期，包括锁失/重新锁定；每轮24帧+1024、24帧−1024，无停止或全零退化。
- 标准I2S WS后1bit delay、16bit payload、32bit/slot剩余补零；左右一致。
- 1152次采样到的DIN电平转换，1730次DIN/WS变化仅BCLK falling；数字模型相邻BCLK rising间隔320ns、frame20.48µs、fall到后续rise160ns。
- 失锁异步静音、清数据，重锁后首帧才启用SD；不依赖按钮。
- 证据：`/tmp/opencode/diagnostic-tone-review-v3/pin-sim/results.xml`及`/tmp/opencode/diagnostic-tone-review/tone-v3-pin-sim.log`。已核对仿真top/tone/I2S SHA与最终v4构建一致；v4只扩大报告，不改变功能RTL。

## 真实Gowin构建与报告

父入口：`sim/build_diagnostic_tone_review.py`（只syn/P&R，冻结13个输入，不覆写已有构建）；报告筛查：`sim/review_diagnostic_tone_reports.py`。

最终原始证据：`/tmp/opencode/diagnostic-tone-review-v4/`；交付目录同时保留`.tr`、`.rpt.txt`、pin HTML、flow日志、XML、逐文件SHA和`delivery.json`。

- Gowin V1.9.12.04，`GW5AST-LV138FPG676AES / B`，真实PLL参数和内部PLL_INIT保留。
- 96logic、59FF、0latch、1PLL、5port；无核心DSP/模态ROM，符合隔离诊断范围。
- **setup/hold违规端点0/0**；普通状态recovery/removal表正裕量；最坏setup+16.909ns、hold+0.247ns、MPW+7.281ns。
- 两个分析时钟：clk_50m20ns、clk_audio80ns；没有clk_core。
- `clk_audio→clk_audio` setup uncertainty额外0.400ns实际生效，路径有`tUnc -0.400`；这是诊断预算，不声称完整PLL jitter签核。
- 未使用source-latency替换、multicycle或普通状态的时序切断。三条hold例外只针对真实存在的`rst_sync_[012]_s0/CLEAR`；普通state由同步末级Q释放，其recovery/removal保留。该例外不是MTBF证明，也不覆盖普通逻辑。
- 输出包络约束、SD max-delay均Actived，无Ignored/Inactive约束；CST映射和3.3V电气与最终pin报告逐项核对：C21/B20/B19/A17，SD pulldown。
- SDC内`report_timing -setup/-hold -max_paths 300 -max_common_paths 1`扩大原完整报告（不改变时序约束）；从原Slow/setup及Fast/hold section分别提取三脚路径，不伪造corner元数据。

| 输出 | Fast最小source-to-pad/ns | Slow最大source-to-pad/ns |
|---|---:|---:|
| BCLK | 6.532 | 11.806 |
| DIN | 6.619 | 12.000 |
| LRC | 6.608 | 11.983 |

在RTL名义160ns半BCLK与**假设10ns板级skew/jitter预算**下，DIN条件setup/hold下界约144.532/144.813ns，LRC约144.549/144.802ns；均大于MAX98357A要求10ns。此为报告极值与假设组合，不是用户杜邦线/模块或完整PLL条件的实测证书。

已亲读并保留真实工具警告：PLL_INIT两条既有EX3791位宽截断及输入参考`clk_d`的PR1014 generic routing警告；实际STA反映其布局/route并为正，但不能把警告删掉或说零警告。该诊断无额外跨域数据/Gray FIFO。raw lock→SD的组合静音路径未有单独完整异步路径签核，保留为范围限制。

## 被拒收的中间版本

- v1：不支持的裸对象`set_clock_uncertainty`语法，PnR未完成，虽然gw_sh退出0也拒收；父runner现在同时检查ERROR、无效Tcl和PNR_DONE，不以退出0代替证据。
- v2：真实Removal违规14，最坏−0.262ns；原始lock与同步末级再AND绕过同步释放，未交付。只改诊断reset使其由同步末级输出释放，不追加普通state false-path。独立STA解析实际拒绝v2作为负控制。
- v3：功能与STA正，但构建末尾在gw_sh上下文调用SDC的`get_ports`无效，专用报告未导出，拒收为最终报告证据。v4把报告命令放回SDC，最终完整报告筛查实际退出0。

## 主工程保护与实板下一步

已逐项复核冻结歌曲版26个RTL/IP/ROM/CST/SDC输入SHA未变；未修改算法、频率、II或任何主工程时序有效命令，旧`parent_core100.fs`未覆盖。只新增独立诊断工程与父工具/说明。

下载诊断版后应持续发音，不需按键。若仍无声，先测MAX模块端DIN有无持续跳变，再对比FPGA B19端；若DIN/时钟到达且格式正确，再查模块/喇叭。示波器地夹只接公共GND，不接OUT+/OUT−。诊断版实板结果尚待用户回报，不等同全温压/PVT或冻结歌曲版硬件放行。
