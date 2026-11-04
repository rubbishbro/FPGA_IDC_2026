# 文档索引

更新：**2026-11-04**。用户已确认整机联调及全部功能测试通过。当前验收结论集中在状态页，接口定义集中在合同，分阶段测试与分析保留在报告中。

## 交稿阅读顺序

| 文档 | 内容 |
| --- | --- |
| [当前状态](status.md) | 整机验收结论、最新保留构建及交付范围 |
| [问题关闭状态](bugs.md) | 当前无未关闭功能问题；历史问题入口 |
| [上板功能验收](上板测试.md) | T01–T16及跨模块联调通过汇总 |
| [整机验收记录](reports/2026-11-04_整机联调与功能验收.md) | 2026-11-04用户确认与文档收口 |
| [报告索引](reports/README.md) | 按时序、配置、录制、资源和音频分类的全部报告 |
| [调试记录](调试记录.md) | 按时间保留的执行过程与证据 |

## 接口与实现合同

| 文档 | 内容 |
| --- | --- |
| [通信协议约定](contracts/通信协议约定.md) | 串口/蓝牙、帧格式、命令、结果码、鼓件编号与录制事件 |
| [自定义键位与演奏指引](contracts/自定义键位与演奏指引.md) | 16 键绑定、回滚、来源屏障与 UI 行为 |
| [板级引脚](contracts/板级引脚.md) | 板级 IO 与引脚约束 |
| [激励与音色前端](contracts/激励与音色前端.md) | 逐乐器激励与小号 TDM 流水 |
| [ENG1 扩展](contracts/ENG1_扩展.md) | 鼓噪声、aftertouch 与 mod1 预算 |
| [声像配置](contracts/声像配置.md) | 运行时声像配置及结果合同 |
| [合唱预设](contracts/合唱预设.md) | 本地合唱参数、外部协议限制及验证范围 |

## 使用与产品资料

- [两种合成引擎的Python模拟](../python_monotor/README.md)

- [Web 采样演奏与键位配置](web采样演奏.md)
- [力度响应与新增音色增益标定](reports/2026-11-04_力度与新增音色增益标定.md)
- [产品调研](product/产品调研.md)
- [参赛视频脚本大纲](product/参赛视频脚本大纲.md)
- [赛题要求](../reference_agent_readfirst/competition_requements_most_important.md)
- [鸿蒙配置应用串口模拟器](../ePiano_config/sim_receiver/README.md)
- [长笛固定音色仿真基线](../python_monotor/modal_sim/presets/flute_soft_legato_v1/README.md)

## 维护与历史材料

1. 新报告放入 `reports/`，PnR/时序专项可放入 `reports/pnr/`，命名为 `YYYY-MM-DD_主题.md`，并加入[报告索引](reports/README.md)。
2. 状态只在 [status.md](status.md) 汇总，问题及关闭条件只在 [bugs.md](bugs.md) 维护；调试记录和历史报告保留当时上下文。
3. 引用资源或时序结果时附日期、源码指纹及综合/物理阶段。构建验收、下载成功与实板功能验收分别记录。
4. `history/`、各处 `archive/` 已删除，历史原文通过 Git 查阅。旧构建路径表示当时的产物位置，交稿目录不保留这些产物；`build/` 仅保留最新构建及其验收证据。
