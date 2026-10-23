# Engine 内部结构分析（A/B/C 与 E2）

> 当前实现复核：2026-10-22，基线 `cdc4e8a2`。本轮只更新文档，未改 RTL。
> **先读 §0。** §1–8 是早期结构分析／目标稿，§9–33 是阶段记录；其中“RAM 只存状态”“四个独立 engine”“只保留一个 instrument”“统一 instrument_id”等不能直接当作当前实现。

## 0. 当前实现与验证边界

### 0.1 正式数据流

```text
router_system_top
  ├─ router_loader → index_loader20(A) / index_loader64(B/C/E2)
  │    .mem 初始化 ROM → cfg/clr/seed → shared_modal_ram
  ├─ router_frontend → router_ctrl + excitation_convert
  │    仅 fmap[7:0] → x；正式 top 注入 A/B/C/E2 slot0
  └─ shared_engines_system_top → router_voice_alloc → shared_engines_top
       ├─ engine_mux
       │    ├─ pure_engine_abc → abc_engine → abc_lane_core ×4
       │    ├─ e2_engine
       │    └─ 唯一 shared_modal_ram（系数 + 状态）
       └─ post_chain（POST_EN 默认 1）
            envelope_mul → body_biquad → comb_reverb → dry_wet_mix → final_adder
```

### 0.2 当前能力，不沿用旧稿假设

- **核与音色不同**：A/B/C 共用同一个递推核；每个 voice 的系数／状态各自存储，ABC 内不同音色没有“必须同时只能一种”的结构限制，但完整多音色演奏尚未验收。ABC 与 E2 互斥，存在 ABC active 时优先 ABC；没有自动切换／清音策略。
- **RAM 存整条记录**：4 lane × 9×32 字段，默认 `LOCAL_RAM=20`、每 lane 深度 `16×20=320`。ABC 用 field0..2 存 G/a1/a2、field3/4 存状态；E2 用 field0..6 存系数、field7/8 存状态。不是实时从外部 flash 逐 mode 读取系数。
- **装载／计算选择已分离**：`cfg_sel_e2` 决定装载目标和 `cfg_first`，`sel_e2` 决定计算读写和 `st_first`；E2 尚未 active 时也可先装载。单字段 `co_we` 与 aux 口在 mux 层仍关闭，不能直接用于上位机改参。
- **控制前端尚未闭环**：`router_frontend` 的 load 请求和地址输出未连接正式 loader；`load_inst` 仍为 2 bit，`rcfg_instrument` 为 4 bit。`router_voice_alloc` 只记录外部指定 voice 的 active/class/gate，不自动找空槽／抢占；Note Off 直接清 active，没有逐 voice release 尾音管理。
- **纯 ABC 不等于完整 B/C 乐器**：旧持续激励、a1 刷新、C timer 和 voice 包络前端已归档；顶层 B/C 的 x 除 slot0 压力覆盖外为 0。`b_ctrl/b_vel/b_ratio` 等旧接口还在，但不代表原功能仍被执行。`pure_engine_abc` 中 x_vel/env_gain 均固定 unity；`linear_modulation` 为独立占位模块，未接正式路径。
- **后级已接，不等于可调效果器已完成**：body 是四段 biquad，固定 `BODY_INSTRUMENT=0`；reverb 是四梳状简化版、反馈常量，无 allpass／独立可调 predelay。系统把 env/gd/gw 固定为 `0x8000/0x4000/0x4000`。`envelope_mul` 只是增益乘法，不是 ADSR 发生器。
- **dry/wet 是定点加权**：`round((dry*gd + wet*gw)/2^15)` 并饱和，不会除以 `gd+gw`。默认 0.5/0.5；开放参数需另定归一化和峰值策略。
- **后级逐样本握手已修复**：一个 engine 结果只送一次后级，等待对应输出后完成；旧诊断的 32 激励／1024 零循环已移除。不能据此推断满 16 voice、48 模态已满足 2048 拍预算，仍需完整周期测试。

### 0.3 本轮复核结果

| 项目 | 证据与边界 |
|---|---|
| 核心回归 | 实际重跑 `sim/run_core.sh`，**21 项 PASS**；包含 signed、E2 装载、post 握手／数据顺序及系统冒烟，不能替代满复音／真实音色／板级测试 |
| 已有 P&R | 保留的 `build/router_probe/router_probe/impl/pnr/router_probe.tr`：100.063 MHz，setup/hold 0/0，最差 setup +0.006 ns；PnR Logic 9,647、Register 6,047、BSRAM 113、DSP 56 |
| P&R 范围 | 3-I/O `router_probe`、小型测试 ROM；本轮没有重新综合／布局布线，不宣称该报告已对当前源码快照完成时序签核；不是整板音频顶层 |
| 可视化 | `FFT_spectrumshow/` 有 1024 点 FFT、128 柱和 64 帧瀑布核心；未接合成器，需 PCM 缩放和跨域 FIFO；本轮 `chain_tb` 在 `spectrum_map.v` 因 `xk_re_r/xk_im_r` 未声明而编译失败 |
| 主机／板级 | UART/host_link、蓝牙 App、FFT 联机、传感器完整映射和新路径音频板级集成不在本次 PASS 结论内 |

