# v5物理位置对照与96负载坐标获取

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

2026-10-08。用户要求先看实际布局，用Matplotlib分析96个负载的欧几里得距离，再决定是否试区域约束；不以部分端点图代替完整分布。

## 当前可证

- 原v5关键路径7个原语坐标及6段数据走线来自真实`.tr`，共6.740ns数据走线、2.555ns单元延迟、0.344ns Clock→Q。
- 最长分支：`n1634_s6/F` R63C142[1][B] → `state_valid_279_s4/I1` R70C151[1][B]，3.979ns。欧几里得网格距离√130≈11.40。
- 上一段R74C135→R63C142，距离√170≈13.04，延迟仅1.106ns。因此最大延迟分支不是端点网格距离最大的分支；不能只用直线距离解释。
- 驱动网`n1634_12`由实际lane3综合网表确认96个输入负载，LUT2/LUT3；原STA只给出其中2个位置，另外94个仍未知。
- 图表：`/tmp/opencode/song-physical-map-v5-20261008-final/critical_placement.{png,svg,pdf}`，只标真实已知位置，连线不代表路由几何；不是完整芯片资源或拥塞图。

## 实际GUI导出的限制

DS打开官方FloorPlanner并执行Back-annotate，原始导出为`/tmp/opencode/song-placement-export-ds-20261008/out/v5_backannotated_all.cst`，SHA `cf061259684581faf0c3d093dd3219ef31af1d250148991d488fd5e65e2fb7a7`。

父亲自看了对话框截图、原CST，核实：窗口仅Port/Port Attribute/BSRAM/DSP/PLL/DSPLite；导出52 BSRAM、7 DSP、2 PLL及6组IO。**没有LUT/FF，因此这份导出不能用于96负载距离分布。**不能将文档泛称原语回标注直接推断为本版本支持全部通用逻辑。

父绘图工具对该真实导出亲跑解析门槛，按预期拒绝缺失关键LUT/DFF；未伪造完整图。门槛夹具测试5/5通过，人工夹具仅检验解析，不是FPGA位置证据。

继续途径：DS在完全隔离副本上尝试官方GUI逐实例定位/复制坐标。须先校准已知驱动和两个负载，不得复制任意鼠标网格作为实例位置；96/96位置未完成前不画完整分布。没有私有db猜解、解密或新P&R。

第二轮阶段报告：DS已核对运行中FloorPlanner的7个文件参数全部位于`copy_safe`，并报告Chip Array → Show Place View → All LUT / All DFF可以显示v5的通用逻辑放置。**这修正了“工具没有完整LUT数据”的推断，但不等于已经导出任何新增实例坐标。**具体实例名到位置的可追溯绑定仍未完成。

继续检查仅限常规GUI/可访问性控件、官方Highlight/tooltip/Copy Location等读取。禁止通过调试器/ptrace/注入库/调用私有槽函数唤出隐藏Finder；如果没有常规入口则记录限制，不无限扩展范围。父尚未取得96/96位置，完整距离图仍未生成。

## 误保存事故及父核验

第一轮GUI实际`-c`指向**原v5构建证据快照**中的CST，虽然网表/P&R来自副本。DS误触File→Save将该快照CST改写为815B，随后报告已从相同SHA的原始副本恢复。此操作违反只读范围，已向用户披露；不是可以忽略的“没修改”。

父独立核验：当前工作区CST与恢复后的v5快照逐字节相同，2271B，SHA `cc83e7300be862da20c23efe4eb67d7082a043cf841eb57e7ba2ffd53145b1a2`；SDC/bank/lane也逐字节一致。原v5工程、STA、db、p及综合网表SHA与事前记录相同，未重新构建或下载。证据`/tmp/opencode/song-placement-export-parent-review-20261008/parent_review.json`。SHA相同只证明当前内容恢复，不能抹去曾经写入的事实；mtime恢复不作为完整性证据。

第二轮要求所有GUI输入、约束、工程状态路径都处于隔离副本，启动后读取实际命令行核对；禁止Save、改位置或改约束，不能让GUI再次引用生产/冻结原文件。

## 绘图验收与边界

`sim/plot_song_placement_review.py`支持固定CFU位置导入，要求关键锚点与原v5 STA一致并定位全部96负载后才生成完整扇出图。若新GUI输出格式不同，须按实际schema审查适配，不猜名字或缺失位置。

完整数据到手后应画96个负载散点/距离直方图/min/median/P95/max及关键接收点距离排名。同R/C不同CLS子位置可能重合；R/C距离没有转换成物理微米，不等于实际线路长度或电气延迟。尚未试新的GROUP/GRP_LOC、并行译码或地址流水化；原MPW仍未通过。
