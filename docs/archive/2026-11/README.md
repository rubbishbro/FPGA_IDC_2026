# 2026-11 归档索引

本目录保留 2026-11 的原始报告/源文，供追溯；当前阅读入口在 [docs/README.md](../../README.md)。合并报告不复制全部细节，原文仍在这里。

## PnR / 资源

| 归档原文 | 对应当前报告 |
|---|---|
| [布线资源审查_20261102](./布线资源审查_20261102.md) | [2026-11-02 PnR 诊断](../../reports/pnr/2026-11-02_PnR诊断.md) |
| [PNR资源对比_20261102](./PNR资源对比_20261102.md) | 同上 |
| [布线搜索现场诊断_20261102](./布线搜索现场诊断_20261102.md) | 同上 |
| [LED与FF_ALU节点审查_20261102](./LED与FF_ALU节点审查_20261102.md) | 同上 + [热点与增长](../../reports/pnr/2026-11-03_热点与增长.md) |
| [current_global_resources](./2026-11-03_current_global_resources.md) | [资源与优化](../../reports/pnr/2026-11-03_资源与优化.md) |
| [logic_optimization_comparison](./2026-11-03_logic_optimization_comparison.md) | 同上 |
| [core_reset_review](./2026-11-03_core_reset_review.md) | [高扇出与复位](../../reports/pnr/2026-11-03_高扇出与复位.md) |
| [high_fanout_reset_ce_review](./2026-11-03_high_fanout_reset_ce_review.md) | 同上 |
| [control_fanout_implementation](./2026-11-03_control_fanout_implementation.md) | 同上 |
| [logic_pressure_review](./2026-11-03_logic_pressure_review.md) | [热点与增长](../../reports/pnr/2026-11-03_热点与增长.md) |
| [led_distance_wait_review](./2026-11-03_led_distance_wait_review.md) | [LED 等待](../../reports/pnr/2026-11-03_LED等待.md) |

## 现场/通信

| 归档原文 | 对应当前报告 |
|---|---|
| [flash_config_review](./2026-11-03_flash_config_review.md) | [现场配置失败](../../reports/2026-11-03_现场配置失败.md) |
| [local_reverb_test](./2026-11-03_local_reverb_test.md) | 同上 |
| [ui_diff_review](./2026-11-03_ui_diff_review.md) | 同上 |
| [bt_host_comm_review](./2026-11-03_bt_host_comm_review.md) | [蓝牙通信审查](../../reports/2026-11-03_蓝牙通信审查.md) |

## 已合并的合同源文

| 归档原文 | 对应当前合同 |
|---|---|
| [激励配置](./激励配置.md) | [激励与音色前端](../../contracts/激励与音色前端.md) |
| [小号时分复用优化](./小号时分复用优化.md) | 同上 |
| [ENG1_鼓噪声](./ENG1_鼓噪声.md) | [ENG1 扩展](../../contracts/ENG1_扩展.md) |
| [ENG1_aftertouch](./ENG1_aftertouch.md) | 同上 |
| [mod1_逐声部调制预算](./mod1_逐声部调制预算_20261103.md) | 同上（附录） |

## 一次性记录

- [烧录_20261102_0613](./烧录_20261102_0613.md)：0BFE 构建/烧录记录，作为 I05 的证据保留。
- [推送状态_20261103](./推送状态_20261103.md)：当天推送/测试快照，已被 [status.md](../../status.md) 取代。

## 证据 JSON

 review 的原始证据在 [reports/pnr/evidence](../../reports/pnr/evidence)：control fanout、core reset、high fanout reset/CE。JSON 文件名保留原日期前缀。
