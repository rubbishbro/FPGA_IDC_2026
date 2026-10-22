# rtl — 新共享 RAM 架构

当前正式路径只保留：

```text
router_system_top
└─ shared_engines_system_top
   └─ shared_engines_top
      └─ engine_mux
         ├─ pure_engine_abc   （A/B/C 共用纯 eng1 核）
         └─ eng2_engine_top_ext
```

共享：

```text
shared_modal_ram   唯一一份 9×32 / depth 320
```

旧并行 top、旧 B/C 前端、b_a1/c_timer/c_seed/voice_env 已归档到
`history/rtl/core/legacy_parallel/` 和 `history/rtl/core/legacy_frontend/`。

保留的当前文件：

```text
router_system_top.sv
shared_engines_system_top.sv
shared_engines_top.sv
engine_mux.sv
pure_engine_abc.sv
eng1_engine_top_ext.sv
eng1_lane_core.sv
eng2_engine_top_ext.sv
shared_modal_ram.sv
voice_router.sv
router loaders: a_router_loader / bc_router_loader / e2_router_loader
class_loader / class_loader64
modal_record_pkg.sv
```

`router` / `excitation_convert` / `linear_modulation` / `envelope_mul` /
`biquad` / `reverb` / `dry-wet` / `final_adder` 仍未实现。
