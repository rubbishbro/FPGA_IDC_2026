# sim — 新 ENG1/ENG2 引擎回归

只保留新四引擎架构的 iverilog 测试；旧 demo、旧 `rtl/synth`、旧 `modal_engine` 测试已删除。

## 测试入口

```bash
# 需要 iverilog/vvp 在 PATH；也可以显式指定
IVERILOG=/path/to/iverilog VVP=/path/to/vvp bash sim/run_core.sh
```

当前 24 项：

```text
tb_modal_ram
tb_modal_ram_aux
tb_eng1_lane_core
tb_eng1_engine_top
tb_eng1_xvel
tb_voice_env
tb_eng1_engine_env_top
tb_engine_mix_sum
tb_b_front
tb_b_a1_ram
tb_c_engine_top
tb_b_engine_top
tb_abc_engines_top
tb_eng2_engine_top
tb_four_engines_top
tb_voice_router
tb_engines_system_top
tb_seed_rom
tb_c_seed_loader
tb_a_router_loader
tb_bc_router_loader
tb_router_system_top
tb_router_system_b
tb_router_system_c
```

Gowin 时序探针在 `sim/synth/`：

```bash
cd <repo root>
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM=minimal
printf 'source sim/synth/gowin_build.tcl\nexit\n' | "$HOME/gowin/IDE/bin/gw_sh" -nocomp
```

报告输出在 `build/router_probe/router_probe/impl/pnr/`。
