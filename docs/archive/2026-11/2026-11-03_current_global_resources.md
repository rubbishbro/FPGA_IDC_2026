# 当前全板资源占用（2026-11-03）

使用当前工作区 97 个源码文件的冻结快照进行 Gowin 综合，完成后逐个核对 SHA256，与当前源码一致。未运行 PnR。

| 资源 | 已用 | 总量 | 使用率 |
| --- | ---: | ---: | ---: |
| Logic | 73954 | 138240 | 53.5% |
| LUT（报告口径，含 154 INV） | 57911 | — | — |
| ALU | 16043 | — | — |
| Register / FF | 38209 | 139140 | 27.5% |
| BSRAM | 147 | 340 | 43.2% |

原始 LUT 原语 57757。综合报告显示的整数使用率依次为 Logic 54%、Register 28%、BSRAM 44%；上表按已用/总量计算到一位小数。

DSP 原语：MULT27X36 77、MULTALU27X18 14、MULT12X12 6、MULTADDALU12X12 10。不同原语尺寸不同，不将数量简单相加作为物理 DSP block 使用率。

相较上轮高扇出复位优化后的冻结基线，Logic 74206 → 73954（-252），FF 37671 → 38209（+538），MULT27X36 97 → 77（-20），BSRAM 不变。差异来自两轮源码快照间的 ENG1 和 pad_driver 修改，不应算作复位分拆收益。

全局 Logic 余量 64286，但该统计不能判断局部拥塞、控制网布线或实现后时序。物理结果留待用户统一 PnR。

证据：`build/current_resources_20261103/input_hashes.json`、`resource_summary.json`、`run.json`；原始报告：`build/current_resources_20261103/synthesis/instrument_board/impl/gwsynthesis/instrument_board_syn.rpt.html`。
