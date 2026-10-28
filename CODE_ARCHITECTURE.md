# 代码架构与阅读路线

更新：2026-10-27。按 `8e9d1cda` 及当前工作区的实例、参数和源清单核对。本文说明代码关系；问题与证据分别维护在 [bugs](docs/bugs.md) 和 [验证记录](docs/工程评审与验证.md#verification)。旧歌曲工程导读已归档到 [历史文档](history/docs/legacy/CODE_ARCHITECTURE_2026-10-06.md)。

## 1. 当前顶层与边界

仓库目前没有同时接通压力/MIDI、音频 DAC 和 LCD 的统一板级顶层。

| 路径 | 顶层/入口 | 输出与限制 |
|---|---|---|
| 当前合成 | `rtl/router/pad_voice_top.sv` → `voice_router.sv` | 64-bit `y_data/y_valid`，没有 I2S；fmap 可来自压力垫或外部输入 |
| 独立显示 | `FFT_spectrumshow/board/ui_demo_top.v` | LCD RGB/DE，默认中文侧栏，使用三音/扫频源 |
| 独立通信 | `rtl/comm/comm_top.sv` | 带来源的 MIDI 事件、配置请求/结果；尚无真实演奏消费者 |
| 配置与交互 | `FFT_spectrumshow/src/ui/sidebar_system.sv` | 摇杆/按键→配置提交→显示帧头或后端；demo 后端能力全 0 |
| 保留 core | `rtl/core/router_system_top.sv` | 另一套共享 RAM ABC/E2，不是当前 router 的子模块 |
| 历史出声 | `history/rtl/audio/` 及 `history/rtl/platform/` | 旧 FIFO/I2S/歌曲/诊断工程，只用于追溯 |

## 2. 当前合成链

```text
pad_voice_top
├─ pad_driver（可由 USE_PAD_DRIVER 关闭）
│  ├─ sense4x4_joystick → Gowin_ADC
│  ├─ cart2polar（兼容旧 pos）
│  └─ led8x8（本适配器 led_p 固定为 0）
├─ src_sel 寄存 → 选择 pad fmap 或 fmap_ext
└─ voice_router
   ├─ fmap_q / 滞回门控 / 采样节拍 / note、dead 事件暂存
   ├─ weight_loader → 系数和调制参数 RAM
   ├─ exc_router → excitation_gen → x_q[SLOTS]
   ├─ env_router → ADSR / dyn0 / 常数包络
   ├─ mod_router → modulation0（后台请求位图）
   ├─ eng_router A → eng0 或 eng1，访问 bank A
   ├─ eng_router B → 相同选核，访问 bank B
   └─ 逐声部包络乘法 → 跨声部累加 → body_router → reverb_router
```

`voice_router` 默认 `SLOTS=16, N_MODES=64, CLK_HZ=100MHz, SR_HZ=48kHz`；合法声部数是 4/8/16。每次 start 完成**一个样本**，固定处理全部槽。`done=1` 表示空闲可启动；`ready` 表示挂起的 inst/reload 变更可执行；两者均不是“指定音色已加载成功”的事务确认。`pad_voice_top.run` 接 start，`busy=~done`；其 `N_MODES` 默认 48，`X_DEPTH` 是残留兼容参数，不再传入 router。

钢琴/吉他选 eng0，其余枚举暂选 eng1。`n_modes_of()` 对钢琴返回 64、吉他 20，其余 64，router 再限幅到 `N_MODES`。10 个乐器编号是目录，不代表 10 套资源已实测。

### 存储与 Flash

RAM 步长 `NMP=1<<clog2(N_MODES)`，地址 `{slot,mode}`；loader 写地址最高位选择系数/参数表。引擎用到的系数和状态按前后半声部分为 A/B 两个 bank，每个 bank 同步读写；调制参数独立存储。

Flash 紧凑布局为 `inst*(SLOTS*N_MODES*64)`，逐 slot、逐模态存 64-byte 大端记录；RAM padding 不进入 Flash。`tools/piano_flash.py` 默认选 MIDI `40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76`，不是连续 32 音。使用镜像时必须统一声部数、物理模态深度和乐器基址。

### 运算与时间

eng0 是七系数状态空间递推，eng1 是 `G*x-(a1<<4)*y1-a2*y2` 的 ABC 核；字段 Q 格式不同，见 [router 契约](rtl/router/README.md)。包络 Q1.31，腔体/混响增益 Q4.27，输出为 signed64；没有统一的“截高 16 位即可接 DAC”契约。

两个 `eng_router` 同时处理 A/B 对应声部，随后复用包络乘法与混音。后台调制按起音请求修改系数，尚不是持音持续压力跟随；逐模态更新也不能推导整张表在帧边界原子切换。装载期间没有 y_valid。router 的整数分频采样节拍与 DAC/LCD 时钟尚未统一。

## 3. 配置、交互与显示

```text
joy_sample_valid + raw X/Y → joystick_adapter ─┐
旧双按键事件 ────────────────────────────────────┤
                                               ▼
sidebar_ctrl（菜单/草稿/请求） → control_loop（1kHz 轮询、一项暂存）
外部已适配请求（槽1） ──────────┘
    → config_dispatch
       ├─ 显示目标 → sidebar_mailbox → 像素帧头应用 → 结果
       ├─ 摇杆重校准 → 等 calibrated 恢复 → 结果
       └─ backend 请求 → 等匹配 tag/id 的真实结果
    → 结果回到原来源
```

统一请求 64 bit `{tag,id,value}`，结果 72 bit `{tag,id,result,applied_value}`。`control_loop` 不解释参数，也不确认业务生效；配置端按能力位开放项，失败保持原实际值。`comm_top` 的 cfg shadow 和侧栏请求不是同一协议，仍需保留物理来源/SEQ/命令的适配。

LCD demo 控制域使用板载 50MHz，像素域约 33.333MHz。菜单快照整包跨域，目的端帧头提交；两个域复位需遵守 mailbox 合同。`lcd_sidebar` 的同步字模使 RGB/DE 延迟一拍，板顶层外层寄存必须保持对齐。`HAS_JOYSTICK=0` 的独立 demo 使用双按键，只启用显示参数。

音频可视化 `real_audio_chain` 在 demo 中 core/pix 都接像素时钟；它的双时钟端口不证明跨域安全。主合成器仍须经过 PCM 适配和异步 FIFO 后再接入。侧栏的 CDC 仅覆盖配置快照。

## 4. 通信与演奏适配

```text
uart_driver / hc05_driver → 各路 transport_link（SLIP/CRC）
    → frame_arbiter → parser_dispatch
       ├─ midi_analyzer → Event32 + source_id → 共享事件 FIFO
       └─ config_analyzer → 原子 cfg 请求 / 最终回复
session_ctrl → 来源隔离、清理、退休和重建
```

线上 v1 规范只维护在 [PROTOCOL_V1](rtl/drivers/analyzer/PROTOCOL_V1.md)。UART/HC-05 驱动与帧层不承担音符生命周期。下游尚须实现通道过滤、Note On/Off、踏板、音符到槽/系数、CC7/11、清音和操作退休；不得将 `source_cleanup_done/source_ops_idle` 未经处理绑 1。

## 5. 离线模型与参数生成

- `python/instruments.py`、`fft_analysis/`：样本目录、基频/分音/衰减、持续音与打击乐参数。
- `python/modal_sim/engine.py`、`fixed_point.py`、`gen_hw_rom.py`：旧模态参考及旧 ROM 格式。
- `python/modal_sim/router_eng1.py`、`eng1_bc.py`：router 级 eng1 整数参考与 A/B/C 试听；不等同于当前钢琴/吉他 eng0 路由。
- `sythsound/piano_coeff_gen.py` → `sythsound/piano_coeff.txt` → `rtl/router/tools/piano_flash.py`：当前钢琴七系数 Flash 打包链。生成器与打包器的状态定标须一起核对，不能将旧数学推导当作所有中间表都未归一化的承诺。
- `.npz`、旧 `.mem` ROM、router Flash 64-byte 记录有不同合同，不能按扩展名互换。

## 6. 推荐阅读与验证

先读 `rtl/router/pkg/router_pkg.sv` 和 `modal_step_pkg.sv`，再沿 `pad_voice_top`→`voice_router`→`routers/*`→`parts/*`/`engines/*` 跟踪时钟、接收条件、状态与完成条件。配置从 `config_pkg`→`control_loop`→`config_dispatch`→`sidebar_system` 阅读，通信从 `comm_sources.f` 和 comm README 阅读。

运行入口见 [sim/README](sim/README.md)。本轮确认通信/控制/摇杆/侧栏回归通过；eng1 intended 对拍 3 个零模态作业失败，旧 core 编译中断。音乐测试绕过真实 loader，旧探针报告、模型音频和独立 LCD 均不能代替当前输入→DAC 的完整验证。