详见[测试说明](../sim/README.md)、[时序分析](TIMING_RAM_ANALYSIS.md)、[产品需求与竞品调研](产品需求与竞品调研.md)。后文原阶段记录保留，若与 §0 或当前 RTL 冲突，以当前源码和本节证据范围为准。

## 1. A/B/C 的递推

A/B/C 走 `abc_lane_core`，是二阶直接型递推：

```text
y[n] = clamp( (G*x[n] - a1*y[n-1] - a2*y[n-2] + 2^23) >>> 24 )
```

字段：

```text
G   : Q2.24，26-bit sign-extended
a1  : Q2.20，22-bit sign-extended，<<4 到 Q2.24
a2  : UQ0.24，24-bit zero-extended
y1  : Q2.30，上一拍输出
y2  : Q2.30，上上拍输出
```

计算时序：

```text
S_REQ  发地址
S_CAP  捕获 9×32 记录
S_M1   prod = G*x
S_M2   acc  = G*x；prod = a1*y1
S_M3   acc -= a1*y1；prod = a2*y2
S_FIN  acc -= a2*y2；算 ynew；写回 {y2_new, y1_new}
```

特点：

```text
每个 lane 一个乘法器
4 lane 并行处理 mode % 4
状态只有 y1/y2
输出 32-bit
```

## 2. E2 的递推

E2 走 `modal_engine7`，是 2×2 状态空间：

```text
q' = a11*q + a12*v + gq*x
v' = a21*q + a22*v + gv*x
y  = wo*q
```

字段：

```text
a11, a12, a21, a22 : 2×2 矩阵元
gq, gv            : 输入增益
wo                : 输出权重
q, v              : 状态（qdot）
```

特点：

```text
7 个乘法器并联
5 级流水
吞吐 1 mode/拍
状态是 q/qdot
输出 64-bit，再做 y_sum
```

## 3. 两者的关系

A/B/C 是二阶直接型：

```text
y[n] = G*x - a1*y[n-1] - a2*y[n-2]
```

E2 是 2×2 状态空间。两者都是线性递推，但：

```text
A/B/C：一个状态变量 + 两个历史值
E2：两个状态变量 q/qdot
```

可以把 A/B/C 写成 2×2 形式（q=y[n-1], r=y[n-2]）：

```text
q' = -a1*q - a2*r + G*x
r' = q
y  = q'
```

所以结构上相关，但：

```text
定点格式不同
状态含义不同
输出格式不同
流水/乘法器不同
```

结论：

```text
不强行统一 datapath
A/B/C 与 E2 各自实例
共享 9×32 字段层和 instrument_id 编址
```

## 4. 9×32 字段分配

### A/B/C

```text
field0 = G       （静态，flash）
field1 = a1      （静态，flash）
field2 = a2      （静态，flash）
field3 = y1      （RAM）
field4 = y2      （RAM）
field5..8 = 未用
```

### E2

```text
field0 = a11     （静态，flash）
field1 = a12     （静态，flash）
field2 = a21     （静态，flash）
field3 = a22     （静态，flash）
field4 = gq      （静态，flash）
field5 = gv      （静态，flash）
field6 = wo      （静态，flash）
field7 = q       （RAM）
field8 = qdot    （RAM）
```

说明：

```text
静态系数从 flash 读
RAM 只保存状态/seed/动态值
A/B/C 只用 field3/4
E2 只用 field7/8
```

如果以后 linear_modulation 要改系数，需要一个小系数缓存/寄存器，不把整张表搬进 RAM。

## 5. 统一编号：instrument_id

不要 engine_id。router 只输出：

```text
instrument_id
```

所有东西都由 instrument_id 决定：

```text
engine 类型（A/B/C/E2）
flash 系数基址
RAM 状态/seed 基址
biquad 系数基址
reverb preset
```

映射关系放在 config/LUT：

```text
instrument_id -> engine_class
instrument_id -> flash_base
instrument_id -> ram_region
instrument_id -> body_preset
instrument_id -> reverb_preset
```

这样只有一层编号：

```text
router → instrument_id → shared RAM/flash/engine
```

不需要：

```text
router → engine_id → 再二次分发
```

## 6. shared RAM 地址图

当前只保留一个 active instrument 的状态：

```text
ram_addr = instrument_base + voice*LOCAL + mode
```

