# sim — 新 ENG1/ENG2 引擎回归

只保留共享 RAM 新架构的 iverilog 测试；旧并行 top 测试已归档到 `history/sim/unit/core_legacy/`。

当前 8 项全 PASS。旧前端测试已归档到 `history/sim/unit/core_legacy/`。

## 测试入口

```bash
# 需要 iverilog/vvp 在 PATH；也可以显式指定
IVERILOG=/path/to/iverilog VVP=/path/to/vvp bash sim/run_core.sh
```

当前 8 项：

```text
tb_a_router_loader
tb_bc_router_loader
tb_e2_router_loader
tb_shared_modal_ram
tb_engine_mux
tb_shared_engines_top
tb_router_system_top
tb_voice_router
```

Gowin 时序探针在 `sim/synth/`：

```bash
cd <repo root>
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM=minimal
printf 'source sim/synth/gowin_build.tcl\nexit\n' | "$HOME/gowin/IDE/bin/gw_sh" -nocomp
```

报告输出在 `build/router_probe/router_probe/impl/pnr/`。
