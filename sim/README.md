# sim — 新 ENG1/ENG2 引擎回归

只保留共享 RAM 新架构的 iverilog 测试；旧并行 top 测试已归档到 `history/sim/unit/core_legacy/`。

当前 17 项全 PASS。

## 测试入口

```bash
# 需要 iverilog/vvp 在 PATH；也可以显式指定
IVERILOG=/path/to/iverilog VVP=/path/to/vvp bash sim/run_core.sh
```

当前 17 项：

```text
tb_modal_ram
tb_modal_ram_aux
tb_eng1_lane_core
tb_voice_env
tb_b_front
tb_b_a1_ram
tb_seed_rom
tb_c_seed_loader
tb_a_router_loader
tb_bc_router_loader
tb_e2_router_loader
tb_router_system_top
tb_shared_modal_ram
tb_shared_engine_mvp
tb_b_engine_top_ext
tb_c_engine_top_ext
tb_shared_engines_top
```

Gowin 时序探针在 `sim/synth/`：

```bash
cd <repo root>
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM=minimal
printf 'source sim/synth/gowin_build.tcl\nexit\n' | "$HOME/gowin/IDE/bin/gw_sh" -nocomp
```

报告输出在 `build/router_probe/router_probe/impl/pnr/`。
