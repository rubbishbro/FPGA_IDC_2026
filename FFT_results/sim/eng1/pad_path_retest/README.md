# 当前RTL设计派生的Python PAD重测

合成ADC矩阵 → 板级无效值处理/饱和乘4 → 64/48门控 → 原周期冲激/ADSR → Q24 ENG1。固定16槽C4..D#5，48k资源时基，无混响，原生mono PCM16/headroom3；已装载且选中PAD。不需要RTL仿真器；未声称本轮RTL对拍或实测演奏。

同一Hinos四小节15音符，保留原松键/重复音和间隔。比较阶跃与8ms上升/12ms下降的ADC压力；下降在原note-off结束，不修改包络或合并gate。

| 乐器 | 阶跃按键 | 渐变按键 | 配置、事件与结果 |
|---|---|---|---|
| 小号 | [听](trumpet/step_pressure_listen.wav) | [听](trumpet/ramped_pressure_listen.wav) | [结果](trumpet/results.json) |
| 小提琴 | [听](violin/step_pressure_listen.wav) | [听](violin/ramped_pressure_listen.wav) | [结果](violin/results.json) |

每版697600帧、14.533秒，15次按下和15次松开，模态及PCM均无触轨。四版正文RMS约-22.499dBFS。两种乐器各两版均仍有14段内部数字静音；压力渐变没有消除原断奏间隔造成的断裂。原基线与新阶跃路径非常接近，主要差别为板级压力量化；新激励/自动连奏候选仍不是当前实现。

`*_adc_bytes.npy`保留合成ADC输入，`*_pressure.npy`是板级适配后的力度，`*_gate_bits.npy`是16位门控快照，`*_raw_q24.npy`及`*_native.wav`为未经听感增益处理的输出。`*_listen.wav`只加恒定增益，无淡出、EQ、噪声或压缩。

运行：`python3 python/modal_sim/eng1_pad_audition.py --instrument trumpet`（或`violin`）。
