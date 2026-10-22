# 时序余量与 RAM 占用分析

> 数据来源：`build/router_probe/router_probe/impl/pnr/router_probe.tr`、
> `router_probe.rpt.txt`、`router_probe_syn_rsc.xml`。
> 对象是 3-I/O 的 `router_probe`（测试 ROM，POST_EN=1），不是整板音频顶层。

## 1. 结论

```text
时序：100.032 MHz，setup/hold 都 0 违例
     但 setup slack 只有 +0.003 ns（约 0.03% 周期）
RAM ：113 / 340 BSRAM（33.2%），剩 227 块
逻辑：10,099 / 138,240（7.3%）
寄存器：6,131 / 139,140（4.4%）
DSP ：56 / 298（18.8%）
```

判断：

- **BSRAM/逻辑/寄存器都有充足余量**，RAM 不是当前瓶颈。
- **时序余量非常小**，当前只能算“刚好压线过 100 MHz”（bug fix 后进一步收紧），不能算稳健 closure。
- 现有 SDC 只写了 `create_clock -period 10`，**没有 clock uncertainty、input/output delay、jitter**；真实板级时钟抖动加上后，+0.003 ns 会立刻变成负 slack。

## 2. 时序

### 2.1 汇总

| 项目 | 结果 |
|---|---|
| 约束时钟 | `clk_probe` 100.000 MHz |
| 实际 Fmax | **100.032 MHz** |
| 周期余量 | 10.000 - 9.997 ≈ **0.003 ns** |
| Setup 违例 | **0** |
| Hold 违例 | **0** |
| Setup TNS | 0.000 |
| Hold TNS | 0.000 |
| 最差 hold slack | **+0.213 ns** |

Fmax 只比约束高：

```text
(100.032 - 100.000) / 100.000 ≈ 0.032%
```

### 2.2 最差 setup 路径

| # | Slack | 起点 | 终点 | 区域 |
|---|---:|---|---|---|
| 1 | **+0.003** | `u_abc/g_lane[2].u_lane/st_2_s1/Q` | `.../n5121_0_s/B[19]` | A/B/C lane |
| 2 | +0.028 | `u_e2/u_eng/state_1_s1/Q` | `u_ram/g_lane[3].f8.../ADB[6]` | E2 → RAM |
| 3 | +0.031 | `u_post/u_rev/c1_c1_0_0_s/DO[0]` | `u_rev/sum4_65_s0/D` | reverb |
| 4 | +0.031 | `u_post/u_body/sec_0_s3/Q` | `u_body/y2[1]_40_s0/CE` | body |
| 5 | +0.055 | `u_post/u_body/sec_0_s3/Q` | `u_body/y1[1]_6_s0/CE` | body |
| 6 | +0.055 | `u_post/u_body/sec_0_s3/Q` | `u_body/y1[1]_58_s0/CE` | body |
| 7 | +0.067 | `u_ld/u_e2/vel_r_7_s0/Q` | `u_ld/u_e2/cnt_5_s1/CE` | loader |

前 25 条最差 setup 路径大致分布：

```text
A/B/C lane        10 条
reverb             7 条
E2 / loader        4 条
body               4 条
```

结论：

```text
第一瓶颈：A/B/C lane 的 st_2/st_3 路径
第二瓶颈：E2 state → shared RAM
第三瓶颈：reverb / body 的反馈路径
```

### 2.3 加时钟不确定性后的估算

当前 SDC：

```tcl
create_clock -name clk_probe -period 10.000 [get_ports {clk}]
```

没有：

```text
set_clock_uncertainty
set_input_delay / set_output_delay
```

按当前最差 slack 粗略估算：

| 额外 uncertainty | 估算 setup slack | 结果 |
|---:|---:|---|
| 0.0 ns | +0.003 ns | 当前报告 |
| 0.2 ns | ≈ -0.183 ns | 100 MHz 不通过 |
| 0.3 ns | ≈ -0.283 ns | 100 MHz 不通过 |

因此：

```text
如果要给 100 MHz 加 0.2 ns uncertainty，
需要把 Fmax 做到约 102 MHz 以上；
或者把时钟降到约 98 MHz 做 bring-up。
```

建议：

1. 板级 bring-up 先用 **95–98 MHz** 验证功能。
2. 正式 100 MHz 前，对 A/B/C lane 的 `st_1/st_3` 路径做重定时。
3. reverb `c1 → sum4` 的第二瓶颈也要一起处理，否则只修 A lane 后它会顶上来。
4. SDC 加 `set_clock_uncertainty`，不要只看当前 +0.003 ns。

## 3. RAM 占用

### 3.1 PnR 总数

```text
BSRAM 113 / 340 = 33.2%
├─ SDPB      106
├─ pROM        5
└─ pROMX9      2
```

剩余：

```text
340 - 113 = 227 块
```

### 3.2 综合层级（模块口径）

综合资源 XML 中设计本体为 **75 BSRAM**：

| 模块 | BSRAM | 用途 |
|---|---:|---|
| `u_ram` | 36 | shared_modal_ram，4 lane × 9 field |
| `u_rev` | 32 | 4 comb 延迟线 |
| `u_bc` | 4 | B/C index/coeff/control/seed ROM |
| `u_e2` | 2 | E2 ROM |
| `u_body` | 1 | body biquad 系数 ROM |
| **合计** | **75** | |

PnR 的 113 = 106 SDPB + 5 pROM + 2 pROMX9；  
**模块级 75 是综合层级口径，不能和 PnR 的 113 逐块一一对应**，PnR 还包含 ROM 映射和打包开销。

### 3.3 实际 bit 估算

shared RAM：

```text
4 lane × 9 field × 320 depth × 32 bit
= 368,640 bit
```

reverb：

```text
(1116 + 1188 + 1277 + 1356) × 64 bit
= 315,968 bit
```

两者合计约：

```text
684,608 bit
```

按 75 个 18K BSRAM 块计算，块容量约 1.38 Mbit；  
设计本体 bit 填充率约 **50%**，存在宽度/深度碎片，但块数仍有很大余量。

### 3.4 如果保留四个 engine 状态区

当前 shared RAM 用 36 块。若四个 region 都保留：

```text
36 × 4 = 144 块
相对当前 +108 块
113 + 108 = 221 / 340（约 65%）
```

仍然放得下，但会明显压缩后续扩展空间。  
如果只保留“当前 engine 独占状态区”，则维持 113 块。

## 4. 其他资源

```text
Logic      10,099 / 138,240 = 7.3%
Register    6,131 / 139,140 = 4.4%
CLS         7,054 / 69,120  = 10.2%
DSP            56 / 298     = 18.8%
```

DSP 报告：

```text
MULT27X36      27
MULT12X12       2
MULTALU27X18    1
```

DSP 块数 56 不等于上面实例数简单相加，27×36 乘法会占用多个 DSP 资源。

## 5. 建议

优先级：

```text
1. 先给 SDC 加 0.2 ns clock uncertainty，重新确认 100 MHz 是否真的过
2. 重定时 A/B/C lane 的 st_1/st_3 路径
3. 重定时 reverb c1 -> sum4
4. 板级先用 95–98 MHz bring-up
5. RAM 方面暂不需要优化；227 块余量足够
```

RAM 不是瓶颈；当前真正限制目标是 **A/B/C lane 和 reverb 的 setup 路径**。
