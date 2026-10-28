# RTL 入口与路径边界

更新：2026-10-29。当前开发主线为 [router](router/README.md)，保留的 `core/` 共享 RAM 实现独立存在，二者不是同一个顶层。

| 位置 | 职责与状态 |
|---|---|
| [router/](router/README.md) | voice_router：双 bank、多槽音高表、eng0/eng1、激励/包络/腔体/混响；默认 16×64，输出 signed64，待完整音频集成 |
| [router/PAD_ADAPTER.md](router/PAD_ADAPTER.md) | pad_voice_top：压力/外部 fmap 选择、运行启动、QSPI 与摇杆原始出口；默认N_MODES=64，透出load_err/table_valid |
| [audio/](audio/README.md) | PCM16/FIFO/I2S与帧主时基模块已有；当前演奏顶层缺音频实例/端口 |
| `midi/`、`router/midi_voice_top.sv` | 音符归属/踏板/来源清理、两组16音、UI联合配置与实际结果 |
| [drivers/](drivers/README.md) | 压力/摇杆/LED、UART/HC-05、共享 FIFO 与 MIDI/Config parser |
| [comm/](comm/README.md) | 双链路分帧、仲裁、回复、来源会话隔离/恢复 |
| [config_pkg.sv](config_pkg.sv) | 统一配置 ID/范围、64 bit 请求和 72 bit 结果 |
| [config_dispatch.sv](config_dispatch.sv) | 能力检查、显示/校准/真实 backend 提交与结果 |
| [control_loop.sv](control_loop.sv) | 通用轮询、一项暂存、原样交付；已在 sidebar_system 使用 |
| [math/](math/README.md) | 定点与坐标变换公共模块 |
| `rom/` | 保留路径的 ROM/索引数据，不能直接作为新 router Flash 镜像 |

当前代码导读见 [CODE_ARCHITECTURE](../CODE_ARCHITECTURE.md)，显示/侧栏集成位于 `FFT_spectrumshow/`，不在此目录生成另一个总顶层。历史FIFO/I2S原件保留在history/rtl/audio，当前复用模块在audio/；顶层接线及实板DAC仍待收口。

## 保留共享 RAM 路径

```text
router_system_top
├─ router_loader → index_loader20 / index_loader64
├─ router_frontend → router_ctrl / excitation_convert
└─ shared_engines_system_top
   ├─ router_voice_alloc
   └─ shared_engines_top
      ├─ engine_mux → pure_engine_abc / e2_engine
      ├─ shared_modal_ram
      └─ post_chain → envelope_mul / body_biquad / comb_reverb
                     / dry_wet_mix / final_adder
```

`router_frontend_a_path_top` 是 A 路径 MVP。core 的 body_biquad 是 4 section，与新 router 的 5 section 接口/格式不同。2026-10-22 的 POST_EN=1、21 项 PASS 和探针时序均是该旧路径的历史结果。

当前 `sim/run_core.sh` 前两项通过，第 3 项缺少 `rtl/simsynth/modal_step_pkg.sv`；`e2_engine` 仍引用旧 modal_engine7。这个保留路径尚不能一键完整回归，也不能借它的历史 Fmax 签核当前 voice_router。

2026-10-22 重命名：class_loader/class_loader64→index_loader20/index_loader64，eng1_lane_core→abc_lane_core，eng1_engine_top_ext→abc_engine，eng2_engine_top_ext→e2_engine；旧 loader/frontends/parallel 路径在 `history/rtl/core/`。完整历史稿和图见 [history](../history/README.md)。
