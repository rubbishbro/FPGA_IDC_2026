# Logic 优化前后对比（2026-11-03）

全部采用综合报告的 Logic = LUT（含 INV）+ ALU 口径，器件容量 138240；本次只读取已有报告，未运行新综合或 PnR。

| 版本/快照 | Logic | 占比 | 证据目录（build/ 下） |
| --- | ---: | ---: | --- |
| 小号 TDM 前整板快照 | 102,341 | 74.0% | `ui_pan_pnr_20261102/implementation_v2` |
| 小号 TDM 最终版 | 68,961 | 49.9% | `trumpet_tdm_20261102/board_final` |
| mod1/aftertouch 修正版 | 70,861 | 51.3% | `pnr_20261103_mod1fix2` |
| 本轮控制优化前（含当时 ENG1） | 74,239 | 53.7% | `high_fanout_20261103/baseline/synthesis` |
| part_tick 同拍复制 | 74,239 | 53.7% | `high_fanout_20261103/tick/synthesis` |
| 模块级复位拆分 | 74,206 | 53.7% | `high_fanout_20261103/reset/synthesis` |
| 当前源码 | 73,954 | 53.5% | `current_resources_20261103/synthesis` |

每个证据目录内报告均为 `instrument_board/impl/gwsynthesis/instrument_board_syn.rpt.html`。

最近一轮严格控制对比：part_tick 复制不改变 Logic；模块级复位分拆减少 33。随后当前源码的 ENG1/pad_driver 修改使 Logic 再减少 252，总计 74239 → 73954，减少 285（0.38%）。复位与 CE 优化的目标是降低单网扇出、改善后续布线，不是显著减少全局 Logic。

早期 102341 与当前 73954 相比净减少 28387（27.7%）。这些跨版本快照之间也有功能变更，尤其小号 TDM 后的 mod1/aftertouch、ENG1 修改，不能将相邻差值全部归因于单项优化。

未纳入 `eng1_shared_board_syn` 的 53400 和 `pnr_20261103_eng1_shared` 的 53274：两份综合日志都有 envelope_ADSR 与 excitation_gen 被 swept 的记录，缺少证明其完整保留功能的依据，不能作为有效优化收益。这与先前分组复位写法的异常裁剪风险一致。干净副本 `eng1_share_clean/build/pnr_20261103_0235` 的 Logic 为 73948，与当前 73954 接近。
