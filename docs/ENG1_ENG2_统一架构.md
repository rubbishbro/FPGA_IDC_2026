# ENG1 / ENG2 统一架构（2026-10-21）

> 状态：**已完成（R2–R5）**；25 个 iverilog 测试通过；生产路径切换和 Gowin 综合为后续集成项。
> 目标：A/B/C/ENG2 **四个独立引擎**共用同一套“RAM 层 + 纯计算 core”结构；
> 全局 **16 voice**，每引擎物理 **16 slot**；每引擎 **4 lane**；记录 **9×32 bit**。

---

## 1. 冻结项

| # | 项 | 结论 |
|---|---|---|
| 1 | 全局声部 | **16**（4×4 矩阵键盘） |
| 2 | 引擎 | A、B、C、ENG2 四个独立并行实例 |
| 3 | 物理 slot | 每引擎 16，共 64 个物理槽，全局分配器只点亮 ≤16 |
| 4 | lane | 每个引擎 **4 lane** |
| 5 | 记录 | **9 × 32 bit = 288 bit / mode** |
| 6 | 语义 | 物理同宽，按引擎解释；router 按目标引擎写 |
| 7 | 状态位置 | 状态在 RAM 层，core 只算不存 |
| 8 | clear | 写 0 到状态字段；**不删系数**；不再保留 `state_valid` |
| 9 | seed | C 的 seed 放 ROM；note-on 写状态字段 |
| 10 | index/control | 归 router；NCO 参数留前级，包络参数进引擎内 envelope |
| 11 | 力度 | 直接进激励：A/B 的 `x`、C 的 seed 各乘一次 `vel_q` |
| 12 | 包络 | 每个引擎内部、`voice_sum` 之后、mix 之前；实现原 control 的 AR/fade 行为 |
| 13 | 结果 | 每个引擎输出一个已加权 `engine_mix`；顶层四个相加 |

---

## 2. 9×32 字段语义

物理记录 `rec[8:0]`，每字段 32 bit。

### ENG1（A/B/C）

| 字段 | 含义 |
|---:|---|
| 0 | `G`（Q2.24） |
| 1 | `a1`（Q2.20） |
| 2 | `a2`（UQ0.24） |
| 3 | `y1`（Q2.30） |
| 4 | `y2`（Q2.30） |
| 5–8 | 保留（a1 shadow / B 扩展 / C 变体等） |

状态字段：**3、4**。  
clear 只写 3、4 为 0；seed 只写 3、4。

### ENG2

| 字段 | 含义 |
|---:|---|
| 0 | `a11` |
| 1 | `a12` |
| 2 | `a21` |
| 3 | `a22` |
| 4 | `gq` |
| 5 | `gv` |
| 6 | `wo` |
| 7 | `q` |
| 8 | `q̇` |

状态字段：**7、8**。

---

## 3. 结构

```text
router（片内 ROM：index / control / seed）
   │  cfg 9×32 + seed + env 参数
   ▼
engine_ram（4 lane，每 lane 1R1W；系数 + 状态）
   │  rd_data 9×32；state write
   ▼
engine_core（纯计算；4 lane；不存状态）
   │  voice_sum（逐 voice）
   ▼
engine_envelope（B AR / C fade / A unity；引擎内）
   │  engine_mix
   ▼
top: A + B + C + ENG2
```

- core 不知道 class；
- B 的 a1 shadow、C 的 seed/timer 都不在 core；
- 每个引擎输出**已加权**的 `engine_mix`，顶层不再做 per-voice 加权。

---

## 4. 资源预算

每 mode 9×32 = 288 bit。

| 引擎 | modes | voices | RAM |
|---|---:|---:|---:|
| A/B/C | 32 | 16 | 18 KiB each |
| A/B/C | 48 | 16 | 27 KiB each |
| ENG2 | 80 | 16 | 45 KiB |

n=32 时总计约 **99 KiB**；n=48 时约 **126 KiB**。
138K 的 6120 Kbit（765 KiB）足够，BSRAM 也可接受。

---

## 5. 分阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| R0 | 本文件 + 9×32 记录包 | 编译 |
| R1 | 4-lane RAM 层：cfg/read/state write/clear/seed | iverilog 单测 |
| R2 | A 引擎 core：G/a1/a2 递推，接 RAM 层 | A 单音/多音 |
| R3 | A envelope（unity）+ 顶层四引擎求和骨架 | 顶层冒烟 |
| R4 | B/C 引擎：NCO/AR/seed/timer | B/C 单测 |
| R5 | ENG2 接 9×32 RAM 层 | 回归 |

先做 R0/R1，不碰现有 engine1 生产路径；R2 起再逐类替换。

---

## 6. 实现进度

- **R0 完成**：`rtl/core/modal_record_pkg.sv`，9×32 字段映射、状态字段掩码、
  `rec_get/rec_set/rec_clear_fields/rec_set_state`。
- **R1 完成**：`rtl/core/modal_ram.sv`，4 lane、每 lane 1R1W；
  `cfg` 整条写、`rd` 同步读、`st_we` 只写状态、`clear/seed` 只写状态。
