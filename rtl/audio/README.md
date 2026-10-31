# I2S 音频输出

更新：2026-10-29。midi_voice_top/pad_voice_top的AUDIO_ENABLE、audio_clk、amp_*及音频实例已恢复；开启AUDIO_ENABLE后自动选择voice_router外部sample_tick。默认0仅兼容旧无音频时钟仿真，正式接线需显式开启并提供匹配资源采样率的audio_clk。生产源清单以板级sources.f为准。

发送为标准 I2S，左右各 32-bit 时隙，每声道前 16 bit 为有符号 PCM，余位补零。正式路径默认启用 `STEREO_ENABLE=1`：总混音/腔体/混响后的 signed64 → `stereo_spatializer` → 左右 PCM16 → 32-bit 成对 FIFO → I2S。`STEREO_ENABLE=0` 显式保留旧单声道复制到左右的逐位兼容路径。

新增模块使用 33 档近似等功率增益、Q4 位置平滑、移位加法 ILD 和辅助 Q6 分数 ITD；不使用乘法器。完整方案、接口及验证结果见 [双声道空间定位方案](../../docs/双声道空间定位方案.md)。位置输入 `pan_position` 为同 core 域 0..32，16 居中，越界钳位；`itd_enable` 仅控制同一位置对应的辅助时差，不独立定位。

Pebble V2 使用 3.5 mm 双声道模拟输入，USB-C 仅供电；本板已接通板载PT8211/耳放的J29，可直接用3.5mm线连接AUX。MAX98357A 是喇叭功率放大器，不能直接把功率输出接到 Pebble AUX。当前信号名 `amp_*` 仅为兼容原工程，不能据此推断新 DAC 的 MCLK/静音/供电接法。

## 采样基准与数据流

```text
audio_clk -> i2s_amp_tx 帧节拍 -> toggle CDC -> core 域 sample_tick
                                               ├-> 激励 / 包络 / router 调度
                                               └-> 上一计算结果 → ILD/ITD → 双路 PCM → async FIFO → I2S
```

`voice_router.EXTERNAL_SAMPLE_TICK=1` 时直接使用 core 域 `sample_tick`，不生成内部整数分频。两个顶层在AUDIO_ENABLE=1时已自动置1并连接sample_tick。`start/run` 仍为运行许可，不能替代采样节拍。

tick K 更新激励/包络并开始一个样本的运算；计算结果在 K+1 边界进入 FIFO，在 K+2 边界开始发送。正常增加两个音频帧的排队时间，48kHz 时约 41.67μs；从停止恢复时允许先等待一个边界再计算首样本。空间处理另占 26 个 core 周期，100 MHz 时为 0.26 us，仍在该帧预算内，不额外排队一帧；ITD 默认较弱侧最多延迟 4 样本。FIFO 深度默认 16，不预填 16 帧。加载、停止、配置失败时仍按帧写零，BCLK/WS 连续运行。第一个有效 FIFO token 之前的启动零帧不报告欠载。

`Fs = audio_clk / (CLK_DIV * 64)`，模块参数 `CLK_DIV` 默认4、必须为>=2的偶数；顶层包装名为AUDIO_CLK_DIV。12.288MHz 对应 48kHz；12.5MHz 对应 48828.125Hz，两种配置的生产/播放速率都来自同一个源，不会平均漂移。`SR_HZ` 不生成音频模式的节拍，也不会把 12.5MHz 变成精确 48kHz。真实音频参考应与系数生成采样率一致；当前旧板 PLL 的 12.5MHz 不能算作精确 48kHz 的实板验证。

core/audio 两个时钟需持续运行，core 必须能观察到每一帧 toggle；本实现没有暂停 core 时钟后的补发协议。`rst_n` 共享异步置位；音频发送器及 FIFO 各域同步释放，顶层 core 复位释放应遵守系统时钟复位合同。同步器已标记 `ASYNC_REG`，整机仍需核对实际约束及 Gray 总线的跨域物理时序。

## PCM 与诊断

当前 router 输出按 `modal_step_pkg::YF=24` 解释。旁路 PCM16 转换为带正偏置舍入的 `y >>> (9 + PCM_HEADROOM_BITS)`，随后饱和到 [-32768,32767]。双声道路径保留额外 18 位小数，最终相应右移 `27 + PCM_HEADROOM_BITS` 后舍入/饱和；空间处理中间不提前转换成 PCM16。默认 `PCM_HEADROOM_BITS=3`，即单位增益换算后保留 3 bit 混音余量；设 0 为单位增益。实现使用高位符号扩展检查和16bit舍入增量，等价于原65bit扩展后加偏置/移位/限幅，避免极大输入加舍入量时回绕；624324组向量已逐位对拍。没有自动峰值归一化，也没有实现菜单音量消费者。

