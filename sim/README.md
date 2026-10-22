# sim — 新 ENG1/ENG2 引擎回归

只保留共享 RAM 新架构的 iverilog 测试；旧并行 top 测试已归档到 `history/sim/unit/core_legacy/`。

当前 8 项全 PASS。旧前端测试已归档到 `history/sim/unit/core_legacy/`。

## 测试入口

```bash
# 需要 iverilog/vvp 在 PATH；也可以显式指定
IVERILOG=/path/to/iverilog VVP=/path/to/vvp bash sim/run_core.sh
```

当前 20 项：

```text
tb_shared_modal_ram
tb_engine_mux
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
tb_engine_post_chain
tb_shared_engines_post
tb_router_frontend_a_path_top
```

Gowin 时序探针在 `sim/synth/`：

```bash
cd <repo root>
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM=minimal
printf 'source sim/synth/gowin_build.tcl\nexit\n' | "$HOME/gowin/IDE/bin/gw_sh" -nocomp
```

报告输出在 `build/router_probe/router_probe/impl/pnr/`。
