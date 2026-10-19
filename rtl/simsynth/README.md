# rtl_modal —— 弦模态递推的定点 RTL（吉他/钢琴共用）

本目录是物理模型合成算法的**第一版 RTL**：从 `sythsound/sim_piano.py` / `sim_guitar.py`
的递推式出发，做到"逐位等于 Python 黄金向量、能被 Gowin 综合与布线"。

```
q' = a11·q + a12·v + gq·x
v' = a21·q + a22·v + gv·x
y  = wo·q            （用更新前的 q，与模型一致）
```

```
rtl/simsynth/
  modal_step_pkg.sv     定点格式 + coeff_t + 算术（唯一算术来源）
  string_mode_step.sv   单模态并联一步（参考实现）
  modal_bank_seq.sv     方案 A（系数在外部 ROM）
  modal_bank_ram.sv     方案 B（RAM 中心化）
  modal_engine7.sv      7 乘法器并联引擎（只算不存）
  modal_voice_top.sv    声部层（8 槽存储 + 状态 ping-pong + 声部调度）
  coeff_loader.sv       窄口系数装载
  top_seq.sv top_ram.sv 方案 A/B 的公平对比顶层
  fmax_probe.sv         只有 clk/rst_n/led 的时序探针（fmax_seq / fmax_ram / fmax_e7）
  dsp_probe*.sv         DSP 映射试验
  tb/                   测试台 + 黄金向量 + 运行脚本 + 生成器
  constr/               时序与引脚约束（fmax.sdc / fmax200.sdc / fmax.cst）
  syn/                  综合与 PnR 脚本（synth*.tcl、run_gwsh.ps1）
```

三份文档：[ARCH_PARALLEL7.md](ARCH_PARALLEL7.md)（7 乘法器架构）、
[FORMAT_ALIGNMENT.md](FORMAT_ALIGNMENT.md)（两套定点约定对齐）、
[RESOURCE_BUDGET.md](RESOURCE_BUDGET.md)（**每模态存储核算 + 32 声部吉他/钢琴容量 + 8 声部架构对比**）。

三份实现、同一个算术、三种集成方式：

| 文件 | 是什么 | 用途 |
|---|---|---|
| `modal_step_pkg.sv` | 定点格式 + `coeff_t` + 算术函数（`term`/`sat_q`/`sat_v`） | **唯一算术来源**，其余模块都调它 |
| `string_mode_step.sv` | 单模态"并联一步"，纯组合、无状态 | 参考实现 / 逐位基准 |
| `modal_bank_seq.sv` | 时分复用 bank（系数在外部 ROM、状态走旁路口） | **方案 A** |
| `modal_bank_ram.sv` | RAM 中心化 bank（系数/状态/激励/结果全在模块内，作业式） | **方案 B** |
| `modal_engine7.sv` | **7 乘法器并联**的纯计算引擎（五级流水；数据面只有 SRAM 式读写口，**不含存储**） | ARCH_PARALLEL7 §8A |
| `modal_voice_top.sv` | 声部层：**多槽存储**（8 槽 × 系数/状态/激励/结果）+ 状态 ping-pong + 声部调度，持有全部存储 | ARCH_PARALLEL7 §8B |
| `coeff_loader.sv` | 窄口系数装载：32 位字 × 7 字段 = 一个模态 | A/B 顶层共用 |
| `top_seq.sv` / `top_ram.sv` | 两个方案的**公平对比顶层**（端口完全相同） | 资源/Fmax 实测 |
| `fmax_probe.sv` | 只有 clk/rst_n/led 的时序探针（内部 LFSR 激励） | 拿真实 Fmax |

## 验证状态（全部实测）

