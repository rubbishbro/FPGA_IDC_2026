# sim — 当前只保留 router 级 eng1 音频

更新：2026-10-25。

这个目录现在只有 `eng1/`：由 [`python/modal_sim/router_eng1.py`](../../python/modal_sim/router_eng1.py)
逐样本整数模拟当前 `rtl/router/engines/eng1.sv` 链路（16 slot、Q1.31 包络、Q4.27
腔体、四梳状混响）产生的两段 WAV。

```text
eng1/
  eng1_guitar_dry.wav      A 类 guitar，body=guitar，reverb=NONE
  eng1_flute_hall.wav      B 类 flute，body=passthrough，reverb=HALL
```

生成：

```bash
python python/modal_sim/eng1_demo.py
```

模型/格式/与 RTL 的对拍说明见
[`docs/ENG1_PY_MODEL.md`](../../docs/ENG1_PY_MODEL.md)。

## 旧合成产物已归档

之前 A/B/C 类的 `pitched/`、`sustained/`、`drums/`、`song/`、`roll_compare/`、
`crosscheck/`、`vibrato_coeff/`，连同旧 `README.md` 和 `report.json`，整体移到：

```text
history/FFT_results/sim_pre_eng1_2026-10/
```

旧目录保留原相对结构，里面的音频、图和数据都还在，只是不再放在当前 `sim/` 下。
索引见 [`history/FFT_results/sim_pre_eng1_2026-10/README.md`](../../history/FFT_results/sim_pre_eng1_2026-10/README.md)。
旧的生成脚本仍在 `python/modal_sim/`，没有删除；本目录只负责“当前保留的新产出”。
