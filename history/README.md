# history — 旧 demo / 旧引擎快照

本目录是 `f6eb854`（只保留新四引擎架构）之前被删除的旧路径快照，来源提交：

```text
605023d  perf(core): pipeline ENG1 mix/env and split 9x32 RAM
```

用途：查看旧 demo、旧 board top、旧 `modal_engine`/`poly_modal_lane` 实现和旧测试，不再参与当前构建。

当前入口见 [仓库 README](../README.md) 和 [文档索引](../docs/README.md)。本目录内的“当前/正式/最新”均按各记录日期理解。

保留共享 RAM 代码在：

```text
rtl/core/
sim/unit/core/
```

注意：`history/` 里的路径保持原仓库相对路径，方便对照；不要把它加回当前 RTL 构建。

## FFT_results/sim 旧合成产物（2026-10-25）

`FFT_results/sim/` 下旧的 A/B/C 合成输出（pitched / sustained / drums / song /
roll_compare / crosscheck / vibrato_coeff，连同旧 README 和 report.json）整体移到：

```text
history/FFT_results/sim_pre_eng1_2026-10/
```

当前只保留新的 `FFT_results/sim/eng1/`（router 级 eng1 整数模型音频）。
旧生成脚本仍在 `python/modal_sim/`，没有删除。

旧算法规格 audio_bringup/body/module2A/module2BC 已归入 `history/docs/design/`，旧歌曲架构导读在 `history/docs/legacy/CODE_ARCHITECTURE_2026-10-06.md`。它们不用于签核当前 voice_router。