| 项目 | 命令 | 结果 |
|---|---|---|
| `string_mode_step` 逐位 | `pwsh tb/run_xsim.ps1` | **64 例（钢琴 32 + 吉他 32）、0 失配 → PASS** |
| `modal_bank_seq` 逐位 | `pwsh tb/run_xsim_bank.ps1` | **16 帧、80 项检查、0 失配 → PASS** |
| `modal_bank_ram` 作业级 | `pwsh tb/run_xsim_ram.ps1` | **4 个作业（钢琴/吉他 × 单帧/48 帧）、0 失配 → PASS** |
| `modal_voice_top` 作业级 + 多声部 + 运行中装载 + 换音色重刷 | `pwsh tb/run_xsim_engine7.ps1` | **7 个作业（4 条黄金向量 + 多声部 + 运行中装载 + 停机重刷）、0 失配 → PASS** |
| Gowin 综合 | `syn/synth*.tcl` | 全部 `GowinSynthesis finish` |
| Gowin PnR（100 MHz 约束） | `syn/synth_pnr_one.tcl`（TOP / SDC 环境变量） | 跑通；**Fmax：A 72.8 / B 73.7 / 7 乘法器引擎 104.8 MHz（收敛）** |

黄金向量由 `gen_golden.py` 从**真实模型**生成（钢琴走 `sim_piano` 的表、吉他走
`sim_guitar` 的拨弦初值），不是手算的期望值。

## 定点格式（2026-10-18：改为逐字段定 Q + 32 位尾数）

```
CW = 32    常量尾数（有符号，|mant| < 2^31）；小数点由**字段**决定，记录里没有移位字段
SH_A11 = 28   SH_A12 = 30   SH_A21 = 23   SH_A22 = 28
SH_GQ  = 31   SH_GV  = 27   SH_WO  = 15
QW = VW = 32   q / q'（状态）
XW = 32    激励（XF = 28）
YW = 64    本帧 Σ wo·q（YF = 40，由调用方统一移位）
AW = 64    累加器
```

- 每个常量 = `mant · 2^-SH_field`。原先是"24 位尾数 + 6 位指数/每条目"，现在改成
  **逐字段编译期 Q**：`a12/a21` 已经把 q 与 q' 各自的状态定标折进去（相似变换 `sq/sv`），
  四个矩阵元是 O(1)；七个字段各自一个 Q，由 `_analysis/_field_q_sizing.py` 在全音域
  40–80、缩放后域上取最大值再留 3 位整数余量定出来。
- **为什么是 32 位而不是 36 位**：`rtl/math` 的 `fxp_pkg` 载体是 64 位，
  `32 位状态 × 32 位尾数 = 64` 正好装满、乘积无截断；36 位尾数会得到 68 位而被截断
  （实测会直接导致数值不符）。32 位已经比原来的 24 位逐条指数**好约 78 倍**
  （极点半径误差 max 4.0e-08 → 5.2e-10；衰减率误差 0.02 → 0.00 dB/s），
  器件上 32/36/40 位同价（都是 2 个 `MULT27X36`）。
- 收益：移位不再来自系数记录（运行量），而是按 `k` 选**编译期常量**，
  关键路径从"6 级桶形移位"缩成"1 级 7 选 1"；代价是 +1 个 `MULT27X36`。
- 状态按每模态归一化（`sq = 2^QF / peak_q`），生成系数时算好，模块只做整数运算。
- 乘积规则：`round(a·m · 2^-SH)`，**逐项舍入后**再相加（`fxp_pkg::fx_mul_rnd`）；
  因此累加顺序无关 —— 这正是流水线能"晚两拍累加"而不改变结果的原因。
- 状态写回前**饱和**到 32 位；`y_sum` 不饱和。
- `gen_golden.py` 的 `SH` 表与 `modal_step_pkg` 的 `SH_*` **必须一致**，否则黄金向量与 RTL 错位。

## 三个模块的时序

### `string_mode_step`（组合，无状态）
七项并行：`term(q,a11) + term(v,a12) + term(x,gq)` → `sat` → `q'`，同理 `v'`，`y = term(q,wo)`。

### `modal_bank_seq`（方案 A：每帧一个采样，11N+1 拍）