- **单测通过**：`sim/unit/core/tb_modal_ram.sv`（iverilog），
  覆盖 cfg 回读、状态写回、clear 保系数、seed 保系数、跨 lane 地址。
- **R2 完成**：`rtl/core/eng1_lane_core.sv`（4 lane 纯计算，单乘法器 6 拍/mode）
  + `rtl/core/eng1_engine_top.sv`（16 slot、4 lane、逐 voice 调度、内建 volume 包络口）。
- **R2 单测**：
  - `tb_modal_ram.sv`：PASS
  - `tb_eng1_lane_core.sv`：PASS
  - `tb_eng1_lane_equiv.sv`：与旧 `poly_modal_lane` 随机 20 帧逐位对拍 PASS
  - `tb_eng1_engine_top.sv`：2 voice / 5 modes / 4 lane PASS
- **R3 完成**：
  - `voice_env.sv`：A unity / B AR / C fade；C 的 choke/done 会锁存 release；
  - `rtl/core/voice_env_bank.sv`：16 个 voice_env 并行；
  - `rtl/core/eng1_engine_env_top.sv`：engine + envelope bank 的完整单引擎块；
  - `tb_voice_env.sv`：PASS（A 立即 1.0；B attack/release；C choke 后不回升）；
  - `tb_eng1_engine_env_top.sv`：PASS（A voice / 1 mode / G=1 / x=0.25 -> mix=0.25）。
- **R3 补充**：`rtl/core/engine_mix_sum.sv`，四引擎结果锁存/求和，`tb_engine_mix_sum.sv` PASS。
- **R4 进行中**：
  - `rtl/core/b_front.sv`：B 的 16 voice NCO/AR x + attack/release 字段，`tb_b_front.sv` PASS；
  - `rtl/core/b_engine_top.sv`：b_front + engine/envelope，`tb_b_engine_top.sv` PASS；
  - `rtl/core/c_engine_top.sv`：seed/timer + engine/envelope，`tb_c_engine_top.sv` PASS；
  - C 的 seed 已接 `seed_vel_vec`（UQ1.15），0x8000 旁路、低力度按比例缩放。
- **R4 进行中（a1 已完成）**：
  - `modal_ram` 新增 `aux_re/aux_data` 只读口和 `co_we/co_field/co_wdata` 单字段写口；
  - `rtl/core/b_a1_ram_engine.sv` 把旧 `b_a1_engine` 适配到 9×32（读 a2/a1，写 field 1）；
  - `tb_modal_ram_aux.sv`、`tb_b_a1_ram.sv` PASS（a1 变化、a2/G 保留）。
- **R4.5 完成（A/B/C）**：`rtl/core/abc_engines_top.sv` 三引擎并列 + `engine_mix_sum`，
  `tb_abc_engines_top.sv` PASS（A-only：0.25）。
- **R5 完成（ENG2 9×32）**：`rtl/core/eng2_engine_top.sv`，
  `modal_ram` LANES=4、STATE_FIRST=7，复用 `modal_engine7` 纯计算；
  `tb_eng2_engine_top.sv` PASS（第一帧 q 更新、第二帧 wo*q 非零）。
- **四引擎顶层完成**：`rtl/core/four_engines_top.sv` = `abc_engines_top` + `eng2_engine_top`
  + `engine_mix_sum`；`tb_four_engines_top.sv` PASS（A-only 0.25，ENG2 空闲不阻塞）。
- **A 力度进 x 完成**：`eng1_engine_top` / `eng1_engine_env_top` 新增 `x_vel_vec`，
  A 的脉冲在 engine 内乘 UQ1.15；B/C 内部旁路。`tb_eng1_xvel.sv` PASS（0.25×0.5=0.125）。
- **全局 16 voice router**：`rtl/core/voice_router.sv`，local slot = global voice；
  `tb_voice_router.sv` PASS（A/B/C/ENG2 分配、note_off、复用）。
- **系统顶层**：`rtl/core/engines_system_top.sv`（事件 + router + 四引擎），
  `tb_engines_system_top.sv` PASS（A-only 0.25）。
- **seed ROM + loader**：`seed_rom.sv` + `c_seed_loader.sv`；
  `c_engine_top` 内部 `USE_SEED_ROM`；A/B/C 系统测试覆盖。
- **A/B/C router loader**：`a_router_loader.sv`、`bc_router_loader.sv`，
  读 ROM 并打包 9×32；`tb_a_router_loader.sv`、`tb_bc_router_loader.sv` PASS。
- **router_system_top**：`rtl/core/router_system_top.sv` 把 A/B/C router loader
  + `engines_system_top` + ENG2 外部 cfg 接起来；`load_done` 触发 voice_router note_on。
  - `tb_router_system_top.sv` PASS（A：ROM loader -> cfg -> 2 modes 0.25 -> mix 0.5）；
  - `tb_router_system_b.sv` PASS（B：control/NCO/AR -> 非零 mix）；
  - `tb_router_system_c.sv` PASS（C：index/control/seed -> seed loader -> timer -> 非零 mix）。
- **当前回归 25 项全 PASS**。
- **后续集成项**：把 `synth_top`/`eng1_voice_top` 生产路径切到新四引擎顶层；
  不属于本轮 R2–R5 验收。
