# history — 旧 demo / 旧引擎快照

本目录是 `f6eb854`（只保留新四引擎架构）之前被删除的旧路径快照，来源提交：

```text
605023d  perf(core): pipeline ENG1 mix/env and split 9x32 RAM
```

用途：查看旧 demo、旧 board top、旧 `modal_engine`/`poly_modal_lane` 实现和旧测试，不再参与当前构建。

当前新架构在：

```text
rtl/core/
rtl/simsynth/modal_engine7.sv
rtl/simsynth/modal_step_pkg.sv
sim/unit/core/
```

注意：`history/` 里的路径保持原仓库相对路径，方便对照；不要把它加回当前 RTL 构建。

## FFT_results/sim 旧合成产物（2026-10-25）

`FFT_results/sim/` 下旧的 A/B/C 合成输出（pitched / sustained / drums / song /
roll_compare / crosscheck / vibrato_coeff，连同旧 README 和 report.json）整体移到：

```text
history/FFT_results/sim_pre_eng1_2026-10/
```

当前只保留新的 `FFT_results/sim/eng1/`（router 级 eng1 整数模型的两段 WAV）。
旧生成脚本仍在 `python/modal_sim/`，没有删除。
