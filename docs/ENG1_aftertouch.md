# ENG1 aftertouch

`voice_router → mod_router → modulation1` 负责持续音色的逐声部 PAD 压力调音。
当前启用范围沿用 `is_sustain()`：长笛、小号、大提琴、小提琴。

- 零点沿用 `PAD_NOTE_ON_TH`，当前默认 102。
- 音偏：`max(0, pressure - PAD_NOTE_ON_TH) × 0.6` 音分。
- 默认力度 102 / 152 / 202 / 255 对应 0 / 30 / 60 / 91.8 音分。
- 内部音分为 Q8，四舍五入；255 对应 91.80078125 音分。
- 按住时随压力升降，最低为 0；松键尾音保持最后提交的音偏。
- 新起音按当前绝对压力计算。默认每 96 个音频采样调度一次，48 kHz 下为 2 ms；无额外 slew 或 LFO。
- 一次作业锁存所有声部压力与门控；作业期间的新压力留待后续更新。
- P1T1 基值不变；由音分换算 Q24 频率比，再计算并限幅 `a1_base + K × delta`。
- 系数写入非活动 bank，仅在帧边界许可时提交；激励器的频率比同时提交。
- MIDI velocity 不作为持续压力；原 wheel/bend 请求明确返回 rejected，不产生音偏。
- PAD/MIDI 模式切换和声部归属变化通过提交屏障处理；清理中断半成品作业。

Flash P1T1 与 ratio 表格式不变。旧 sine/depth 表仍占据镜像原位置，但本模块不再存储或使用这些表。
本次不扩大音色范围，也不改变 ENG0 的 modulation0 映射。

验证：

```sh
python sim/run_aftertouch.py
python sim/run_aftertouch.py --model-python /path/to/python-with-numpy
```

第一条为无 vendor IP 的 Icarus 回归：全 256 个力度值、多声部隔离、正负斜率、上下界限幅、松键保持、压力锁存、原子提交、格式错误、清理、模式切换与零模态。
第二条追加 40000 个时钟的 Python/RTL 对比，使用已部署 trumpet 的 P1T1 记录。
完整 Flash/router/MIDI 仿真用例已同步；本机缺少 Questa 配置且没有 Verilator，未执行完整系统回归或综合布线。
