# pad_driver → voice_router 适配

更新：2026-10-28（补加载失败保护、默认64模态和状态透出）。描述当前 [pad_voice_top.sv](pad_voice_top.sv)，源码基线 `d7045c4b` 后的新接口。模块连接压力与合成值，输出尚未到 DAC。

## 数据流

```text
clk → PAD_DIV 使能（默认 /40）→ pad_driver → 4×4 fmap ─┐
fmap_ext ────────────────────────────────────────────┤
                     src_sel 寄存选择 ────────────────┘
                        ↓
                  voice_router → y_valid/y_data
                        ↕
                     QSPI Flash
pad_driver → joy_sample_valid / joy_raw_x / joy_raw_y → 外部 sidebar_system
```

16 个压力单元直接对应 16 个 slot；门控/起音、激励、包络、合成、混音和效果由 voice_router 持有。本适配器不解释MIDI；真实MIDI已由midi_voice_top连接状态/激励/引擎，不能把解析字节直接当fmap。当前门控起音要求fmap>230、保持到fmap<26才释放；旧>2/<1说明已过期。MIDI原始velocity仅0..127，直接复制无法起音；适配策略见 [MIDI接入](../../docs/MIDI演奏与通信接入.md#midi-consumer)。

## 参数与接口

| 项目 | 当前值/语义 |
|---|---|
| CLK_HZ / SR_HZ | 100MHz / 48kHz；router 内部产生采样节拍 |
| SLOTS | 默认 16，router 支持 4/8/16 |
| N_MODES | 本适配器默认 **64**，与voice_router及钢琴工具默认一致；正式镜像深度仍必须匹配 |
| USE_PAD_DRIVER | 1 综合真实压力/摇杆驱动；0 时只使用 fmap_ext，采集/LED/摇杆出口为零 |
| src_sel | 0 选择压力，1 选择外部 fmap；先寄存一拍；切换不会自动清音/清队列 |
| run | 高电平持续请求新采样，接 router.start；不是独立音频采样时钟 |
| done / busy | done 是空闲电平，busy=~done；run 拉低不取消正在计算的样本 |
| ready | 挂起乐器/reload 变更能执行；不是通用 start ready 或 cfg_applied |
| inst / reverb_preset / reload | 乐器编号、router 原生混响枚举、reload 上升沿请求 |
| load_err / table_valid | 加载错误与当前表有效性；done/ready不代替成功确认 |
| y_valid / y_data | 每个结果一个 valid，signed64；无输出 ready，尚需 PCM/FIFO/I2S |
| qspi_* | 转接 loader；需要真片协议/引脚验收 |
| pad_row_s / pad_ch_s / pad_fmap / pad_pos | 原始调试出口；旧 pad_pos 为极坐标 |
| joy_sample_valid / joy_raw_x/y | 同 clk 域，一拍 valid、14 bit 原始 X/Y 成对快照；接 [摇杆适配](../drivers/JOYSTICK_ADAPTER.md) |

旧 `n_voices/n_modes/n_samples` 运行端口已移除，声部数是参数，实际模态数由 `n_modes_of(inst)` 选择并限幅。旧文档中的固定 5/6/7 bit 强转问题已不再适用。

## 采集与启动

压力/摇杆扫描包含泄放、建立、请求、等待完成和存储，完成信号经同步/上升沿 sticky 后消费，超时重试；不能继续用旧“列 3 时连续换行”的逻辑描述当前实现。一个扫描帧含 16 个压力通道及两个摇杆通道，实际周期取决于 ADC 完成与参数。

PAD_DIV=`CLK_HZ/2_500_000`，计数器目前 8 bit；非默认频率必须核对除法余数、计数范围和模拟前端时序。默认只证明 100MHz 参数意图，不保证任意 CLK_HZ。

上电首次装载及换音色期间不产生 y_valid；reload 在 router 内部取上升沿，有变更且仍按键时延后加载。`pad_voice_top`现已引出load_err/table_valid。坏表后不出声、不自动无限重试同一目标；显式reload或另一音色才重新装载。UI/MIDI联合事务使用midi_voice_top的CONFIG_BACKEND模式，不能只凭PAD的done判断成功。主控应将目标 inst 保持稳定直到事务收束。

## 验证与待接部分

`python3 sim/run_joystick.py` 本轮 26 组通过，其中两组使用真实采集 FSM/坐标转换和 ADC 行为模型，检查 X/Y 成对出口、dummy、超时重试。没有例化整套 pad_voice_top、真实 ADC 或 LED，不证明 16 键位置/独立发声。

待接：统一镜像深度/音高表、上板逐键校准、真实 Flash、至少四路可闻复音、PCM 饱和/缓冲/I2S/DAC、源切换清理和真实 UI 配置后端。问题与关闭条件见 [bugs](../../docs/bugs.md)，侧栏入口见 [实施与接线](../../docs/控制与侧栏设计.md#integration)。
