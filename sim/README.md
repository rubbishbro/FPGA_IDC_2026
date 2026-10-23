# sim — 共享 ABC/E2 引擎回归

只保留共享 RAM 新架构的 iverilog 测试；旧并行 top 测试已归档到 `history/sim/unit/core_legacy/`。

2026-10-22 基于 `cdc4e8a2` 实际重跑：当前 **21 项全 PASS**。旧前端测试已归档到 `history/sim/unit/core_legacy/`。

## 测试入口

```bash
# 需要 iverilog/vvp 在 PATH；也可以显式指定
IVERILOG=/path/to/iverilog VVP=/path/to/vvp bash sim/run_core.sh
```

当前 21 项：

```text
tb_shared_modal_ram
tb_router_loader
tb_engine_mux
tb_abc_signed
tb_e2_load_mux
tb_env_signed
tb_shared_engines_top
tb_router_system_top
tb_router_voice_alloc
tb_post_chain
tb_comb_reverb
tb_router_ctrl
tb_excitation_convert
tb_linear_modulation
tb_router_frontend
tb_post_chain_top
tb_post_handshake
tb_post_data_order
tb_engine_post_chain
tb_shared_engines_post
tb_router_frontend_a_path_top
```

覆盖共享 RAM、loader、ABC/E2 mux、负数／增益语义、后级握手与数据顺序，以及正式 top 的小规模冒烟。**不等于**满 16 voice／48 模态周期验收、真实音色听感、传感器多键闭环或板级音频验收。

独立 `FFT_spectrumshow/sim/chain_tb.v` 不在本脚本内；本轮使用 Icarus 编译时，`spectrum_map.v` 的 `xk_re_r/xk_im_r` 未声明，链级仿真未运行，不能与上述 21 项合并计为 PASS。

Gowin 时序探针在 `sim/synth/`：

```bash
cd <repo root>
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM=minimal
printf 'source sim/synth/gowin_build.tcl\nexit\n' | "$HOME/gowin/IDE/bin/gw_sh" -nocomp
```

报告输出在 `build/router_probe/router_probe/impl/pnr/`。