| 状态 | 拍数 | 干什么 |
|---|---|---|
| `S_REQ` | 1 | 给系数 ROM 地址与状态 RAM 地址（同步读，下一拍有效） |
| `S_MAC` | 9 | k=0..8：**三级流水**（操作数选择 → 乘+舍入 → 累加），一个乘法器 |
| `S_WB` | 1 | 状态写回 RAM、`y_sum += y_acc`；还有模态就回 `S_REQ` |
| `S_DONE` | 1 | `frame_done` 脉冲 |

N=48 时 529 拍/采样，100 MHz / 48 kHz 预算 2083 拍（余量 3.9×）。

### `modal_bank_ram`（方案 B：作业式，11N+2 拍）

| 状态 | 拍数 | 干什么 |
|---|---|---|
| `S_X` | 1 | 取本帧激励（同步 RAM） |
| `S_REQ` | 1 | 取本模态系数与状态（同步 RAM） |
| `S_MAC` | 9 | 三级流水：S1 操作数选择 → S2 乘法+舍入 → S3 累加（k=0..8） |
| `S_WB` | 1 | 状态写回 + `y` 累加；还有模态就回 `S_REQ` |
| `S_FRAME` | 1 | `y_ram[j] = y_sum`，进入下一采样；采样跑完 → `S_DONE` |

一次 `start` 跑 `n_samples` 帧，结果写进结果 RAM。N=48、每采样一个作业时 530 拍。

**三级流水为什么逐位等价**：每个乘积都"先独立舍入成整数、再相加"，加法顺序无关，
所以把选择/乘/累加拆成三级、晚两拍累加不改变任何结果 —— 黄金向量一次都没改。

## 方案 A vs B：含顶层的公平对比（实测）

两个顶层 `top_seq.sv` / `top_ram.sv` 的**端口和功能完全相同**（同样的窄口系数装载 +
同样的逐采样 `x_valid/x_data → y_valid/y_data` 流）；A 的顶层里额外放了它必须外挂的系数 ROM；
所有存储阵列都加了 `(* syn_ramstyle = "block_ram" *)`，B 用 `DEBUG_PORT=0` 的生产配置。

| 项 | **A：`top_seq`** | **B：`top_ram`** |
|---|---|---|
| Logic / Register / BSRAM | **1708 / 1071 / 18** | **1717 / 1109 / 24** |
| DSP | 2 × MULT27X36（32 位尾数） | 2 × MULT27X36 |
| **PnR 实测 Fmax（100 MHz 约束）** | **72.8 MHz** | **73.7 MHz** |
| PnR 逻辑级数 | 10 | 10 |
| 每采样周期 | 529（11N+1） | 530（11N+2） |
| 存储归属 | 系数 ROM 在顶层、状态在 bank 内 | 系数/状态/激励/结果全在 bank 内 |

**结论**

1. **B 没有过多的资源消耗**：逻辑 +18、FF +39、BSRAM +3，与 A 基本持平。
2. **两版的流水结构现在完全同构**（都是三级：选择 → 乘+舍入 → 累加），综合级数都是 16，
   所以对比是公平的：B 用几乎相同的面积换来了"数据全在模块内 + 块处理"的接口。
3. **Fmax：A 72.8 MHz / B 73.7 MHz**（系数阵列按字段拆开后重测；拆之前 A 76.1 / B 71.8，
   旧 24 位格式 89.9 / 87.8），距离 100 MHz 还差 26–27%
   （−39.4 ns / 167 个端点 vs A −271.4 ns / 557），整体更接近收敛。
4. 关键路径都落在 **"乘 + 舍入 + 移位"这一级**上（`term()` 里的 64 位加法与移位）。
   再切一级（乘积先打拍，再单独做舍入/移位）就能过 100 MHz —— 这是明确的下一步。
5. 之前"B 比 A 贵 2.4 倍"完全是两个可修的假象（见下面的坑 #6、#7）。

### DSP 试验（`dsp_probe*.sv`）

同一段"32×24 有符号乘 + 舍入右移"：

