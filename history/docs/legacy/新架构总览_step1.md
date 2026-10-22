# 新架构总览（2026-10-22）

> 状态：Step 1 结构定稿。先冻结控制面、存储分层和 engine mux；engine 内部下一步再展开。

## 1. 设计原则

```text
router       只做解析 / 编码 / 通信 / 调度
shared RAM   只放动态数据、状态和 seed
flash        只放死的系数表
LUT          只放小表/校准/多项式
engine       纯计算，不带 control / envelope / loader
后级         包络 → 腔体 → 混响 → dry/wet → final adder
```

明确不做：

```text
engine 内部不查 index/control
engine 内部不做包络
engine 内部不做颤音/滑音
engine 不自己扫 voice / 不自己搬运系数
router 不做 DSP 乘法/滤波
```

## 2. 总体数据流

```text
config / fmap（4×4 压力矩阵）
        ↓
router
  解析、编码、地址、engine 选择、start
        ↓
shared RAM（动态数据）
        ↑
flash（静态系数）/ LUT（小表）
        ↓
engine_mux
   ├─ A engine
   ├─ B engine
   ├─ C engine
   └─ E2 engine
        ↓ 只选一个
envelope_mul
        ↓
biquad_filter（全局共享）
        ↓
reverberation_filter（全局共享，wet）
        ↓
dry/wet 归一化
        ↓
final_adder
```

## 3. router

### 输入

```text
config
fmap（压力矩阵）
```

旋钮输入暂不定义。  
颤音和力度的独立交互后续再定。

### 职责

```text
1. 解析 config / fmap
2. 判断哪个键/哪个压力单元被按下
3. 编码 instrument / class / engine_sel
4. 生成 shared RAM 地址/区域
5. 生成 flash 系数地址
6. 控制 engine_mux
7. 给选中 engine 发 start
8. 决定 envelope 是否更新
9. 决定 linear_modulation 是否载入
10. 给后级发 valid / 参数选择
```

### 不做

```text
pressure → velocity 的乘法/曲线
包络乘法
颤音/滑音计算
biquad / reverb 运算
```

## 4. 存储分层

### 4.1 flash

只放静态系数和静态参数：

```text
A/B/C coefficient：G, a1, a2
E2 coefficient：a11, a12, a21, a22, gq, gv, wo
biquad 系数
reverb 参数
```

不放：

```text
index
control
seed
```

### 4.2 LUT

只放小表：

```text
pressure → velocity 曲线
linear_modulation 多项式系数
router 的 key/config 映射（如需要）
阈值 / 校准表
```

### 4.3 shared RAM

只放动态数据：

```text
pressure / velocity
key code
envelope 当前值
config / patch 运行参数
seed
engine 状态（当前 engine 的 16 voice × 9×32）
```

seed **在 RAM 里**，不放 flash。

## 5. seed 和状态

seed 是 C/E2 的初始状态，属于运行时数据：

```text
router 在 note-on 时写 shared RAM 的 seed 区
engine 从 shared RAM 读 seed
engine 运行后写回状态
```

不单独做 seed ROM。

## 6. engine_mux

四个 engine 都保留：

```text
A engine
B engine
C engine
E2 engine
```

同一时刻只接一个：

```text
router 给 engine_sel
engine_mux 选择：
  - shared RAM 读写口
  - flash 系数口
  - x / mod
  - start / done
  - y / y_valid
```

其他 engine 不读 shared RAM、不读 flash、不启动。

### shared RAM 状态区

默认按“当前 engine 独占状态区”设计：

```text
同一时刻只有一个 engine 接入
shared RAM 保存当前 engine 的 16 voice 状态
切换 engine 时重新载入/清空
```

如果以后要保留四个 engine 的休眠状态，需要四个状态 region，RAM 会增加。  
这一点需要在 engine 内部讨论时确认。

## 7. excitation_convert

```text
pressure → velocity → x
```

输入：

```text
pressure[7:0]     来自 shared RAM
calibration       来自 LUT/shared RAM
```

输出：

```text
velocity
x[31:0]           送 engine
```

驱动只提供原始压力：

```text
pad_driver 的 fmap 是 8-bit 原始压力
```

velocity 转换不在 router，也不在驱动。

## 8. linear_modulation

```text
key code + 多项式系数 → engine.mod
```

当前只留接口，不实现。  
多项式系数后续由 Python 拟合后放 LUT。

## 9. engine

每个 engine 都是纯计算：

```text
输入：
  start
  voice
  n_modes
  x
  mod
  shared RAM 状态口
  flash 系数口

输出：
  y
  y_valid
  done
```

不包含：

```text
index/control
envelope
vibrato/glide
loader
voice 调度
```

## 10. 包络

包络乘法器在 engine 输出之后：

```text
y_env = y * env_gain
```

包络数据在 shared RAM，由 router 决定何时更新。  
engine 内部没有 `voice_env_bank`。

## 11. biquad / reverb

```text
biquad_filter       全局共享
reverberation_filter 全局共享
```

biquad 系数在 flash，按当前 instrument 选择。  
reverb 参数在 flash/LUT。

## 12. dry / wet

reverb 内部只输出 wet。  
predelay 放在分支上，不塞进全局 bus。

```text
wet_delayed = predelay(wet)
mix = (gd*dry + gw*wet_delayed) / (gd + gw)
```

增益归一化，避免 dry+wet 超过满幅。

例子：

```text
浴室：gd=0, gw=1
房间：gd=1, gw=0.4
insert：gd=0.7, gw=0.3
```

## 13. final_adder

final_adder 只做 bus/voice 最终求和，不再兼职 dry/wet：

```text
final = sum(bus_mix)
```

如果只有一个 bus，final_adder 可以是简单寄存器/直通。  
多个 instrument bus 时才有实际求和意义。

## 14. 模块清单（目标）

```text
rtl/core/
  router.sv
  shared_ram.sv
  flash_coeff_if.sv
  excitation_convert.sv
  linear_modulation.sv
  engine_mux.sv
  engine_a.sv
  engine_b.sv
  engine_c.sv
  engine_e2.sv
  envelope_mul.sv
  biquad_filter.sv
  reverberation_filter.sv
  dry_wet_mix.sv
  final_adder.sv
```

## 15. 旧实现处理

删除/迁移：

```text
b_front
b_x_pool
b_voice_ctrl
b_a1_ram_engine
b_a1_engine
b_a1_refresh
voice_env
voice_env_bank
c_voice_timer（归 router）
a_router_loader / bc_router_loader / e2_router_loader（合并进 router/flash 接口）
```

旧并行 top 已经在：

```text
history/rtl/core/legacy_parallel/
```

## 16. 待确认

1. 四个 engine 的状态是否只保留当前 engine，还是四个 region 都保留。
2. fmap 的“按下”是由 router 阈值判断，还是 driver 给 pressed 位。
3. flash 系数接口：每次 note-on 读，还是加一个小 line buffer。
4. linear_modulation 的输出是 `mod` 标量，还是一组系数 delta。
5. final_adder 是单 bus 直通，还是多 bus 求和。

## 17. 下一步

```text
Step 2：router / shared RAM 地址图
Step 3：engine_mux 接口
Step 4：四个 engine 内部结构
Step 5：包络 / biquad / reverb / dry-wet / final
Step 6：删除旧 B/C 前端
Step 7：MVP 回归
```
