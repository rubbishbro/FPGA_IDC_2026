# 高扇出控制优化实施 — 2026-11-03

按用户指定顺序完成 part_tick 同拍复制、内部复位分组，并 review core 根复位。未运行 PnR，布局布线由用户统一测试。

## RTL

- voice_router 保留原协议 part_tick，另外两个并行寄存器从相同 smp_tick_q 取数，分别驱动激励和包络；无新增数据流水延迟。使用 syn_keep/syn_preserve 保留副本。
- child_reset 从 7 条扩为 15 条，同样异步断言、两拍释放。分离通用激励控制、小号、mod0/pitch、两路 eng0/eng1。包络保留原有独立复位，parts 算法模块不修改。
- wrapper 默认 SPLIT_RESET=0，原有独立使用方式保持；仅 voice_router 显式打开分组复位。
- 状态机、激励/包络算法、系数以及音频资源 BIN/MEM 不变。resources.json 仅更新 exc_router 源文件 SHA。

## 验证

`python3 sim/run_control_fanout.py` 通过。测试使用冻结的修改前 wrapper/parts 生成 reference，并与当前实现逐周期比较：

- SLOTS=4、7、16，各 60000 时钟，覆盖不同声部数、六种旋律乐器、门控、重触发、清槽、弯音输入及热复位。
- 完整 voice_router 的 QSPI 表加载、失败、加载中复位、中止与重试；包含非零音频，逐周期比较输出/状态，并检查真实 tick 副本与复位分支同拍。
- `sim/check_performance_resources.py` 通过；资源镜像 SHA256 为 `e9de9737735eda50f03853c959d162868949b2a80ec202dce992d3924c3ca900`。
- 当前板级源码使用仿真 PLL、ADC 占位模型完成 elaboration/lint；不是板级行为仿真。

测试基线与日志在 `build/high_fanout_20261103/`。可通过 `--baseline-dir` 指定保留的修改前源码。三个综合阶段使用同一冻结源码，仅逐步加入本轮控制修改，避免并行 ENG1 音色修改影响因果对比；功能对比使用当前相同的 engine 实现。

## 综合检查

part_tick 单独阶段已经确认独立寄存器未被合并：1799 引脚（1712 CE）拆为 env 1104（1088 CE）及 exc 694（624 CE），最大分支负载下降约 39%，增加两个 FF。

尝试过每四声部细分复位，但当前 Gowin 在完整层级综合中异常裁剪了激励/包络，即使 RTL 仿真通过且独立模块综合正常。逐声部展开与扁平复位向量均未解决，因此交付范围收敛为模块级复位分拆；激励/包络 parts 已恢复原实现，不交付四声部细分。扁平 child_reset 位向量中每两位仍是一条同深度复位链。

最终综合网表中 DFF 原语从 37653 增至 37671，正好增加 18 个（16 个复位链 FF、2 个 tick FF），激励与包络均保留。计数见 `2026-11-03_control_fanout_evidence.json`。

| 控制网 | 基线引脚数 | 最终分支引脚数 |
| --- | ---: | --- |
| part_tick | 1799 | env 1104 / exc 694，协议支路单独保留 |
| exc reset | 2199 | generic 1649 / trumpet 537 / wrapper 13 |
| mod reset | 1783 | pitch 1248 / mod0 534 / wrapper 1 |
| 每路 engine reset | 1007 | eng0 549 / eng1 458 |
| env reset | 1120 | 1120 |
| core 根复位 | 7502 | 7520 |

两路 engine 的数字均来自本次同一冻结基线，包含当时的 ENG1 实现，与早先 review 使用的旧网表数值不同。core 增加的 18 个负载符合新增 FF 数量；本轮没有降低根网扇出。

综合扇出仅代表连接数，不代表布局或 STA 收益。更多控制集可能影响寄存器打包。

Core 根复位暂不修改，详见 [core review](./2026-11-03_core_reset_review.md)。物理拥塞、时序、复位 recovery/removal 留待用户统一 PnR 验证。
