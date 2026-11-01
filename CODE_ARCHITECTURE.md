# 代码架构与阅读路线

更新：2026-11-01。已合入main@f7958d1b；本文维护实例与接口，当前参数/Flash合同见[音频设计](docs/音频设计.md)，源码与板上版本的验证状态见[调试记录](docs/调试记录.md)。

## 1. 当前入口与边界

| 路径 | 入口 | 当前边界 |
|---|---|---|
| 统一板级入口 | `rtl/platform/tang_mega_138k_pro/instrument_board_top.sv` | 单PLL三时钟域/复位、双UART、PAD/LED、真实UI后端、QSPI和I2S；真实PCM经独立FIFO接FFT/波形/极坐标显示 |
| 压力/外部fmap | `rtl/router/pad_voice_top.sv` | pad_driver、QSPI、摇杆原始出口、signed64合成值；默认64模态 |
| MIDI及联合配置 | `rtl/router/midi_voice_top.sv` | 音符/来源/引导状态、两组16音、清理/装载/实际结果、signed64输出 |
| 音频模块 | `rtl/audio/i2s_audio_output.sv` | PCM/FIFO/I2S及帧节拍CDC；两个演奏顶层及统一板级入口均已实例化，统一以I2S帧推进合成 |
| 通信 | `rtl/comm/comm_top.sv` | Event32+source、Config shadow及会话接口；演奏消费者已有，统一板级接线已有，REVERB_SET映射真实后端；EQ明确NOT_READY |
| 显示/配置 | `FFT_spectrumshow/src/ui/sidebar_system.sv` | loop/dispatch、真实后端握手、配置/引导独立显示CDC；独立demo后端能力仍为0 |
| 本地主机 | `web/midi-editor/` | 编辑/参考试听/Web Serial；无板端PCM回传或远程音色设置 |
| 归档core | `history/core_2026-11-01/rtl/core/router_system_top.sv` | 另一套共享RAM ABC/E2实现，与当前router无父子关系 |

统一板级只有一套voice_router，内部保留eng0/eng1选择。六音色固件3ED7已烧录；main新增录制/fmap/混响修改后的源码尚未编译。core50MHz、audio12.5MHz、pixel约33.333MHz，实际Fs=48.828125kHz。

## 2. 演奏与合成

```text
comm_top事件+source → midi_voice_top
                     ├─ midi_note_state / midi_instrument_map
                     ├─ 清理 → 锁存目标 → loader → 排空 → active/结果
                     └─ gate/velocity/retrigger/hard_clear ──┐
pad_voice_top → pad_driver或fmap_ext → 压力滞回门控 ────────┤
                                                         ▼
voice_router → performance_input_mux
             ├─ exc_router → excitation_gen → x_q[slot]
             ├─ env_router → ADSR/dyn0/常数 → emap
             ├─ weight_loader → 系数/调制参数RAM
             ├─ mod_router → modulation0 → 系数写口
             ├─ eng_router A ↔ bank A（前半声部）
             ├─ eng_router B ↔ bank B（后半声部）
             └─ 锁存A/B结果 → 逐槽包络乘法/混音 → 五段腔体 → 四梳状混响
                                                             → y_valid/y_data
```

voice_router默认16槽、64模态存储、100MHz/48kHz参数，合法槽数4/8/16。每次作业产生一个样本并处理全部槽；两个bank按声部拆分，不是新旧系数双缓冲。钢琴/吉他选eng0，分别计算64/20模态；其余选eng1，首版计算48并限幅到存储深度。

模块默认压力起音为fmap>230，保持到fmap<26；统一板级入口按ADCV实测量程将正原始字节乘4并饱和、负值置零，配置门限64/48（对应原始16/12）。MIDI使用独立gate/retrigger与7bit velocity，避免受压力门限阻挡。持续压力变化也会登记吉他后台调制，MIDI velocity不进入压力调音。调制采用一阶近似、MOD_TOP=4、lambda最大0.035；逐模态更新仍未保证整帧表版本原子一致。

eng1已改五级跨模态流水，空作业返回零且不读写状态。四种持续音色已接逐槽周期冲激和ADSR；配置与系数加载一起提交，释放后清零退休才报告idle。资源生成与实施合同统一在[eng1演奏前端设计](docs/ENG1前端.md)。

