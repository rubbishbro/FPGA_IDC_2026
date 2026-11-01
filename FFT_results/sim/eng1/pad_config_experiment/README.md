# 同一PAD输入：原配置与实验配置

复用上一轮16路渐变ADC压力和门控。每版14.533秒/697600帧，15次按下、15次松开；逐帧确认gate完全相同，不合并重复音或改写乐谱事件。只改变指定合成模块。

| 乐器 | 原配置 | 实验配置 | 配置与核对 |
|---|---|---|---|
| 小号 | [听](trumpet/original_listen.wav) | [听](trumpet/experimental_listen.wav) | [结果](trumpet/results.json) |
| 小提琴 | [听](violin/original_listen.wav) | [听](violin/experimental_listen.wav) | [结果](violin/results.json) |

小号启用此前暂定的新双极性脉冲、起音周期/幅度扰动、少量模态前气流；G/a1/a2和原ADSR保持不变，没有额外直达气声或单独G增强。

小提琴启用20ms attack、full sustain、无decay、80ms release，保留原周期激励和模态系数；不启用旧bow_legato中的自动连奏事件重写。

两对分别匹配正文RMS，仅恒定增益，无淡出、EQ或压缩。四版模态和原生PCM均无触轨。小提琴内部至少1ms数字静音由14段降为1段句间休止；小号仍14段。数字静音计数不等同于主观音色评价。

输入链按当前RTL设计组织；新增激励和包络是明确启用的Python候选，尚未进入生产RTL。本次不要求运行RTL仿真器。

运行：`python3 python/modal_sim/eng1_pad_config_experiment.py --instrument trumpet`（或`violin`）。