2026-10-31板级覆盖：`instrument_board_top/instrument_system` 默认传入 `PCM_HEADROOM_BITS=1`，使两种DAC输出的未限幅PCM振幅相对原板级设置提高4倍（约+12dB）；通用音频模块默认3仍保留。`tb_pcm_equivalence`补充headroom=1及空间PCM路径检查，仍保留饱和限幅；没有引入自动压缩，用户确认当前音量实测通过，作为后续基准；强和弦/大力度的削波率尚未量化。

三个诊断为 core 域 sticky，复位清除：

- `audio_deadline_miss`：正常运行且已过恢复准备时间（最多两个帧边界，覆盖进入等待节拍及首样本计算），上一采样计算仍未交付；该 token 写零。
- `audio_overflow`：FIFO 写入时无空间，或同一采样窗口出现多个结果。这里报告丢样，不宣称发生此故障后仍无损。
- `audio_underflow`：音频域曾收到 token 后，在播放帧边界 FIFO 为空；发送零帧并同步标志。

按本次决定，暂不做 panic 的音频队列 flush/确认。现有维护仍清引擎并停止接收新的有效 PCM，但已排队或正在发送的旧样本会播放完；软件不能把引擎清理完成解释为 DAC 已原子清空。没有增加满 FIFO 重试队列；正常一帧进、一帧出由单一时间基准保证，故障由诊断暴露。

## 测试

新空间处理及线端矩阵执行 `python3 sim/run_stereo.py`；完整合成音频矩阵执行 `python3 sim/run_audio.py`（含四项动态双声道真实合成用例）；可用 `--test eng1 --test bridge`只选模块用例。真实B类音色另用sim/run_sustain.py验证。命令在仓库根目录执行（Questa，沿用 `QSIM_INI` 或 `~/gowin/simlib_questa/modelsim.ini`）。整数向量由固定种子的 Python 标准库生成，输出/日志写入 `build/i2s_pipeline/audio`；`--out` 更换目录，`--test eng1/bridge/integration` 可重复选择。独立串行解码器只观察 BCLK/WS/DIN。

eng1 的五级流水为同步读、三个并行乘法、加减、舍入饱和、写回/累加，每拍一个模态。状态/地址/valid 同步前进，最后一次写回提交后才出 `y_valid`。接口和逐模态算术保持不变，修复 `n_modes=0` 误读写第一个模态。资源深度仍为 64：钢琴实际 64、吉他 20、eng1 首版 48；这不代表其余乐器的真实系数资源已验收。

本轮验证的是 RTL 功能、帧/样本一致性及所测规模的运算周期余量；不替代整机 PnR、板上时钟/引脚、真片 Flash、放大器容差及听感验收。当前统一板级已接 I2S、真实菜单和 FFT/LCD 音频采样，2026-10-31 整板物理时序及 SRAM 下载通过，用户确认当前版本实测通过。接线与验收见[板级说明](../platform/tang_mega_138k_pro/README.md)。

## 板载PT8211（2026-10-30）

`i2s_audio_output.PT8211_ENABLE=1`增加Japanese/LSBJ输出dac_bck/dac_ws/dac_din；默认0保留已有外部I2S接口，统一板级固定开启。midi_voice_top透传参数和数字输出；PAD与MIDI在统一入口内共用此输出。pt8211_tx复用同一个FIFO读数据，与主I2S的ready和frame_tick逐拍一致，数据保持左右成对。输出时隙为右16bit（WS=0）、左16bit（WS=1），每帧32×8=256 audio clocks，与I2S的64×4相同。不会让FIFO每帧被弹出两次。

协议依据：[PT8211 V1.7官方数据手册](https://www.princeton.com.tw/Portals/0/activeforums_Attach/PT8211%20V1.7_E.pdf?ver=I8v0SNPIQri_LxlOI2sp7w%3D%3D)第4页；引脚依据仓库Dock Rev1.2原理图第18页。独立接收器检查数据、左右极性、每槽16位、20480ns帧周期及复位后的重同步。
