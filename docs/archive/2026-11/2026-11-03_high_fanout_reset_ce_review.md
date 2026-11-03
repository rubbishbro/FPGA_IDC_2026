# 高扇出复位与 CE：局部拥塞优化 Review

日期：2026-11-03。范围：只读审查源码、综合网表和已有 PnR 结果；未修改生产 RTL/约束，未运行新仿真、综合或 PnR。

**结论**

值得做有针对性的控制网拆分。首个实验建议选择 `part_tick` 同拍复制和声部分组，其次是 exc/env 内部复位分组；更广泛的 core 域复位分区另做一轮。优化目标是降低跨区域控制网的负载和长度，不能承诺仅凭复制就直接消除局部拥塞。复制可能增加 FF/LUT 和不同控制组合，影响 CLS 打包。

**证据与版本边界**

- `build/fanout_old70k/fanout.json` 指向通过的 `build/pnr_20261103_mod1fix2/.../instrument_board.vg`；已重新校验网表 SHA256。`unknown_primitive_ports=[]`。
- `fanout_new74k` 实际对应更早的 `pnr_20261103_0115`，不能按目录中的 old/new 判断时间顺序。
- mod1fix2 基线 PnR 已通过，CLS 51435/69120，约75%；setup +0.050ns、hold +0.181ns、recovery +10.581ns、removal +0.349ns，core Fmax50.125MHz。place/route 配置3/2。
- 当前源码相对该基线有12个输入文件变化，包括 eng1、instrument_system、配置与 UI。以下负载是该网表的实测结构计数，不冒称当前 HEAD 的重新综合结果。完整漂移清单和哈希见同目录 evidence JSON。
- 扇出单位为原语输入引脚数。没有本轮生成的实际网络跨度、路由长度、局部拥塞坐标或控制网专门 recovery/removal 路径，不能据此确定拥塞根因。
- 已有最差 setup 路径是 event_fifo/out_data→guide/notes→hold_count；次差包含 voice/state→input/note_on→note_pend。复位/CE不是现有报告中已经证明的最差 setup 路径。

| 对象 | 基线负载 | 具体观察 | Review判断 |
|---|---:|---|---|
| core 域复位反相网 |7445|7258 CLEAR、152 PRESET、35 RESET；跨 voice3088、audio918、notes490、通信等|不是ENG1本体复位。需要按实际区域分区，不能只在voice内部复制|
| exc复位|2199|acc512、tgt512、published_x512、cnt256、pitch_phase256等|已有模块级叶子，内部仍太集中；按功能/声部细分|
| modr复位|1783|next_delta384、active_delta384、levels_q/job112×2等|modulation0/1共用复位，优先拆两个消费者，再按需拆数据状态|
| env复位|1120|lvl512、emap512，另有状态、dead、门控历史|可按4个声部一组划分；不能直接删除lvl/emap反馈复位|
| era/erb引擎复位|824/824|每条同时别名到该lane的eng0和eng1|应称引擎lane复位，不是ENG0独占；先拆eng0/eng1再评估流水数据|
| part_tick|1800|1712 CE，另有LUT输入；跨exc/env等消费者|首个低侵入实验；保持周期与快照一致|
| smp_tick_q|696|689 CE|第二层目标，避免part_tick下降后瓶颈只是转移|
| env sustain_mode_r|920/920|已有两份寄存驱动，但每份仍有大量LUT输入|CE/reset优化后复查；与s_level_r等模式/参数广播一起评估|

对应源码：

- `rtl/platform/tang_mega_138k_pro/instrument_system.sv:39`：core/audio/pix 三级域复位。
- `rtl/router/voice_router.sv:110`：7组两级 child_reset；当前已做第一层复位分区。
- `rtl/router/voice_router.sv:337`：part_* 快照和 part_tick；`:356/:364`分别进入exc/env。
- `rtl/router/parts/excitation.sv:114`：全槽数据与控制共用reset/CE。
- `rtl/router/parts/envelope.sv:85`：lvl/emap等全槽寄存器共用reset/CE。
- `rtl/router/routers/mod_router.sv:78/:89`：两个调制器共用复位。
- `rtl/router/routers/eng_router.sv:92/:104`：eng0/eng1共用lane复位。

**方案A：part_tick同拍分发，建议先做**