A/B/C 与 E2 都在同一层 9×32 记录上：

```text
A/B/C: fields0..4
E2:    fields0..8
```

seed 也在 RAM：

```text
A/B/C seed -> field3/4
E2 seed    -> field7/8
```

如果以后要同时保留多个 instrument 的休眠状态，需要多 region；这会增加 RAM。当前默认只保留 active instrument。

## 7. engine mux

```text
engine_mux
  select = engine_class(instrument_id)
  data   = shared RAM + flash + x + mod
  output = 选中 engine 的 y
```

四个 engine：

```text
A/B/C: eng1 lane core 结构
E2:    modal_engine7 结构
```

同一时刻只有一个 engine 接入共享 RAM/flash。

## 8. 结论

```text
A/B/C 与 E2 数学不同，不强行统一
字段层统一：9×32
状态层统一：shared RAM
编号统一：instrument_id
engine 选择：instrument_id -> engine_class
静态系数：flash
seed/状态：RAM
```

下一步讨论 engine 内部时，只需要分别看：

```text
A/B/C lane core：乘法器/时序/状态写回
E2 modal_engine7：7 乘/5 级/状态写回
```

而不再讨论 index/control/loader。

## 9. 已实现的 lane 时序修改（2026-10-22）

`rtl/core/abc_lane_core.sv` 已替换为新版，旧版归档到
`history/rtl/core/legacy_parallel/abc_lane_core.sv`。

修改：

```text
1. voice 开始时只算一次 voice * LOCAL，寄存为 addr_r/voice_base_r
   每个 mode 只做 addr_r + 1，去掉 rd_addr/st_addr 里的运行时乘法
2. S_FIN2 拆成 S_FIN2A（diff+ROUND）和 S_FIN2B（移位/比较/饱和）
3. commit_mode 改为 start 时设 LANE，之后每个 mode 加 LANES
   去掉 mi*LANES+LANE 的提交路径乘法
```

测试：

```text
tb_abc_lane_core   PASS
tb_shared_engines_top PASS
tb_shared_engine_mvp PASS
tb_b_engine_top_ext PASS
tb_c_engine_top_ext PASS
tb_router_system_top PASS（共享 top A 路径）
```

本版只做 lane 时序；P&R 还没有重新跑。共享 top 的 done/mix 同拍问题也已修正。

## 10. 最新共享 top P&R（2026-10-22 17:15）

`router_probe` 在共享 top + lane retime + loader index decode pipeline 后：

```text
Fmax        102.750 MHz
Setup 违例   0
Hold 违例    0
Slack        +0.268 ns
Logic        4,119
Register     2,879
BSRAM           47 / 340
DSP             21 / 298
```

关键路径从 BC loader 的 `index_rom → offset_r` 转移到：

```text
A lane st_3_s1
  → mix_idx_1_s6
Slack +0.268 ns
```

这说明旧 loader 的 index 解码链已不再是 100 MHz 瓶颈；下一步仍是把旧 loader 替换成 router/flash 接口。

## 11. 纯 ABC/E2 engine_mux（2026-10-22）

新增：

```text
rtl/core/pure_engine_abc.sv   A/B/C 共用的纯 eng1 核（无 b_front/b_x_pool/b_a1/voice_env）
rtl/core/engine_mux.sv        pure ABC / E2 二选一 + 单份共享 RAM + 单尾部加法器
```

测试 `tb_engine_mux` PASS。

## 12. shared top 已切到纯 engine mux（2026-10-22）

`shared_engines_top` 现在只例化：

```text
engine_mux
├─ pure_engine_abc
└─ e2_engine
```

A/B/C 共用同一个纯 eng1 核；旧 B/C 前端、b_a1、c_timer/c_seed、voice_env 已归档。
回归 8 项全 PASS。

## 13. Pure top P&R（2026-10-22 17:23）

`shared_engines_top -> engine_mux(pure ABC, E2)`：

```text
Fmax        100.120 MHz
Setup 违例   0
Hold 违例    0
Slack        +0.012 ns
Logic        5,900
Register     3,212
BSRAM           71 / 340
DSP             21 / 298
```

关键路径：`router class_r -> A lane RAM f8 write port`。

## 14. 后级模块（2026-10-22）

已加入并单测：`envelope_mul`、`body_biquad`（归档恢复）、`comb_reverb`、`dry_wet_mix`、`final_adder`。`tb_post_chain` 和 `tb_comb_reverb` PASS。

## 15. router 控制面 MVP（2026-10-22）

新增 `router_pkg.sv` / `router_ctrl.sv` / `tb_router_ctrl.sv`：

```text
config/fmap → instrument_id → engine_sel / coeff_base / ram_base / load 命令
```

不做压力→激励、包络、颤音滑音。测试 PASS。

## 16. excitation / linear modulation（2026-10-22）

