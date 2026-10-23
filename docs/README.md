# 文档索引

## 当前有效

| 文档 | 内容 |
|---|---|
| [ENGINE_INTERNAL.md](ENGINE_INTERNAL.md) | §0 为当前源码／验证摘要；后文保留早期目标稿和阶段记录 |
| [TIMING_RAM_ANALYSIS.md](TIMING_RAM_ANALYSIS.md) | 100MHz 时序余量与 BSRAM/逻辑/DSP 占用分析 |
| [diagrams/README.md](diagrams/README.md) | 新架构三张图和 review 说明 |
| [产品需求与竞品调研.md](产品需求与竞品调研.md) | 乐器硬件＋电脑上位机＋手机 App 的整套竞品比较；网页仅作次级参考（非实现报告） |
| [上位机可行性分析.md](上位机可行性分析.md) | 上位机/MIDI/链路可行性评估（讨论稿） |
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
