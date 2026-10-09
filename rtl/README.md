# 硬件代码说明

**项目进度、资源占用和验收结论只看[工程汇报](../docs/工程汇报.md)。**本目录不再并列维护轮次汇报。

| 目录 | 内容 |
|---|---|
| `core/` | 模态运算、系数装载、调度和共享箱体 |
| `audio/` | 歌曲调度、跨域FIFO和音频接口 |
| `platform/tang_mega_138k_pro/` | 板级顶层、PLL、约束及独立诊断工程 |
| `rom/` | 系数与索引初始化数据 |

## 开发时查阅的规格

- [冻结设计约定](DECISIONS.md)：以此为准；未冻结项由作者决定，AI不擅自假设。
- [单声部运算阵列规格](module2A_design.md) / [系数装载与多声部调度规格](module2BC_design.md)。
- [共享箱体规格](body_design.md) / [音频启动规格](audio_bringup_design.md)。
- [代码衔接架构](../CODE_ARCHITECTURE.md) / [仿真环境与用法](../sim/README.md)。

AI按冻结规格实现并提供逐位验证，作者审查和判定。数值参考为`python/modal_sim/fixed_point.py`，不能将实现者自测当作独立验收。早期算法说明、推进路线及各轮报告已保存在[历史归档](../docs/archive/2026-10/)，日常不必逐份阅读。