| 版本 | Logic | Register | MULT27X36 | 级数 |
|---|---|---|---|---|
| 纯组合 | 636（LUT 572 + ALU 64） | 0 | 1 | — |
| 乘法两端寄存 | 654（LUT 590 + ALU 64） | 126 | 1 | 17 |

⇒ **Gowin 本来就把它映射到 DSP**（组合/寄存器化都一样），面积几乎不差；器件 298 个 DSP
一个 bank 只用约 2 个。**"要不要用 DSP"不是面积问题，而是时序问题**：寄存器化（流水线）
才是提高 Fmax 的手段，而它恰好就是 DSP 友好的写法。

## 7 乘法器引擎 + 声部层（ARCH_PARALLEL7 第 8 节的实施）

`modal_bank_ram` 的 7 个乘积是**一个乘法器轮转**算的：一个模态要 11 拍，"移几位"还得由运行时的
`k` 选出来 ⇒ 逐字段 Q 只能省掉系数里的移位字段，桶形移位器仍留在关键路径上（A/B 两个顶层的最差
路径都是 `LUT → term_q`，13.1 / 13.9 ns）。

把 7 个乘积**并联**，每个字段的移位量 `SH_*` 就成了编译期常量（`>>> SH_A11` 退化成连线），
舍入偏置 `1<<(SH-1)` 也是常数。7 个乘法器的成本由 8 个声部分摊。

### 分工：引擎只算，存储和声部在顶层

| 模块 | 职责 | 有没有存储 |
|---|---|---|
| `modal_engine7.sv` | 7 乘法器 + 五级流水；对外只有 `start/n_samples/n_modes/done/busy` 和 5 组 SRAM 口（本声部内的**偏移**地址） | **没有** |
| `modal_voice_top.sv` | 8 槽 × 系数/状态/激励/结果、地址拼接 `{槽号, 偏移}`、声部调度、状态 ping-pong | **全部** |

引擎不知道有几个声部、也不知道哪一份在跑；换声部只是顶层换地址高位。

### 五级流水（吞吐 1 模态/拍）

| 级 | 内容 | 序号 |
|---|---|---|
| R | 给 co/st 读地址（同步 RAM） | `ri` |
| M | 7 个 32×32 乘法 → `p_*` | `ri−1` |
| N | `(p + 2^(SH−1)) >>> SH` → `t_*` | `ri−2` |
| S | 三路相加 → `qn_q/vn_q`（`t_wo` 也过一级） | `ri−3` |
| W | 饱和 → 写回状态；`y_acc += two_q` | `ri−4` |

一帧 = `1 + 1 + (N+4) + 1 + 1 = N + 8` 拍；N=48 时 **56 拍**（`modal_bank_ram` 是 530 拍）。
8 声部 × 48 模态 + 声部切换 ≈ 480 拍/采样，占 48 kHz / 100 MHz 预算（2083 拍）的 **23%**。

**为什么必须切五级**：第一版把 M/N/S/W 挤在一拍，PnR 实测最差路径 **16.0 ns（64 MHz）** ——
一条路径穿过 乘法 → 64 位舍入加 → 常数移位 → 三路 64 位加 → 饱和 → RAM 写口。
切开后每级 2–4 ns，瓶颈换成了"RAM 读出 → bank 2 选 1 → 乘法器输入"。

### 状态 ping-pong

- 8 个槽位常驻；装载口地址 = `{槽号, 偏移}`，写的是**引擎下一帧要读的那一份状态块**；
- 系数/激励/状态三块阵列各自 1R1W：引擎读系数、顶层写系数，两者同拍也不冲突；
  测试台专门验证了"引擎在跑槽 0 时装载槽 1"（检查 busy 仍为 1）；
- 状态 A/B 每帧末交换一次（`pp` 翻转）：引擎永远读"旧"写"新"，所以顶层可以随时写旧状态
  （note-on 清零、直接往 q 上加激励，正合 `sim_guitar.py` 的 `self.q += K`），而引擎不会写自己正在读的阵列；
