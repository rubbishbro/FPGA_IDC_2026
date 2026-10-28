# sim — 当前只保留 router 级 eng1 音频

更新：2026-10-27。

这个目录现在只有 `eng1/`：由 [`python/modal_sim/router_eng1.py`](../../python/modal_sim/router_eng1.py)
和 [`python/modal_sim/eng1_bc.py`](../../python/modal_sim/eng1_bc.py) 逐样本整数模拟
router 级 eng1 的意图链路（16 slot、Q1.31 包络、Q4.27 腔体、四梳状
混响；A/B/C 共用 `Eng1Core`）产生的音频。

```text
eng1/
  eng1_guitar_dry.wav       A 类 guitar demo，body=guitar，reverb=NONE
  eng1_flute_hall.wav       B 类 flute demo，body=passthrough，reverb=HALL
  eng1_guitar_estudio.wav   新片段：D 小调练习曲（重构后引擎）
  eng1_piano_prelude.wav    新片段：C 减和弦前奏（重构后引擎）
  eng1_b_phrase.wav         B 类长笛短句（共享 Eng1Core，周期冲激 + ADSR）
  eng1_c_groove.wav         C 类鼓组 groove（共享 Eng1Core，seed + timer + choke）
```

这些音频是 Python 模型输出；当前钢琴/吉他 RTL 选 eng0，激励形状也已变化，不能当作最新顶层逐位对拍或板级录音。对拍现状见模型说明。

这里的 Python 钢琴提取表目前只有 C / Eb / F# / A / B 这些音高类，所以前奏按这组音写；
不是用采样补齐缺失音。

生成：

```bash
python python/modal_sim/eng1_demo.py     # 原有 A/B 链演示
python python/modal_sim/eng1_pieces.py   # 新写的吉他与钢琴片段
python python/modal_sim/eng1_bc_demo.py   # B/C 共用 Eng1Core 的短句与鼓组
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
