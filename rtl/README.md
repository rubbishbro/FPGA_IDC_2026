# rtl — 新 ENG1/ENG2 引擎架构

当前只保留新四引擎路径；旧 demo、板级顶层、旧 `modal_engine`/`poly_modal_lane` 已删除。

```text
rtl/core/
  router_system_top.sv      顶层：A/B/C 表装载 + 事件 + 四引擎 + 汇总
  engines_system_top.sv     voice_router + four_engines_top
  four_engines_top.sv       A/B/C + ENG2
  abc_engines_top.sv        A/B/C
  voice_router.sv           全局 16 voice
  modal_record_pkg.sv       9×32 记录
  modal_ram.sv              每 lane 9×32 BSRAM
  eng1_lane_core.sv         A/B/C 单乘法器 lane
  eng1_engine_top.sv        16 voice / 4 lane 调度
  eng1_engine_env_top.sv    engine + envelope
  voice_env.sv / voice_env_bank.sv
  b_engine_top.sv + b_front/b_x_pool/b_voice_ctrl
  b_a1_refresh/b_a1_engine/b_a1_ram_engine
  c_engine_top.sv + c_voice_timer/c_seed_loader/seed_rom
  eng2_engine_top.sv        ENG2 9×32 + modal_engine7
  e2_router_loader.sv       ENG2 index/seed + 224-bit coeff loader
  class_loader.sv / class_loader64.sv
  a_router_loader.sv / bc_router_loader.sv
  engine_mix_sum.sv
rtl/simsynth/
  modal_step_pkg.sv         E2 系数/状态格式
  modal_engine7.sv          E2 7 乘法/5 级流水纯计算
rtl/math/pkg/fxp_pkg.sv     定点工具
rtl/rom/                    A/B 系数、index、seed 数据
```

测试：`sim/run_core.sh`（24 项）。Gowin 探针：`sim/synth/`。
