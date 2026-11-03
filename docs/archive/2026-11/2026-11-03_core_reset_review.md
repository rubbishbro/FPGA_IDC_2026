# Core reset review — 2026-11-03

本轮仅 review core 根复位，不修改其 RTL。按用户要求不运行 PnR。

## 综合证据

基线为 `build/high_fanout_20261103/baseline/source` 的冻结源码，综合输出的 core 复位网 `u_system/n3143_6` 有 7502 个负载引脚（7315 CLEAR、152 PRESET、35 RESET）。完整分布见同目录 `2026-11-03_core_reset_review.json`。这是综合连接数，不代表实际布线长度或拥塞结论。

| 接收区域 | 引脚数 |
| --- | ---: |
| voice_router 自身 | 1963 |
| voice loader | 861 |
| stereo spatial | 847 |
| notes | 490 |
| instrument_system 自身 | 450 |
| pad LEDs | 350 |
| sound 自身 | 342 |
| pad input | 222 |
| record | 207 |
| guide | 169 |
| 两路通信 framer | 各 151 |
| voice input / gain | 134 / 130 |

voice 子树总计 3088；仅 emap_frame、part_pitch_delta、ctx_shadow 三组寄存器就贡献 1152 个负载。这比继续无差别复制所有复位更值得优先处理。

## 建议下一步

1. 在 `rtl/platform/tang_mega_138k_pro/instrument_system.sv` 现有三级 core_reset 的末级做并行复制：各副本取同一个 `core_reset[1]`，异步置复位、相同边沿释放，保留综合属性。按 voice、audio spatial、notes/guide、通信/外设分配驱动。
2. voice 内优先分离帧快照与控制、loader、input/gain。对 512 位 emap_frame、384 位 part_pitch_delta、256 位 ctx_shadow 再按接收区域分组。先保留原有复位值和有效位关系。
3. spatial 的 847 个负载单独做区域复位。是否进一步分左右声道，需要检查共享状态和打拍协议。
4. 每次分组先验证热复位、表加载中复位、停止/重启与跨模块有效位，再由统一 PnR 检查 recovery/removal、控制集与布局结果。

不要直接额外串一级复位；这会改变生产者和消费者的启动次序。也不要直接删除数据路径复位：先证明所有读取都被有效位屏蔽，尤其帧快照、loader 和引擎状态的首帧。

音频 FIFO/CDC 现有复位合同，以及 amp_sd 的 rst_n/audio_reset/audio_valid/audio_fault 安全关断关系，应单独保持。本次内部叶子分拆不能替代 core 根复位分区，反而会给根网增加少量叶子寄存器负载。

## 局限

更多独立复位驱动可能增加控制集并影响 CLS 打包。尚不能承诺时序或拥塞收益；最终以用户统一 PnR 的布局、最长路径和拥塞对比为准。本次未运行布局布线。
