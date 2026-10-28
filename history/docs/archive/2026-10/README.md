# 2026年10月工程历史归档

**当前只读[工程汇报](../../工程汇报.md)。**此处保存20份被移出的轮次报告和旧说明，只供追溯；标题下的历史记录可能包含已被后续决定替代的“最新状态”，不能当成当前结论。

按问题查找，无须逐份阅读：

| 要追溯的内容 | 历史材料 |
|---|---|
| 模块实现与数值验证 | `rtl/`下模块2A、2B/2C、音频、箱体交付及箱体独立审查 |
| 原无声原因与修复过程 | [歌曲启动网表](rtl/song_startup_netlist_review.md)、[元数据修复](rtl/song_metadata_fix_review.md)、[地址与CDC迭代](rtl/song_control_timing_review.md) |
| 时序与模型疑问 | [整机时序迭代](rtl/hardware_timing_review.md)、[早期时钟模型](rtl/clock_model_review.md)、[PLL脉宽分析](rtl/pll_clock_pulse_audit.md) |
| 物理位置采集 | [96负载位置记录](rtl/song_placement_review.md)，含未完成项及误保存事故 |
| 板级早期操作与测试音 | `rtl/platform/tang_mega_138k_pro/`下旧交付、任务、操作说明与测试音验收 |
| 资源归档时的独立报告 | [v5资源报告](docs/reports/song_synthesis_resources_v5_20261009.md)，内容已合并到当前汇报 |
| 本轮四份专题文档（2026-10-20 归档） | [B类迁移硬件估算](docs/B类迁移硬件估算.md)、[双引擎统一顶层架构](docs/双引擎统一顶层架构.md)、[统一IIR合成数据格式与C类设计](docs/统一IIR合成数据格式与C类设计.md)、[音色合成缺陷台账](docs/音色合成缺陷台账.md)；结论已汇总到当前汇报第二节 |

保存原相对层级及文件名，正文不删除，标题/banner与相对链接作必要调整；不在旧路径留下重复副本。旧硬件实现说明的算法解释和推进路线也保留在`rtl/README.md`。原始工具证据未搬动，仍在`docs/reports/evidence/`与原本地构建目录。

历史正文中的`sim/test_*.py`命令和SHA记录保留当轮路径，不作为现行运行命令；测试现行分类及入口见[测试说明](../../../../sim/README.md)，原文件名可在`sim/catalog.json`中查到新位置。
