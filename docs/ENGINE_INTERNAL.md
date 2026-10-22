# Engine 内部结构分析（A/B/C 与 E2）

> 状态：结构理解，不改 RTL。结论：A/B/C 与 E2 不强行统一，各自实例；共享同一层 9×32 字段和统一的 instrument_id 编址。

## 1. A/B/C 的递推

A/B/C 走 `eng1_lane_core`，是二阶直接型递推：

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

`rtl/core/eng1_lane_core.sv` 已替换为新版，旧版归档到
`history/rtl/core/legacy_parallel/eng1_lane_core.sv`。

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
tb_eng1_lane_core   PASS
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
└─ eng2_engine_top_ext
```

A/B/C 共用同一个纯 eng1 核；旧 B/C 前端、b_a1、c_timer/c_seed、voice_env 已归档。
回归 8 项全 PASS。