- 代价是状态 RAM ×2（64 位/模态，相对系数的 224 位是小头），换来的是三块阵列**全是 1R1W**、
  不需要任何写口仲裁。

### 踩到的两个综合陷阱（都已修）

1. **`coeff_t` 结构体阵列不进 BSRAM**：224 位一个字的阵列，综合日志里只有 q/v/x/y 有
   "Extracting RAM"，`co_ram_*` 没有 ⇒ 直接退回 FF（实测 +25k 寄存器、布线报 6530 条布不通）。
   改成**按字段拆成 7 个 32 位阵列**（`ca_a11..ca_wo` / `cb_*`）后 22 个阵列全部进 BSRAM。
2. **7 个系数写成同一个值会被 CSE 合并**：探针原来写 `co_data <= {7{lfsr}}`，综合器认为 7 个乘法
   是公共子表达式，只留 3 个（`MULT27X36` 从 14 掉到 6），那样量出来的 Fmax 不可信。
   改成 7 个不同的循环移位后恢复 14 个。

### 实测（`fmax_e7` 探针：VOICES=8、N_MODES=48、X_DEPTH=64、DEBUG_PORT=0）

| 项 | 1 引擎 + 8 个槽位（状态 ping-pong） | 摊到每声部 |
|---|---|---|
| Logic | **1531** | 191 |
| Register | **785** | 98 |
| BSRAM | **28** | 3.5 |
| DSP | **28**（14 × `MULT27X36`） | 3.5 |
| 存储 | 13 个阵列**全部**进 BSRAM（不再有 FF 回退） | — |
| 每采样拍数（8 声部 × 48 模态） | 8 × (56 + 4) ≈ **480** = 预算 23% | 60 |
| **PnR Fmax（100 MHz 约束）** | **104.8 MHz**（slack +0.458 ns，**收敛**） | — |

关键路径变成 **`bank` → 状态读数据 2 选 1 → 乘法器输入**（约 9.5 ns），
不再是"乘 → 64 位舍入 → 桶形移位"。

**16 声部怎么摊**：一个引擎 8 槽 × 2 个引擎 = 16 声部 ⇒
逻辑 ≈ 3.1k、寄存器 ≈ 1.6k、BSRAM ≈ 56、DSP 56（298 的 19%）、
每采样 2 × 480 = 960 拍（预算 46%）。

**和"每声部一个 TDM bank"比**（16 声部）：

| 16 声部 | TDM bank（`modal_bank_ram`） | **7 乘法器引擎 ×2** |
|---|---|---|
| 实例数 | **5 个 bank**（16 × 530 = 8480 拍/采样 > 预算 2083，必须并行摊） | **2 个引擎** |
| Logic | ≈ 8.5k | ≈ **3.1k** |
| Register | ≈ 2k | ≈ **1.6k** |
| DSP | 10 × `MULT27X36` | 28 × `MULT27X36` |
| 每声部每采样拍数 | **530** | **60**（快 8.8 倍） |
| Fmax | 73.7 MHz | **104.8 MHz** |

⇒ 逻辑省 2.4 倍、拍数省 8.8 倍、Fmax 高 41%；代价是 DSP 从 10 个涨到 28 个
（器件有 298 个，占 9%，其余留给腔体滤波/激励）。

## 踩过的坑（都是被仿真或综合抓到的真 bug）

1. **SV 乘法宽度**：`a * m` 的结果宽度是操作数最大宽度、不是 LHS 宽度。32 位状态 × 24 位系数
   必须先**符号扩展到累加器宽度**再相乘，否则高位直接丢。
2. **系数尾数的符号位**：`mant` 用满 24 位（`|mant| ≥ 2^23`）会被 24 位有符号端口当负数
   （实测 16776243 → −973）。生成器现在 assert 幅值只占 `CW-1` 位、移位不超过 6 位。
