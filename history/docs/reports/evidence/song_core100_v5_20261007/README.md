# 歌曲工程v5原始资源与验收证据

本目录是2026年10月7日已有真实构建的证据副本，2026年10月9日归档；没有重新综合或生成新下载文件。

| 文件 | 内容 |
|---|---|
| `pnr_report.txt` | 最终P&R资源、时钟资源及实际pinout |
| `synthesis_resources.xml` | 综合阶段模块层次资源，不能替代P&R整机数量 |
| `timing_report.tr` | 原完整STA，保留负MPW |
| `trial_manifest.json` | 对应SRAM试验文件的版本、SHA及范围 |
| `cdc_review.json` | 父独立CDC端点与约束复核 |
| `bank_parent_acceptance.json` | 独立bank全范围综合网表父验收，不是整曲实板结果 |
| `pnr_resources.csv` | 从P&R报告提取的资源数量、容量与百分比 |
| `synthesis_hierarchy.csv` | 互不重叠的综合阶段模块分摊 |
| `resource_summary.json` | 汇总数据、版本、范围与限制 |
| `source_manifest.json` | 原报告绝对路径、原始SHA及字节数 |
| `SHA256SUMS` | 本目录文件校验清单 |

当前阅读入口：[工程汇报](../../../工程汇报.md)。本目录只保存证据，不另外维护进度。原报告保留工具自己的标题格式。

在本目录执行`sha256sum -c SHA256SUMS`可验证归档完整性。
