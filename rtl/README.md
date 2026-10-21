# rtl — 共享 RAM 四引擎架构

当前正式路径已切到 `shared_engines_system_top`。旧并行 top 已归档到
`history/rtl/core/legacy_parallel/`，不再参与构建。

```text
rtl/core/
  router_system_top.sv          顶层：装载 + 事件 + shared_engines_system_top
  shared_engines_system_top.sv  voice_router + shared_engines_top
  shared_engines_top.sv         A/B/C/E2 + 单份 shared_modal_ram + scheduler
  shared_modal_ram.sv           唯一一份 9×32（depth 320）
  eng1_engine_top_ext.sv        A/B/C 外置 RAM 核
  eng1_engine_env_top_ext.sv    外置 RAM + envelope
  b_engine_top_ext.sv           B 外置 RAM + a1 aux/co
  c_engine_top_ext.sv           C 外置 RAM + seed/timer
  eng2_engine_top_ext.sv        E2 外置 RAM
  shared_engine_mvp.sv          A/E2 共享 RAM 早期 MVP（保留测试）
  voice_router.sv               全局 16 voice
  modal_record_pkg.sv           9×32 记录
  eng1_lane_core.sv             A/B/C 单乘法器 lane
  voice_env.sv / voice_env_bank.sv
  b_front / b_x_pool / b_voice_ctrl
  b_a1_refresh / b_a1_engine / b_a1_ram_engine
  c_voice_timer / c_seed_loader / seed_rom
  e2_router_loader.sv           E2 index/seed + 224-bit coeff
  class_loader.sv / class_loader64.sv
  a_router_loader.sv / bc_router_loader.sv
rtl/simsynth/
  modal_step_pkg.sv / modal_engine7.sv
rtl/math/pkg/fxp_pkg.sv
rtl/drivers/                    键盘/驱动依赖
rtl/math/                       CORDIC 等数学依赖
rtl/rom/                        A/B 系数、index、seed
```

注意：当前 `tb_router_system_top` 的共享 top A 路径仍是 FAIL（`mix=0`），
所以正式顶层虽然已切换，功能上还需要修 scheduler/A 包络路径。