串口／蓝牙引导模式由0503联合配置：mode_q仍标记外部来源，guide_q使实际合成选择synth_midi=0。事件经原FIFO握手分流到midi_guide_state，实际压力输入继续驱动同一voice_router；提示不产生MIDI gate/retrigger。guide_display_t包含音高表、目标、80ms余辉和实际压力门控，独立mailbox在像素帧头整体提交到lcd_pad_guide，侧栏保持更高覆盖优先级。具体状态／切换／清理合同见[MIDI引导](docs/MIDI接入.md#midi-guide)。

### 运行与加载

`done` 是空闲电平；`ready` 是挂起音色/reload是否可执行，均不等于配置成功。reload取上升沿，持键时普通换色延后，旧表仍使用旧音色/模态数。loader失败撤销table_valid、静音并等待显式重试；pad_voice_top引出load_err/table_valid。midi_voice_top用load_complete、维护退休与状态机完成配置事务，再回写匹配tag/id的结果和实际快照。

当前panic在C_RUN等可接收状态发起配置清理；先前忙时抢占装载的panic_pending/旁路已不在当前源码，不能继续承诺装载中立即取消。菜单清音事务、来源清理和音频FIFO撤销是不同完成条件；音频队列flush仍暂缓。

### 存储、资源与定标

RAM按NMP=next_power_of_two(N_MODES)补齐槽步长，地址含sel/slot/mode。Flash记录64B大端：前半7系数+保留字，后半4基值+4斜率；逐槽偏移、update_mask及目标在事务接收时锁存。默认16音每乐器64KiB，32音资源每乐器128KiB，基址必须随FLASH_NOTES统一；不能把两种区域步长混烧。

钢琴/吉他生成器都输出scaled表，打包器直接按当前Q量化；默认16音清单为40/42/44/46/48/50/52/54/56/58/60/62/64/67/71/76。吉他每槽补零到64条，实际计算前20。钢琴工具可显式生成连续32音并输出manifest，正式六种音色/32音范围尚未冻结。详细格式只在[router系数合同](rtl/router/README.md#coefficient-pipeline)维护。

eng0状态、激励和输出统一Q24；a11/a12/a21/a22小数位28/30/23/28，gq/gv/wo为32/34/29。eng1的G/a1/a2为独立合同；当前生产Python模型使用Q24；旧Q30参考及SHIFT22只属于历史路径。

## 3. 配置、交互与通信

```text
摇杆原始X/Y / 双按键 → sidebar_ctrl ─┐
已转换的外部统一请求（槽1） ──────────┤
                                   ▼
control_loop（1kHz） → config_dispatch
                     ├─ 显示 → mailbox → 像素帧头应用 → 结果
                     ├─ 校准 → calibrated恢复 → 结果
                     └─ midi_voice_top(CONFIG_BACKEND=1) → 真实提交/实际快照
```

请求64bit `{tag,id,value}`，结果72bit `{tag,id,result,applied_value}`。loop只轮询/暂存配置，不调度音符或音频样本。联合后端已有音色/通道、来源、音组、混响和清音事务；RESOURCE_MASK默认开放六音色0xC2B，菜单音量/调制开关深度/EQ等消费者仍未完成；ENG1 Bend/CC1已接入。独立LCD demo只开显示能力；统一板级启用真实后端，并在外围持有远程权限策略。

comm按UART/HC-05→transport→arbiter/parser→事件或配置分层，33bit事件FIFO保留source侧带。session_ctrl的清理/退休必须接真实演奏消费者。Config shadow含物理来源/SEQ/命令，不能截成统一64bit请求；整版适配端保留这些字段到退休，远程权限由本地0502后端持有；REVERB_SET等待真实结果，EQ无消费者时返回NOT_READY。唯一线上合同为[PROTOCOL_V1](rtl/drivers/analyzer/PROTOCOL_V1.md)，演奏归属与配置事务只在[MIDI文档](docs/MIDI接入.md)维护。

## 4. 输出与显示的接入责任

已有i2s_audio_output实现Q24→PCM16、独立FIFO和连续I2S，帧toggle同步到core后可作为统一sample_tick。当前顶层同时让激励、包络和引擎使用外部帧节拍；不能另外给start接独立采样分频。采样率、PCM余量、诊断和复位合同见[音频说明](rtl/audio/README.md)。接口缺失的历史问题已修复；系统回归及整版构建结果以日期化验证为准。

统一板级已接真实PCM抽头/独立FIFO、像素域FFT及极坐标历史显示；独立demo继续保留三音/扫频。可视化取得独立PCM副本，不能和I2S共同pop同一个队列，也不能反压播放。real_audio_chain需要24bit输入，当前demo的core/pix都接像素域；内部写侧仍用clk_pix，wr_ready未向上暴露。正式接入须冻结PCM扩展/抽头位置、入口CDC、连续1024点窗口与丢窗口诊断，不能只改一个clk端口就认为安全。

独立demo的sidebar控制域50MHz，统一板级控制域50MHz，两者像素约33.333MHz；整包快照在帧头提交。菜单布局、字模及最终输出使RGB/DE统一延迟4个像素时钟，外围必须保持对齐。配置mailbox不承担音频CDC。显示应读取完整发布帧，不能直接把引擎缓存状态口当任意地址RAM读口。

## 5. 阅读与验证

先读router_pkg/modal_step_pkg，再沿演奏顶层→voice_router→routers→parts/engines读状态和握手；配置从config_pkg/dispatch/loop/sidebar_system读，通信从comm_sources.f与comm README读。离线模型和资源格式不能互换：NPZ、旧core ROM、Flash记录分别有合同。

[sim说明](sim/README.md)维护命令，[工程评审与验证](docs/工程验证.md)维护日期化证据，[验收总表](docs/赛题验收.md)维护赛题闭环。模块PASS、模型WAV、Flash行为模型、历史PnR均不能单独证明输入→DAC→LCD整机通过。

2026-10-30选择性迁移origin/board50@6183395d，保留本地双声道/PT8211/MIDI引导及用户确认的新版U5引脚；范围和验证见[迁移记录](docs/工程验证.md#board50-migration-2026-10-30)。
