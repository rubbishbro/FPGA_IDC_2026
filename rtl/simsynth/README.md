# rtl_modal —— 弦模态递推的定点 RTL（吉他/钢琴共用）

本目录是物理模型合成算法的**第一版 RTL**：从 `sythsound/sim_piano.py` / `sim_guitar.py`
的递推式出发，做到"逐位等于 Python 黄金向量、能被 Gowin 综合与布线"。

```
q' = a11·q + a12·v + gq·x
v' = a21·q + a22·v + gv·x
y  = wo·q            （用更新前的 q，与模型一致）
```

三份实现、同一个算术、三种集成方式：

| 文件 | 是什么 | 用途 |
|---|---|---|
| `modal_step_pkg.sv` | 定点格式 + `coeff_t` + 算术函数（`term`/`sat_q`/`sat_v`） | **唯一算术来源**，其余模块都调它 |
| `string_mode_step.sv` | 单模态"并联一步"，纯组合、无状态 | 参考实现 / 逐位基准 |
| `modal_bank_seq.sv` | 时分复用 bank（系数在外部 ROM、状态走旁路口） | **方案 A** |
| `modal_bank_ram.sv` | RAM 中心化 bank（系数/状态/激励/结果全在模块内，作业式） | **方案 B** |
| `coeff_loader.sv` | 窄口系数装载：32 位字 × 7 字段 = 一个模态 | A/B 顶层共用 |
| `top_seq.sv` / `top_ram.sv` | 两个方案的**公平对比顶层**（端口完全相同） | 资源/Fmax 实测 |
| `fmax_probe.sv` | 只有 clk/rst_n/led 的时序探针（内部 LFSR 激励） | 拿真实 Fmax |

## 验证状态（全部实测）

| 项目 | 命令 | 结果 |
|---|---|---|
| `string_mode_step` 逐位 | `pwsh run_xsim.ps1` | **64 例（钢琴 32 + 吉他 32）、0 失配 → PASS** |
| `modal_bank_seq` 逐位 | `pwsh run_xsim_bank.ps1` | **16 帧、80 项检查、0 失配 → PASS** |
| `modal_bank_ram` 作业级 | `pwsh run_xsim_ram.ps1` | **4 个作业（钢琴/吉他 × 单帧/48 帧）、0 失配 → PASS** |
| Gowin 综合 | `synth*.tcl` | 全部 `GowinSynthesis finish` |
| Gowin PnR（100 MHz 约束） | `synth_pnr_fmax.tcl` | 跑通；**Fmax：A 55.5 MHz / B 65.0 MHz** |

黄金向量由 `gen_golden.py` 从**真实模型**生成（钢琴走 `sim_piano` 的表、吉他走
`sim_guitar` 的拨弦初值），不是手算的期望值。

## 定点格式

```
CW = 24   常量尾数（有符号，|mant| < 2^23）
SW = 6    常量移位
QW = VW = 32   q / q'（状态）
XW = 32    激励
YW = 64    本帧 Σ wo·q（由调用方统一移位）
AW = 64    累加器
```

- 每个常量 = `mant · 2^-shift`，**每个常量自带指数**：`a12/a21` 已把 q 与 q' 各自的状态定标
  折进去（相似变换 `sq/sv`），所以四个矩阵元都是 O(1)；`gq/gv/wo` 的动态范围很大，靠指数吸收，
  硬件上只是移位，不花资源。
- 状态按每模态归一化（`sq = 2^QF / peak_q`），生成系数时算好，模块只做整数运算。
- 乘积规则：`(a·m + 2^(s-1)) >>> s`（`s=0` 不加偏置），**逐项舍入后**再相加；
  因此累加顺序无关 —— 这正是后面流水线能"晚一拍累加"而不改变结果的原因。
- 状态写回前**饱和**到 32 位；`y_sum` 不饱和。

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
| Logic | 1667（LUT 1351 + ALU 316） | **1685**（LUT 1368 + ALU 317） |
| Register | 868 | 907 |
| BSRAM | 8 | 11 |
| DSP | 1 × MULT27X36 | 1 × MULT27X36 |
| 综合逻辑级数 | 16 | **16**（同构三级流水） |
| **PnR 实测 Fmax（100 MHz 约束）** | **89.9 MHz** | **87.8 MHz** |
| PnR 逻辑级数 | 12 | 11 |
| 最差 setup slack | −1.129 ns | −1.388 ns |
| Setup TNS / 失败端点 | −271.4 ns / 557 | **−39.4 ns / 167**（好 7 倍） |
| 关键路径 | LUT → `term_q`（乘+舍入级） | LUT → `term_q`（乘+舍入级） |
| 每采样周期 | 529（11N+1） | 530（11N+2） |
| 存储归属 | 系数 ROM 在顶层、状态在 bank 内 | 系数/状态/激励/结果全在 bank 内 |