新增 `excitation_convert.sv`（pressure→velocity→x）和 `linear_modulation.sv`（二阶多项式占位），`tb_excitation_convert` / `tb_linear_modulation` PASS。

## 17. router_frontend（2026-10-22）

`router_frontend` 组合 `router_ctrl + excitation_convert`，测试 PASS。

## 18. post_chain MVP（2026-10-22）

`post_chain` 串联 envelope→body→reverb→dry-wet，测试 PASS。当前 dry 只做一拍对齐，完整 predelay/dry delay 仍待补。

## 19. engine_mux + post_chain 联测（2026-10-22）

`tb_engine_post_chain` 把 `engine_mux` 的 A 输出接 `post_chain`，PASS。后级仍未接正式 shared top。

## 20. shared top 可选 post（2026-10-22）

`shared_engines_top` 增加 `POST_EN`，默认 0；`tb_shared_engines_post` 用 POST_EN=1 PASS。正式顶层仍未默认开启 post。

## 21. router_frontend_a_path_top（2026-10-22）

新增 `router_frontend_a_path_top`，A 路径 config/fmap→x→engine_mux，测试 PASS；系数装载仍外部。

## 22. 统一 router_loader 顶层（2026-10-22）

`router_system_top` 现在只例化一个 `router_loader`，内部仍是 A/BC/E2 三个后端；18 项回归 PASS。

## 23. 删除旧 a/bc/e2 loader 包装（2026-10-22）

`router_loader` 直接例化 `index_loader20` / `index_loader64`，旧 a/bc/e2 loader 已归档到 `history/rtl/core/legacy_loader/`；回归 15 项。

## 24. Inlined loader P&R（2026-10-22 17:41）

旧 a/bc/e2 loader 归档，router_loader 直接例化 index_loader20/64：

```text
Fmax        100.250 MHz
Setup 违例   0
Hold 违例    0
Slack        +0.025 ns
Logic        5,889
Register     3,213
BSRAM           71 / 340
```

关键路径 `router active_r -> A lane RAM f4`。

## 25. router_loader 直测（2026-10-22）

`tb_router_loader` A 路径直接验证统一 loader，PASS；回归 16 项。

## 26. router_frontend 接入正式顶层（2026-10-22）

`router_system_top` 增加 rcfg/fmap 输入并例化 router_frontend；fmap_valid=1 时覆盖 A slot0 x；16 项回归 PASS。

## 27. router x 覆盖四 engine slot0（2026-10-22）

`router_system_top` 在 fmap_valid=1 时把 router x 同时写到 A/B/C/E2 slot0；B/C x 已从 system 顶层传入 shared top。16 项回归 PASS。

## 28. fmap 激励 P&R（2026-10-22 17:50）

`router_probe` 加入 fmap/rcfg 激励后：

```text
Fmax        100.264 MHz
Setup 违例   0
Hold 违例    0
Slack        +0.026 ns
Logic        6,075
Register     3,237
BSRAM           79 / 340
```

关键路径 `E2 n_mod_lat -> shared RAM f8`。

## 29. POST_EN=1 整机 P&R（2026-10-22 17:54）

后级默认打开时：

```text
Fmax        58.715 MHz
Setup 违例   979
Slack        -7.031 ns
Logic       10,175
BSRAM          121 / 340
```

关键路径 `reverb c4 -> mult`。因此 POST_EN 仍默认 0；后级需流水化/降频才能整机 100 MHz。

## 30. 后级流水实验（2026-10-22 18:00）

reverb 改用移位反馈后 POST_EN=1 Fmax 83.577 MHz（setup -1.965ns，460 endpoints）；再尝试读/写两级流水，Gowin 报 SP WRITE_MODE=2'b10 不支持。当前回退 single-stage 移位版，POST_EN 保持 0，正式 16 项回归 PASS。

## 31. POST_EN=1 正式 100MHz（2026-10-22 18:13）

4-comb reverb + ABC cfg 流水后：

```text
Fmax        100.224 MHz
Setup 违例   0
Hold 违例    0
Slack        +0.022 ns
Logic       10,046
Register     5,921
BSRAM          113 / 340
```

正式 POST_EN 默认 1，回归 16 项 PASS。

## 32. 后级 final_adder + reverb sum 流水（2026-10-22 18:23）

```text
Fmax        100.166 MHz
Setup 违例   0
Hold 违例    0
Slack        +0.017 ns
Logic       10,050
Register     6,054
BSRAM          113 / 340
```

POST_EN=1、final_adder 已接入；回归 16 项 PASS。

## 33. voice_router 替换（2026-10-22 18:28）

旧的 `voice_router.sv` 已归档，新模块 `router_voice_alloc.sv` 接入 shared system；100.166MHz、0/0、16 项回归 PASS。
