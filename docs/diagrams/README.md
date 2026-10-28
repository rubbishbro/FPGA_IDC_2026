# 当前架构图

更新：2026-10-29。三张图按当前工作区更新，包含MIDI消费者、联合配置、持音压力调制和音频接线缺口；实线为现有内部连接，虚线表示待整机接入。具体接口见 [代码导读](../../CODE_ARCHITECTURE.md)，验证结果见 [维护记录](../工程评审与验证.md#verification)。图内不将旧 core PASS/Fmax 当作当前整机结论。

## 系统边界

[![系统边界](architecture_overview.png)](architecture_overview.svg)

[DOT 源](architecture_overview.dot)：已实现演奏消费者/音频模块、当前缺失的顶层连接、独立LCD与整机边界。

## 配置与显示提交

[![配置与侧栏](router_control_flow.png)](router_control_flow.svg)

[DOT 源](router_control_flow.dot)：摇杆/按键、control_loop、config_dispatch、联合配置后端、真实结果与显示快照CDC；独立demo未启用后端。侧栏 CDC 不覆盖主音频。

## router 与后级

[![router 数据流](engine_post_flow.png)](engine_post_flow.svg)

[DOT 源](engine_post_flow.dot)：双 bank、流水eng1与两路选核、单采样激励、逐声部包络/混音、五段腔体与四梳状混响。

## 历史图与重新生成

2026-10-22 的共享 RAM/router_system_top 图在 [历史目录](history/2026-10-22/)，保留当时的标注；更早四引擎图在 `history/docs/diagrams/legacy/`。它们不是 voice_router 的当前实例树。

从仓库根目录，对每个 DOT 文件生成对应 SVG/PNG：

```bash
dot -Tsvg docs/diagrams/architecture_overview.dot -o docs/diagrams/architecture_overview.svg
dot -Tpng -Gdpi=130 docs/diagrams/architecture_overview.dot -o docs/diagrams/architecture_overview.png
```

另外两张用相同命令替换文件名。字体使用 Noto Sans CJK SC；SVG 可缩放查看。