**结论**

1. **B 没有过多的资源消耗**：逻辑 +18、FF +39、BSRAM +3，与 A 基本持平。
2. **两版的流水结构现在完全同构**（都是三级：选择 → 乘+舍入 → 累加），综合级数都是 16，
   所以对比是公平的：B 用几乎相同的面积换来了"数据全在模块内 + 块处理"的接口。
3. **Fmax：A 89.9 MHz / B 87.8 MHz**，都还差 100 MHz 约 11%。但 **B 的 TNS 好 7 倍**
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
# 逐位验证（Vivado xsim）
pwsh -File rtl/simsynth/run_xsim.ps1        # 单模态一步：64 例
pwsh -File rtl/simsynth/run_xsim_bank.ps1   # 方案 A：16 帧
pwsh -File rtl/simsynth/run_xsim_ram.ps1    # 方案 B：4 作业（流水版）

# 重新生成黄金向量（会覆盖 golden_*.txt）
python rtl/simsynth/gen_golden.py

# Gowin 综合
pwsh -File rtl/simsynth/run_gwsh.ps1 -Only bank   # 或 all / step / probe
# 两个顶层公平对比 + PnR 拿 Fmax（约 10 分钟）
'source rtl/simsynth/synth_pnr_fmax.tcl' | & 'E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe' -nocomp
```

工具版本：Vivado 2017.4（xsim）、Gowin V1.9.12（`sysv2017`），器件
**GW5AST-LV138FPG676AES**（Tang Mega 138K Pro，device_version B）。

## 还没做的

- **到 100 MHz 的流水**：B 再切 1–2 级（RAM 读出 / 操作数选择打拍）即可望达标；A 需要更多级。
- 系数 ROM 的**真实内容**（每个音每个模态的定点系数表，由 `gen_golden.py` 那套工具批量导出）
  与 note-on 装载流程。
- 腔体滤波器（CAD）与激励发生器；与队友 `clk_rst_pkg` / 顶层的接入。
- 多声部（当前一个 bank = 一个音）。

## 与队友 RTL 的关系

| 他们的模块 | 结构 | 能否直接用 |
|---|---|---|
| `rtl/core/resonator.sv` | (a1,a2,G) 二阶 IIR，状态是隐藏的 (y1,y2) | **不能**：我们的算法需要**物理 (q,q̇)**（拨弦是 q 的初始条件、琴桥力是 Σwo·q、输入有两条增益） |
| `rtl/core/modal_lane.sv` | (a1,a2,G) 三系数的 TDM lane（三相调度） | 调度思想可借鉴；接口风格已刻意对齐 |
| `rtl/core/body_filter.sv` | **DF-I 4 段级联**（b0..b2/a1/a2、valid-ready、GUARD_BITS、饱和标志） | **结构上与我们的腔体同构，最有望直接复用**：3 段系数可直接喂（第 4 段置零或按 4 段重拟合） |

## 与 rtl/math（定点/浮点工具包）的关系

modal_step_pkg 的舍入与饱和已改为调用 
tl/math/pkg/fxp_pkg.sv：

- 	erm() = xp_pkg::fx_mul_rnd(a, m, 0, 0, -s) —— 乘法与四舍五入移位都在包里；
  xp_pkg 的 64 位只是载体，综合器按实际位宽裁剪（实测同一 bank：+11 LUT，
  MULT27X36 仍为 1）。
- sat_q/sat_v = xp_pkg::fx_sat(v, 0, 0, QW/VW)。
- 等价性由 
tl/math/tb/tb_fp_ops.sv 证明（5660 项检查，含 4060 项
  x_mul_rnd ↔ 	erm 随机/定点平局比对）。
- string_mode_step 的端口已改用 
tl/math 的 sfp interface 声明
  （q/q' = s8.24、x = s4.28、y = s24.40），64 例黄金向量逐位不变。

两套定点约定的完整差异与合并方案见 [FORMAT_ALIGNMENT.md](FORMAT_ALIGNMENT.md)。