1. 在原快照边界，由相同的 `smp_tick_q` 同拍产生 exc/env/协议控制各自的 tick 副本；保持当前复位值与有效周期。不采用 `local_tick<=part_tick` 后只替换部分消费者，这会多出一拍。
2. 第一轮先拆消费者，不同时改复位树。第二轮按需要把env拆成4组×4声部，exc按gen/trumpet及声部区域分组；目标先试每叶约256–512个负载，并比较两种粒度。目标不是硬性器件指标。
3. 保持 part_clear/gate/trigger/strike/pitch_delta 同一快照，检查 xmap_valid、emap_valid、frame_start、part_commit 和 pitch_commit_ok 不错帧。上层协议判断可以保留低扇出的原tick，但它与各副本必须逐周期相等。
4. 复制必须真实保留到综合网表，并让各副本只驱动所属区域。单纯assign改名不产生驱动复制；不同名字和RTL属性也不等于布局时已经局部化。
5. 限定复制属性范围，先做小规模综合探针，确认等价寄存器不会重新合并。不要给全设计 blanket preserve。

收益预期：将集中在exc/env的1712个CE负载分摊，减少跨模块广播。风险：增加控制组合后CLS打包变差；复制寄存器没有靠近负载则收益有限；时序错拍会直接破坏音频帧一致性。

**方案B：第二层局部复位树**

1. 延续已有异步断言、同步释放，不改成功能寄存器直接吃异步板级复位。
2. exc按generic/trumpet和声部组细分，env按4声部一组；modr拆mod0/pitch；era/erb各自拆eng0/eng1，原A/B lane并行关系保留。
3. 对需要增加分发级数的区域统一评估复位深度。共同同步源之后的分发应同级，跨支路通信在所有相关叶子ready后才能启动。不能让一个模块先运行并对仍在reset的模块发单拍请求。
4. core父网的7445负载另按音频/router、通信、notes/guide、外围处理等实际布局区域分区；若树根还直接驱动数千功能寄存器，仅增加少数叶子不能解决根网负载。
5. 更新与检查STA reset集合匹配；新增叶子同步器的异步入口例外不得吞掉功能寄存器的recovery/removal。CDC/FIFO reset、PLL失锁静音和异步断言行为保持原合同。

收益预期：让上千个CLEAR/PRESET端点由附近叶子驱动。风险：额外复位延迟、释放偏斜、上层启动顺序和新控制组合。复制树主要降低物理负载，不等于减少寄存器数量。

**方案C：减少确实无必要的数据复位，后续单独审查**

可审查eng流水乘积/地址、modr输出缓存、快照数据中“首读前必写且valid已复位”的部分。每块必须列出首写、全部读者、valid/clear支配关系以及异常恢复。FSM、valid、门控历史、递归模态/包络状态、音频历史、CDC指针不能直接套用。删除reset后也不能给每一位加rst_n门控CE，从而把负担搬到CE。该方案对部分dataflow推导可能有额外收益，但功能风险高于先复制控制网。

**工具约束结论**

Gowin官方 SUG550-1.6 §5.10明确列出 `syn_maxfan` 对CLK、CE、LSR相关inpin不适用。因此对本次主要落在CE/CLEAR上的负载，不把自动maxfan当作实施主方案；以明确的驱动分组和综合网表验收为准。不同版本应在本机工具做小探针确认。`syn_keep/syn_preserve`也应按对象和实际效果验证，不能仅凭属性存在宣布复制生效。

官方原文来源：[GowinSynthesis用户指南，§5.10](https://cdn.gowinsemi.com.cn/SUG550-1.6_GowinSynthesis%E7%94%A8%E6%88%B7%E6%8C%87%E5%8D%97.pdf#page=48)。

不建议作为第一轮方案：全局maxfan、原始CE的组合门控时钟、直接接动态GSR、大范围放宽false path/recovery/removal、一次性删除整个模块reset，或没有拥塞位置依据的硬floorplan。

**实施顺序与验收**

1. 用当前输入重新建立可对照的综合/PnR基线，导出前20条控制网的原语pin计数、驱动、负载位置跨度与拥塞图；保留源哈希。此前mod1fix2结果继续保留。
2. 仅做方案A消费者级同拍复制；综合核验实际驱动数/映射/CE分摊，再用相同place3/route2比较PnR。
3. 有收益再做A的声部分组；随后独立做B的exc/env局部复位，最后评估跨系统core树。
4. 每轮记录CLS/FF/LUT/BSRAM/DSP、独立reset/CE组合、目标网最大扇出及物理跨度、路由时间/未布通网、setup/hold/recovery/removal结果。主要STA检查保持零违反。不要把降低最大扇出作为唯一成功条件。
5. CE同拍复制按周期比较tick、快照、状态写回、PCM；验证单音/满复音、note-on/off/retrigger、PAD/MIDI切换、装载和pitch原子提交，确认deadline无变化。复位树实验额外覆盖运行中复位、PLL失锁、不同复位相位、装载中断、FIFO在途及恢复首帧。
6. 先固定实现配置比较；对保留候选再用工具支持的不同place/route选项检查结果稳定性。只有实测路由跨度/拥塞和时序不劣化，才接受为改善；本报告不预估确定的ns收益。

本轮交付为review和可能方案，不包含已实施或已验证的RTL优化。