3. **同步 RAM 的地址/数据差一拍**：系数必须在 `S_MAC` 期间直接用 `c_data`；在 `S_REQ` 末尾
   再锁一次就会**晚一个模态**（现象：slot m 拿着 m−1 的结果）。
4. **状态写回根本没写**：RAM 本体里只接了装载口 `st_we`，计算侧 `st_wen/st_waddr` 声明了没用
   ⇒ 48 帧跑完状态一直是 0。
5. **测试台装载顺序**：`co_addr` 在时钟沿**之后**才赋值 ⇒ 每个模态的系数写进前一个地址，
   整体错位一格（现象：帧和比期望大 3.07×，因为模态间的抵消关系被打乱）。
   教训：RAM 接口的地址/数据/使能必须**同一拍全部就位**。
6. **结构体阵列进不了 BSRAM**：`mode_state_t st_ram[]` 会被 Gowin 退回 2048 个 FF；
   拆成 `q_ram`/`v_ram` 两个纯向量数组后才进 BSRAM。
7. **多一个读口就进不了 BSRAM**：验证用状态读回口让状态阵列变成 1W2R（BSRAM 只支持 1W1R），
   又退回 FF。加 `DEBUG_PORT` 参数，生产配置关掉。
8. **计数器位宽不够**：流水计数器 `k` 是 `logic [2:0]`，而排空点写成 `3'd8` —— 8 被截成 0，
   FSM 在 k=0 就退出 `S_MAC`、累加器永远是 0（现象：所有状态与 y 全为 0）。改成 4 位 + `4'd8`。

## 怎么跑

```powershell
# 全套四套仿真（Vivado xsim），最后汇总 PASS/FAIL
pwsh -File rtl/simsynth/tb/run_all.ps1

# 或者单跑
pwsh -File rtl/simsynth/tb/run_xsim.ps1        # 单模态一步：64 例
pwsh -File rtl/simsynth/tb/run_xsim_bank.ps1   # 方案 A：16 帧
pwsh -File rtl/simsynth/tb/run_xsim_ram.ps1    # 方案 B：4 作业（流水版）
pwsh -File rtl/simsynth/tb/run_xsim_engine7.ps1 # 7 乘法器 + 声部层：8 作业

# 重新生成黄金向量（会覆盖 tb/golden_*.txt；需要 _analysis/ 里的模型工具）
python rtl/simsynth/tb/gen_golden.py

# Gowin 综合（run_gwsh.ps1 里的三个顶层）
pwsh -File rtl/simsynth/syn/run_gwsh.ps1 -Only bank   # 或 all / step / probe
# A/B/7 乘法器三个顶层各做一次 syn+PnR 拿 Fmax（约 15 分钟）
'source rtl/simsynth/syn/synth_pnr_fmax.tcl' | & 'E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe' -nocomp
# 只跑一个顶层、并且换约束（SDC=fmax200.sdc 探真实 Fmax）
$env:TOP='fmax_e7'; $env:SDC='fmax.sdc'; 'source rtl/simsynth/syn/synth_pnr_one.tcl' | & 'E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe' -nocomp
```

工具版本：Vivado 2017.4（xsim）、Gowin V1.9.12（`sysv2017`），器件
**GW5AST-LV138FPG676AES**（Tang Mega 138K Pro，device_version B）。

## 还没做的

- **到 100 MHz 的流水**：B 再切 1–2 级（RAM 读出 / 操作数选择打拍）即可望达标；A 需要更多级。
- 系数 ROM 的**真实内容**（每个音每个模态的定点系数表，由 `gen_golden.py` 那套工具批量导出）
  与 note-on 装载流程。
- 腔体滤波器（CAD）与激励发生器；与队友 `clk_rst_pkg` / 顶层的接入。
- 声部**分配器**（note-on/note-off → 声部槽位）与真实系数表装载。`modal_voice_top` 现在
  只会"按 `n_voices` 顺序跑一遍"，还没有"哪个键占哪个声部、哪个声部在响"的逻辑。

## 与队友 RTL 的关系

