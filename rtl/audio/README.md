# I2S 音频输出

更新：2026-10-29。midi_voice_top/pad_voice_top的AUDIO_ENABLE、audio_clk、amp_*及音频实例已恢复；开启AUDIO_ENABLE后自动选择voice_router外部sample_tick。默认0仅兼容旧无音频时钟仿真，正式接线需显式开启并提供匹配资源采样率的audio_clk。源清单包含本目录三个.sv。

发送器和异步 FIFO 从 `history/rtl/audio` 复用；唯一新增的适配模块是 `i2s_audio_output`。发送为标准 I2S，左右各 32-bit 时隙，低 16-bit 有符号 mono 复制到左右声道。目标仍为 MAX98357A。

## 采样基准与数据流

```text
audio_clk -> i2s_amp_tx 帧节拍 -> toggle CDC -> core 域 sample_tick
                                               ├-> 激励 / 包络 / router 调度
                                               └-> 上一计算结果转 PCM -> async FIFO -> I2S
```

`voice_router.EXTERNAL_SAMPLE_TICK=1` 时直接使用 core 域 `sample_tick`，不生成内部整数分频。两个顶层在AUDIO_ENABLE=1时已自动置1并连接sample_tick。`start/run` 仍为运行许可，不能替代采样节拍。

tick K 更新激励/包络并开始一个样本的运算；计算结果在 K+1 边界进入 FIFO，在 K+2 边界开始发送。正常增加两个音频帧的排队时间，48kHz 时约 41.67μs；从停止恢复时允许先等待一个边界再计算首样本。FIFO 深度默认 16，不预填 16 帧。加载、停止、配置失败时仍按帧写零，BCLK/WS 连续运行。第一个有效 FIFO token 之前的启动零帧不报告欠载。

`Fs = audio_clk / (CLK_DIV * 64)`，模块参数 `CLK_DIV` 默认4、必须为>=2的偶数；顶层包装名为AUDIO_CLK_DIV。12.288MHz 对应 48kHz；12.5MHz 对应 48828.125Hz，两种配置的生产/播放速率都来自同一个源，不会平均漂移。`SR_HZ` 不生成音频模式的节拍，也不会把 12.5MHz 变成精确 48kHz。真实音频参考应与系数生成采样率一致；当前旧板 PLL 的 12.5MHz 不能算作精确 48kHz 的实板验证。

core/audio 两个时钟需持续运行，core 必须能观察到每一帧 toggle；本实现没有暂停 core 时钟后的补发协议。`rst_n` 共享异步置位；音频发送器及 FIFO 各域同步释放，顶层 core 复位释放应遵守系统时钟复位合同。同步器已标记 `ASYNC_REG`，整机仍需核对实际约束及 Gray 总线的跨域物理时序。

## PCM 与诊断

当前 router 输出按 `modal_step_pkg::YF=24` 解释。PCM16 转换为带正偏置舍入的 `y >>> (9 + PCM_HEADROOM_BITS)`，随后饱和到 [-32768,32767]。默认 `PCM_HEADROOM_BITS=3`，即单位增益换算后保留 3 bit 混音余量；设 0 为单位增益。实现使用高位符号扩展检查和16bit舍入增量，等价于原65bit扩展后加偏置/移位/限幅，避免极大输入加舍入量时回绕；624324组向量已逐位对拍。没有自动峰值归一化，也没有实现菜单音量消费者。

三个诊断为 core 域 sticky，复位清除：

- `audio_deadline_miss`：正常运行且已过恢复准备时间（最多两个帧边界，覆盖进入等待节拍及首样本计算），上一采样计算仍未交付；该 token 写零。
- `audio_overflow`：FIFO 写入时无空间，或同一采样窗口出现多个结果。这里报告丢样，不宣称发生此故障后仍无损。
- `audio_underflow`：音频域曾收到 token 后，在播放帧边界 FIFO 为空；发送零帧并同步标志。

按本次决定，暂不做 panic 的音频队列 flush/确认。现有维护仍清引擎并停止接收新的有效 PCM，但已排队或正在发送的旧样本会播放完；软件不能把引擎清理完成解释为 DAC 已原子清空。没有增加满 FIFO 重试队列；正常一帧进、一帧出由单一时间基准保证，故障由诊断暴露。

## 测试

完整矩阵执行 `python3 sim/run_audio.py`；可用 `--test eng1 --test bridge`只选模块用例。真实B类音色另用sim/run_sustain.py验证。命令在仓库根目录执行（Questa，沿用 `QSIM_INI` 或 `~/gowin/simlib_questa/modelsim.ini`）。整数向量由固定种子的 Python 标准库生成，输出/日志写入 `build/i2s_pipeline/audio`；`--out` 更换目录，`--test eng1/bridge/integration` 可重复选择。独立串行解码器只观察 BCLK/WS/DIN。

eng1 的五级流水为同步读、三个并行乘法、加减、舍入饱和、写回/累加，每拍一个模态。状态/地址/valid 同步前进，最后一次写回提交后才出 `y_valid`。接口和逐模态算术保持不变，修复 `n_modes=0` 误读写第一个模态。资源深度仍为 64：钢琴实际 64、吉他 20、eng1 首版 48；这不代表其余乐器的真实系数资源已验收。

本轮验证的是 RTL 功能、帧/样本一致性及所测规模的运算周期余量；不替代整机 PnR、板上时钟/引脚、真片 Flash、放大器容差及听感验收。统一板级已接I2S与真实菜单，但尚未接FFT/LCD音频采样通路；当前整板物理时序不通过。接线与验收见[板级说明](../platform/tang_mega_138k_pro/README.md)。
