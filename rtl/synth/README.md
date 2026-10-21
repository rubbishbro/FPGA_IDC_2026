# rtl/synth —— ENG1 A/B/C 共享顶层（迁移中）

> 权威梳理见 [`docs/ENG1_ENG2_统一架构.md`](../../docs/ENG1_ENG2_统一架构.md)。本 README 只记 `rtl/synth` 的局部约定，
> 不再重复模块清单。

模板：`rtl/simsynth/modal_voice_top.sv`（多槽存储、单份状态、引擎只算、结果流）。
目标：A/B/C 共用同一套作业口与 BUF，引擎内部各自保留 state / 工作缓存。

**先看这条边界**：当前 `audio_demo_core` 仍直接例化 `modal_engine`（A-only），
`synth_top` 只是测试/迁移路径；B/C 还没有进入真实音频链。收敛计划见权威文档 §8。

## 分层

```text
RT / class_loader ──► synth_buf（max-width 256-bit，按 engine 分 region）
                          │  coeff: ENG1 低 72 bit，ENG2 224 bit
                          │  result: 每 engine ping-pong
                          ▼
                eng1_voice_top（class_loader + modal_poly_bank）
                eng2_voice_top（modal_voice_top）
                          ▼
                   per-engine result → 求和 → POST
```

## 约定

- **BUF 是暂存层，不是工作缓存**：引擎的 32×48 / SLOTS×N_MODES 工作缓存留本地；
  BUF 只放一次装载/一次结果，深度小。
- 每个 engine 只读自己的 region；地址高位 `engine`，另一个 engine 不读。
- 每采样 state **不进 BUF**：ENG1 的 `y1/y2`、ENG2 的 `q/q̇` 都在各自 voice_top 内。
- 记录格式以 `rtl/core/class_format_pkg.sv` 为准（Index 64、`n_vel=4`、无 layer、48 模态）。

## 迁移顺序

1. `synth_buf` + `eng1_voice_top`（A 先通，A 逐位不变）；
2. `synth_top` 接 ENG1，ENG2 tie-off；
3. `eng2_voice_top` 把 `modal_voice_top` 的系数块改成读 BUF 的 ENG2 region；
4. B：class_loader 64-bit index / 4 带 / Control / a1 刷新；
5. C：seed V=4 / timer / choke；
6. 噪声最后接（接口先留）。

## 当前状态

- `class_format_pkg.sv` / `class_format.py` / T-F01 已完成。
- `synth_buf.sv`：系数 region + 结果 ping-pong，同步读；两个 region 暂用两个数组。
- `eng1_voice_top.sv`：包 `modal_engine`，A 路径通过。
- `eng2_voice_top.sv`：1:1 包 `modal_voice_top`，当前在 `synth_top` 里 tie-off。
- `synth_top.sv`：BUF + ENG1 + ENG2（tie-off）；A 冒烟通过。ENG1 结果自动写 BUF（engine 0，ping-pong）；结果读口对齐 `modal_voice_top`：`rd_en/rd_addr/rd_data/rd_valid`，`rd_addr[0]` 选 bank、`rd_addr[1]` 选 engine。
- `class_loader64.sv`：B/C 的 64-bit index、4 力度带、Control 256-bit、C seed 阶段；`test_class_loader64` 2/2 通过。
- `class_loader_mux.sv` + `modal_engine.USE_BC`：A 走 `class_loader`，B/C 走 `class_loader64`，按 `load_class` 选；`commit_ctrl` 已引出；A e01/e03–e06 通过，`test_engine_bc` 1/1 通过。
- per-voice Control：`voice_ctrl[32]` 在 `load_done` 写入，`ctrl_rd_voice/ctrl_rd_data` 读回；B 测试已验证。
- `b_a1_refresh.sv`：`s=sqrt(4a2−a1²)` + `a1' = a1 + s·δθ − a1·δθ²/2`；`test_b_a1_refresh` 1/1 通过（±1% ratio）。
- `b_a1_engine.sv`：θ ROM（`b_theta.mem`，只读）+ per-voice `theta_base` + bank 系数读 + a1 shadow 写；`tb_a1_engine`、`tb_bank_a1` 通过（iverilog）。
- `eng1_voice_top` / `synth_top` 已暴露 `load_class`、`load_note_id`、`commit_ctrl`、`ctrl_rd_voice/ctrl_rd_data`；`test_synth_top_bc` 1/1 通过。
- `b_x_pool.sv`：B 的多声部 x 池（Control 解析 + class 门控），`test_b_x_pool` 2/2；已接进 `eng1_voice_top`，按 class 做 x mux；B 顶层出声、C seed 振铃均通过（`test_synth_top_bc` / `test_synth_top_c`）。
- `b_voice_ctrl.sv`：B 的分数 NCO + AR 包络 + velocity/AM 的 x 输出；`test_b_voice_ctrl` 1/1 通过。
- `c_voice_timer.sv`：C 的 length/choke 生命周期；`test_c_voice_timer` 1/1 通过。
- 待做：C timer 的 active_mask/choke 回收、ENG2 实际数据、B/C 逐位与 A/B/C 混音、e02/e07。