| 他们的模块 | 结构 | 能否直接用 |
|---|---|---|
| `rtl/core/resonator.sv` | (a1,a2,G) 二阶 IIR，状态是隐藏的 (y1,y2) | **不能**：我们的算法需要**物理 (q,q̇)**（拨弦是 q 的初始条件、琴桥力是 Σwo·q、输入有两条增益） |
| `rtl/core/modal_lane.sv` | (a1,a2,G) 三系数的 TDM lane（三相调度） | 调度思想可借鉴；接口风格已刻意对齐 |
| `rtl/core/body_filter.sv` | **DF-I 4 段级联**（b0..b2/a1/a2、valid-ready、GUARD_BITS、饱和标志） | **结构上与我们的腔体同构，最有望直接复用**：3 段系数可直接喂（第 4 段置零或按 4 段重拟合） |

## 与 rtl/math（定点/浮点工具包）的关系

modal_step_pkg 的乘法、舍入与饱和都建立在 `rtl/math/pkg/fxp_pkg.sv` 的算术上：

- `term()` 的"乘 + 四舍五入右移"是包内联实现的，语义与 `fxp_pkg::fx_shift_rnd` 逐位一致；
  不直接调 `fx_shift_rnd` 是因为它的 `d` 是 `int`，会把 6 位移位量拓宽成 32 位、综合出更宽的
  桶形移位器（实测 Fmax 掉约 13%）。`fxp_pkg` 的 64 位只是**载体**，综合器按实际位宽裁剪
  （实测同一 bank：+11 LUT，`MULT27X36` 仍为 1）。
- `sat_q/sat_v` = `fxp_pkg::fx_sat(v, 0, 0, QW/VW)`。
- 等价性由 `rtl/math/tb/tb_fp_ops.sv` 证明（**9680 项检查**，含 `fx_mul_rnd` 与 `term` 的
  随机/定点平局比对，以及 floor 版与四舍五入版的 `sfp`/`ufp` 全套比对）。
- `string_mode_step` 的端口已改用 `rtl/math` 的 `sfp` interface 声明
  （q/q' = s8.24、x = s4.28、y = s24.40），64 例黄金向量逐位不变。

两套定点约定的完整差异与合并方案见 [FORMAT_ALIGNMENT.md](FORMAT_ALIGNMENT.md)。

## 2026-10-18 格式变更的实测结论

系数从"24 位尾数 + 每条目 6 位移位"改成 **逐字段定 Q + 32 位尾数**（见上节）：

- **精度**：极点半径误差 max 4.0e-08 → **5.2e-10（好约 78 倍）**，衰减率误差 0.02 → 0.00 dB/s；
- **四套测试全部逐位 PASS**（64 例 / 16 帧 80 项 / 4 作业 / 9680 项数学检查）；
- **但 Fmax 退步**：A 89.9 → **72.8 MHz**，B 87.8 → **73.7 MHz**（系数阵列拆成 7 个 32 位阵列后的重测值；
  拆之前是 76.1 / 71.8）。
  原因：32 位尾数把乘积从 56 位变成 64 位，舍入加法与 6 级桶形移位器都加宽；
  两个顶层的最差路径仍是 `LUT → term_q`（13.1 / 13.9 ns）。

**为什么"逐字段 Q 省掉桶形移位"在这里没实现**：TDM 结构里"该移几位"由运行时的 `k` 选出来，
而 `fxp_pkg` 的移位参数是 `int`，会把 6 位量再拓宽成 32 位。移位只有在**每字段一个乘法器**时
才真正变成常量。

⇒ 下一步按 [ARCH_PARALLEL7.md](ARCH_PARALLEL7.md)：**7 个乘法器并联 + 声部/模态两级时分复用**
（建议 8 声部/引擎 × 2 引擎）。账面上：DSP 14 个（与声部数无关）、逻辑约 3–4k、
每模态 2 拍（8 声部时占预算 37%）、移位与舍入全部常量化，关键路径预计远超 100 MHz。
