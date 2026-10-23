# rtl — 新共享 RAM 架构

## 正式路径

```text
router_system_top
├─ router_loader
│  ├─ index_loader20        A
│  └─ index_loader64        B/C/E2
├─ router_frontend
│  ├─ router_ctrl
│  └─ excitation_convert
└─ shared_engines_system_top
   ├─ router_voice_alloc
   └─ shared_engines_top
      ├─ engine_mux
      │  ├─ pure_engine_abc → abc_engine → abc_lane_core ×4
      │  └─ e2_engine
      ├─ shared_modal_ram   唯一 9×32 / depth 320
      └─ post_chain
         ├─ envelope_mul
         ├─ body_biquad
         ├─ comb_reverb
         ├─ dry_wet_mix
         └─ final_adder
```

正式配置 `POST_EN=1`。

## 当前保留的 core 文件

```text
router_system_top.sv
router_loader.sv
router_frontend.sv
router_ctrl.sv
router_pkg.sv
router_voice_alloc.sv
excitation_convert.sv
linear_modulation.sv
shared_engines_system_top.sv
shared_engines_top.sv
engine_mux.sv
pure_engine_abc.sv
abc_engine.sv
abc_lane_core.sv
e2_engine.sv
shared_modal_ram.sv
modal_record_pkg.sv
index_loader20.sv
index_loader64.sv
class_format_pkg.sv
post_chain.sv
envelope_mul.sv
body_biquad.sv
comb_reverb.sv
dry_wet_mix.sv
final_adder.sv
router_frontend_a_path_top.sv   # A 路径 MVP，不是正式顶层
```

## 2026-10-22 文件重命名

| 旧名 | 新名 | 原因 |
|---|---|---|
| `class_loader.sv` | `index_loader20.sv` | 只负责 A 的 20-bit index |
| `class_loader64.sv` | `index_loader64.sv` | B/C/E2 的 64-bit index/control/seed |
| `eng1_lane_core.sv` | `abc_lane_core.sv` | A/B/C 共用的单 lane 递推 |
| `eng1_engine_top_ext.sv` | `abc_engine.sv` | A/B/C 共用 4-lane 引擎 |
| `eng2_engine_top_ext.sv` | `e2_engine.sv` | E2 状态空间引擎 |
| `body_filter.sv` | `body_biquad.sv` | 明确是 4-section biquad |
| `reverb_filter.sv` | `comb_reverb.sv` | 明确是 4-comb 简化混响 |
| `router_frontend_top.sv` | `router_frontend_a_path_top.sv` | 只是 A 路径 MVP |

所有 `rtl/core/*.sv` 已统一重写文件头：

```text
// 文件 : ...
// 模块 : ...
// 功能 : ...
// 说明 : ...
```

## 归档

旧并行 top、旧 B/C 前端、旧 a/bc/e2 loader 包装和旧 `voice_router` 在：

```text
history/rtl/core/legacy_parallel/
history/rtl/core/legacy_frontend/
history/rtl/core/legacy_loader/
history/sim/unit/core_legacy/
```
