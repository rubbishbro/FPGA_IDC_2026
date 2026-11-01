# RTL 入口与路径边界

更新：2026-10-29。当前开发主线为 [router](router/README.md)，旧 `core/` 共享 RAM 实现已归档至 `history/core_2026-11-01/`，二者不是同一个顶层。

| 位置 | 职责与状态 |
|---|---|
| [router/](router/README.md) | voice_router：双 bank、多槽音高表、eng0/eng1、激励/包络/腔体/混响；默认 16×64，输出 signed64，待完整音频集成 |
| [router/PAD_ADAPTER.md](router/PAD_ADAPTER.md) | pad_voice_top：压力/外部 fmap 选择、运行启动、QSPI 与摇杆原始出口；默认N_MODES=64，透出load_err/table_valid |
| [audio/](audio/README.md) | 移位加法 ILD/辅助 ITD、双声道 PCM16/FIFO/I2S与帧主时基，两个演奏顶层及统一板级均已接入 |
| [platform/tang_mega_138k_pro/](platform/tang_mega_138k_pro/README.md) | 统一板级入口、单PLL三时钟域/复位、通信/PAD/UI/I2S、CST/SDC与时序验收；FFT PCM待第二阶段 |
| `midi/`、`router/midi_voice_top.sv` | 音符归属/踏板/来源清理、两组16音、UI联合配置与实际结果 |
| [drivers/](drivers/README.md) | 压力/摇杆/LED、UART/HC-05、共享 FIFO 与 MIDI/Config parser |
| [comm/](comm/README.md) | 双链路分帧、仲裁、回复、来源会话隔离/恢复 |
| [config_pkg.sv](config_pkg.sv) | 统一配置 ID/范围、64 bit 请求和 72 bit 结果 |
| [config_dispatch.sv](config_dispatch.sv) | 能力检查、显示/校准/真实 backend 提交与结果 |
| [control_loop.sv](control_loop.sv) | 通用轮询、一项暂存、原样交付；已在 sidebar_system 使用 |
| [math/](math/README.md) | 定点与坐标变换公共模块 |
| `rom/` | 保留路径的 ROM/索引数据，不能直接作为新 router Flash 镜像 |

当前代码导读见 [CODE_ARCHITECTURE](../CODE_ARCHITECTURE.md)，显示/侧栏集成位于 `FFT_spectrumshow/`，不在此目录生成另一个总顶层。历史FIFO/I2S原件保留在history/rtl/audio，当前复用模块在audio/；顶层接线已恢复；整板PnR时序未达标，实板DAC仍待验。

## 已归档共享 RAM 路径

旧 ABC/E2 共享 RAM 实现及其测试、综合探针已移至 [CORE 归档](../history/core_2026-11-01/README.md)。它与当前 voice_router 无父子关系，不能用于当前功能或时序签核。归档保留原始文件和已知编译阻塞说明。
