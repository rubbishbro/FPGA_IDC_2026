# 文档索引

## 当前有效

| 文档 | 内容 |
|---|---|
| [UI控制Loop与配置层设计.md](UI控制Loop与配置层设计.md) | 保持现有结构，独立 control_loop.sv 已实现；轮询／转交接口及 15 组独立仿真结果（2026-10-27） |
| [控制层与主循环设计调研.md](控制层与主循环设计调研.md) | 基于当前 router／通信／UI 的事件驱动控制建议、配置生效边界、MIDI 状态与时钟责任（2026-10-27，设计调研） |
| [ENGINE_INTERNAL.md](ENGINE_INTERNAL.md) | §0 为当前源码／验证摘要；后文保留早期目标稿和阶段记录 |
| [TIMING_RAM_ANALYSIS.md](TIMING_RAM_ANALYSIS.md) | 100MHz 时序余量与 BSRAM/逻辑/DSP 占用分析 |
| [ENG1_PY_MODEL.md](ENG1_PY_MODEL.md) | router 级 eng1 整数模型：A/B/C 共用核、位宽契约、RTL 对拍、试听与边界 |
| [diagrams/README.md](diagrams/README.md) | 新架构三张图和 review 说明 |
| [产品需求与竞品调研.md](产品需求与竞品调研.md) | 乐器硬件＋电脑上位机＋手机 App 的整套竞品比较；网页仅作次级参考（非实现报告） |
| [上位机可行性分析.md](上位机可行性分析.md) | 上位机/MIDI/链路可行性评估（讨论稿） |
| [通信子系统实现与汇报](../rtl/comm/README.md) | 独立 UART／HC-05 驱动、transport、会话协调和共享解析；含 13 项仿真／独立时序汇报 |
| [HC-05 设备驱动](../rtl/drivers/bluetooth_hc05/README.md) | 复用通用 UART、可选 STATE；已实现设备包装，历史设计单独归档，尚无实物验收 |
| [赛题要求完成度核对.md](赛题要求完成度核对.md) | 按基础／拓展／现场标准核对已做、待集成、设计空缺与自主增加项（2026-10-23） |
| [../FFT_spectrumshow/README.md](../FFT_spectrumshow/README.md) | 独立 FFT／频谱／瀑布核心，未接主引擎；含本轮编译阻塞记录 |

2026-10-22 实现复核基线 `cdc4e8a2`：核心回归 21 项 PASS；FFT 链级编译失败。已保存的 `router_probe` P&R 为 100.063 MHz／+0.006 ns，属于测试 ROM 探针，不是当前整机板级签核。

## 已归档

以下文档是重构前/中间稿，已移到：

```text
history/docs/legacy/
```

包括：

```text
新架构总览_step1.md
ENG1_ENG2_统一架构_2026-10-21.md
ENGINE2_REVERB_PLAN.md
```

历史图在：

```text
history/docs/diagrams/legacy/
```
