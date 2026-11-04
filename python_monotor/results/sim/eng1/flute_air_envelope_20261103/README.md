# 长笛气息：复用包络乘法器的定点仿真

输入：现有 ENG1 模态输出。气息在包络乘法器前相加，不进入模态库。
公式：`y_env = signed64((signed64(y_modal + (air >>> shift)) * E) >>> 31)`。
复用 64×32 包络乘法；新增运算仅为 LFSR、单极点去直流的移位加减、乘前加法。
每声部独立固定种子，每音频帧推进一次；用旧 ADSR 控制起音和释放，E=0 时严格静音。
腔体保持生产直通，无额外 EQ、混响、压缩或后包络噪声。

baseline / air_light / air_medium / air_strong 使用同一固定播放增益。
含长音、短音、双音重叠和松键尾部。强度是试听选择，并非实测标定。
气息目前仅随 ADSR，不单独随 MIDI velocity/压力缩放。

这是算术结构实验；未改生产 RTL，未验证时钟调度、资源和 PnR。
原版逐样本复现检查、零包络静音、状态轨限、乘前加法溢出和 WAV 有限值/峰值检查见 results.json。

独立 SystemVerilog 算术检查已通过 8192 组 LFSR/滤波/移位/包络乘法向量；见 arithmetic_verification.json。此检查不代表完整路由时序验证。
