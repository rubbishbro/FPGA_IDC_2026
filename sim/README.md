# sim — 共享 ABC/E2 引擎回归

## 独立配置轮询模块

`python3 sim/run_control_loop.py` 只编译 `rtl/control_loop.sv` 和
`sim/unit/control/tb_control_loop.sv`，不依赖或修改 UI、通信和 router 回归。
覆盖单／多来源、非二次幂回绕、轮询公平性、背压、复位和请求记账。
默认 5 种参数 × 3 个随机种子，共 15 组；日志在 `build/control_loop/`。
接口及验收边界见[设计文档](../docs/UI控制Loop与配置层设计.md)。

## 万向摇杆适配

摇杆独立验证入口：`python3 sim/run_joystick.py`，共 26 组参数/采集接线仿真。
接口、覆盖和 ADC 行为模型边界见[摇杆适配说明](../rtl/drivers/JOYSTICK_ADAPTER.md)。

## 共享引擎回归说明

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

## router 级 eng1 模型（Python + RTL 对拍）

`python/modal_sim/router_eng1.py` 是当前 `rtl/router/engines/eng1.sv` 的逐样本整数
模型；它同时也把激励、包络、腔体和混响包成一条可出声的链。B/C 也走同一个
`Eng1Core`，见 `python/modal_sim/eng1_bc.py` 和 `eng1_bc_demo.py`。回归入口在
`sim/unit/eng1/`：

```bash
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python -m pytest -q sim/unit/eng1/test_router_eng1.py

# 生成 build/eng1_cosim/cases.txt 并跑 tb_eng1_cosim（需要 iverilog/vvp）
PATH=$HOME/micromamba/envs/torch312/bin:$PATH \
  python python/modal_sim/eng1_cosim.py
```

对拍当前跑 `rtl_compat=True`（当前 RTL 仍有 F05）；修完后用
`--mode intended`。契约、F05/F08/F09 差异和未覆盖边界见
[`docs/ENG1_PY_MODEL.md`](../docs/ENG1_PY_MODEL.md)。本节**不计入**上面的
21 项 core 回归，也不代表整机/板级验收。
