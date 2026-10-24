# rtl/router —— 声部路由器（我们这一版）

> 一句话：**16 个声部 × 每声部 N 个模态**的物理模型合成器。所有存储都在 `voice_router`，
> 引擎是"只算不存"的纯计算单元；后级是"逐声部过包络 → 全声部求和 → 统一过一遍腔体"。
>
> 本文件只记录**现在代码的真实状态**。旧版的 `rtl/simsynth` 已经删了，
> 要翻旧设计就 `git log -- rtl/simsynth/` 去历史里看，别混着看。

---

## 1. 目录结构

```
rtl/router/
├─ voice_router.sv        ← 顶层：全部存储 + 调度 + 引擎 mux + 后级（混音/腔体）
├─ fmax_router.sv         ← 时序/面积探针顶层（clk/rst_n/led，内部 LFSR 造激励），综合用
├─ loader.sv              ← weight_loader：W25Q64 SPI 读驱动 + 记录装配 + 系数块写口
├─ syn_only.tcl           ← Gowin 只综合（TOP 由 $env:TOP 给）
├─ synth_pnr_router.tcl   ← Gowin 综合 + 布局布线（带 fmax.sdc/cst）
│
├─ pkg/
│  ├─ modal_step_pkg.sv   ← 模态定点格式：CW/QW/VW/XW/AW/YW、coeff_t、SH_* 移位量、饱和函数
│  └─ router_pkg.sv       ← instrument_e / reverb_preset / mod_par_t / table_base / eng_sel
│
├─ engines/               ← 纯计算：对外只有 5 组"SRAM 式"口，地址是声部内的偏移
│  ├─ eng0.sv             ← E2 状态空间（我们的，7 个乘法器并联，5 级流水，吞吐 1 模态/拍）
│  └─ eng1.sv             ← ABC 递推（队友的：acc = G*x - a1*y1 - a2*y2，3 个乘法器）
│
├─ parts/                 ← 被 routers/ 封装的功能块
│  ├─ envelope.sv         ← envelope_ADSR（含 release 段）/ envelope_dyn0 / envelope_const
│  ├─ excitation.sv       ← excitation_gen：一个状态机出脉冲串（宽度/间距/个数可调）
│  ├─ modulation.sv       ← modulation0：揉弦，单乘法器串行，15 step/模态
│  ├─ body_biquad.sv      ← 腔体：NSEC 段 biquad（吉他 5 段），Q4.27，历史状态放 RAM
│  └─ comb_reverb.sv      ← 混响湿声：4 条并联梳状延迟线，Q4.27
│
├─ routers/               ← 子路由：case(inst) 选参数 + 封装 parts（和 voice_router 同一套路）
│  ├─ exc_router.sv       ← 激励：按乐器选 shift/gate_th/train
│  ├─ env_router.sv       ← 包络：按乐器选 ADSR 参数 / dyn / 常数
│  ├─ mod_router.sv       ← 揉弦：只有 GUITAR/BASS 真的开（其它 1 拍直接 done）
│  ├─ body_router.sv      ← 腔体：乐器 → 25 个 Q4.27 系数常量表 + body_biquad
│  └─ reverb_router.sv    ← 混响：预设 → 延迟/反馈/加权 + 干湿混合（已接进顶层）
│
├─ tools/                 ← Python 打包/对账 + 一键脚本
│  ├─ bq_gen.py           ← 腔体系数 Q4.27 量化 + 回读 body_router 对账 + 生成黄金向量
│  ├─ run_bq.ps1          ← 一键跑腔体回归（tb_body_biquad）
│  ├─ bq_*.mem            ← 上面生成的激励/期望/系数（已入库，tb 直接读）
│  ├─ flash_image.py      ← flash 镜像打包（record/table/image/parse + 自检）
│  ├─ golden_seq_piano.txt ← tb_voice_router 的系数激励（4 个模态的 7 个系数）
│  │                        原先是 rtl/simsynth 的 scratch，已入库到这里
│  └─ run_flash.ps1       ← 一键跑加载器回归（tb_loader_flash）
│
└─ tb_*.sv                ← 见第 5 节（含 tb_excitation：激励脉冲串）
```

外部依赖（不在这里，但必须一起编）：
`rtl/math/pkg/fxp_pkg.sv`（定点函数）、`rtl/drivers/pkg/clk_rst_pkg.sv`、
`rtl/drivers/pkg/pad_driver_pkg.sv`（fmap 的 `mat4x4`）。

---

## 2. 数据流

```
fmap(16×8bit 压力) ──► note_on/note_gate(滞回电平) ─┬─► exc_router  ──► xmap[16]
                                                    ├─► env_router  ──► emap[16]
                                                    └─► (起音沿) ──► mod_router ──► 改系数
                                                                                    
每个采样:  for slot = 0..n_voices-1:
             eng0/eng1 用 {slot, mode} 地址读系数/状态/x ──► y（本声部本采样的 Σ wo·q）
             包络乘法: y_env = (y * emap[slot]) >>> 31        ← 3 拍流水
             累加:     y_acc += y_env                          （全声部混音）
           → body_router（乐器选 5 段系数，Q4.27）
           → reverb_router（预设 = 输入端口 reverb_preset）→ y_data
```

后级顺序**固定**：**先求和再统一过腔体**，不是每个声部各过一遍（腔体是乐器共用的）。

---

## 3. 设计要点

### 3.1 存储全在顶层，引擎只算不存
`voice_router` 持有：7 个系数阵列 + q/v 状态 + x_ram + y_out + 7 个调制参数阵列。
引擎对外只有 `co/st/x` 三个读口 + `st` 一个写口 + `y` 输出，地址都是**声部内偏移**，
顶层拼 `{slot, mode}`。好处：加声部/模态不动引擎；坏处：引擎和存储在物理上是分开的
（PnR 时要注意）。

### 3.2 定点约定（各模块不同，别串）

| 位置 | 格式 | 说明 |
|---|---|---|
| 引擎系数 a11/a12/a21/a22/gq/gv/wo | 各自一个 Q（`SH_*` = 28/30/23/28/31/27/15） | 见 `modal_step_pkg`，7 个乘法器并联，移位是编译期常量 |
| q / qdot / x / y | 32 / 32 / 32 / **64** 位 | `AW=YW=64` 是累加器和输出 |
| 包络 emap | Q1.31 | `y_env = (y * emap) >>> 31` |
| 调制参数 c0/s0/theta0/g/k12/k21 | Q1.30，gam 是 Q16.16 | `mod_par_t` |
| 腔体 body_biquad | 系数 **Q4.27**，状态 Q(G=4)，累加器 104 位 | 每段 `(acc + 2^26) >>> 27`，末段 `(y+8) >>> 4` |
| 混响 comb_reverb | 反馈/加权 **Q4.27** | 延迟线 64 位饱和 |

> Q2.30 装不下吉他腔体系数（最大 7.45e9 > int32 上限），所以腔体用 Q4.27（最大 6.94 → 9.3e8）。

### 3.3 每采样调度与实测拍数

一个采样：
`S_RUN_X(等节拍) → S_XWR(16 拍写 x_ram) → 每个声部 [S_RUN_V 等引擎 → S_ENVMUL → S_ENVACC → S_ADV]`

每声部 = `n_modes + 8`（引擎，见 `eng0.sv` 顶部注释）+ 3（包络流水/推进）；
起音那一帧再加 1（走 `S_MOD`）。

实测（`tb_throughput`，钢琴 80 模态 × 16 声部，节拍周期设 1 拍）：

| 场景 | 每采样拍数 | 48 kHz 需要 |
|---|---|---|
| 稳态 | **1474** | **70.8 MHz** |
| 16 声部同时起音那一帧 | **1490** | **71.5 MHz** |

推导式：`18 + n_voices × (n_modes + 11)`。48 模态 × 16 声部 = 962 拍 → 46.2 MHz。
腔体（93 拍/样本）和混响（7 拍流水）都只是**延迟**，不进每采样拍数——只要一帧比它们长
就能藏住。

### 3.4 `note_on` 是电平（滞回门控），不是脉冲

- `note_on[i]` = `gate_r[i] ? (fmap >= NOTE_OFF_TH) : (fmap > NOTE_ON_TH)`，打一拍输出。
- `note_gate` 与 `note_on` 是**同一根线**（保留旧端口名）。
- 谁要"起音事件"谁自己取沿：
  - `voice_router`：`note_ev = note_on & ~note_on_q` → `note_pend` → 帧头 `note_f`（只在这一帧有效），
    用来清引擎状态和触发调制器；
  - `envelope_ADSR`：内部 `onset = note_on & ~note_on_q`；
  - `excitation_gen`：在 smp_tick 上取 `note_on` 上升沿启动脉冲串（**内部不判阈值**）；
  - `body_router`：**只在换乐器时清腔体历史**（起音不清，保上一音的尾音）。
- 加载期间 `fmap_q` 冻结 ⇒ 电平冻住 ⇒ 等于"忽略外部输入"。

### 3.5 包络乘法必须拆拍

`(y * emap) >>> 31` 是 64×32 → 96 位。第一版把它和 64 位累加放一拍，PnR 实测 25.6 ns
（50 MHz）。现在拆成 `S_ENVMUL`（乘，两个输入都是寄存器）→ `S_ENVACC`（累加）两拍，
`emap[voi]` 的 16:1 读也单独一拍（`e_lat`）。代价：每声部 +2 拍。

### 3.5b 激励发生器（excitation_gen）

原来的 `pulse_single` / `pulse_train` 合并成一个状态机（`X_IDLE / X_HIGH / X_GAP`）：

| 参数 | 含义 |
|---|---|
| `PW_LEN` | 脉冲宽度（采样数，>=1） |
| `GAP_LEN` | 两脉冲间距（采样数，0 = 不留低电平，连续给力） |
| `N_PULSE` | 单次触发最多 N+1 个脉冲；**7 = 按住期间一直发** |
| `SHIFT` | 8 位力值 → 32 位定点的左移量 |
| `clear` | 换乐器时清 16 个声部状态（router 给） |

- 触发只看 `note_on` 上升沿（router 的滞回电平）；松开后当前脉冲走完就停。
- 脉冲高度跟着当时的 `fmap` 压力走（不是锁存按下瞬间的值）。
- `exc_router` 填参数：GUITAR = 1 个脉冲 2 采样宽；BASS/PAD = `N_PULSE=7`；
  其它 = 1 个脉冲 1 采样宽。**这些数都是占位，要按听感调。**
- 细节：`cnt` 记的是"这一状态已经出过几个采样"，起音那一拍算脉冲的第 1 个，
  所以 PW/GAP 不会被多算一拍（这个 off-by-one 在 tb_excitation 里盯着）。

### 3.6b 腔体历史状态搬进 RAM

原来 `body_biquad` 里 `x1/x2/y1/y2 [0:NSEC-1]` 是 4 × 5 × 68 = **1360 个 FF**，
"sec → 5:1 读 mux → 4 组 5:1 写 demux"是整条路径上的最坏项（13~17 ns，随布局漂）。

现在合成一项：`hist[0:NSEC-1]`，每项 `4*SW = 272` 位（`{y2,y1,x2,x1}`）：

- 段开始前把这一项读进 `h_rd`（272 位寄存器），段末一次写回 `hist[sec]`。
- 一拍读延迟被"tap0 只用 sec_x"天然吸收，所以**总拍数还是 93**。
- 清历史不再逐项写 0：置 `clr_run` 跑一遍段循环、期间历史读作 0，写完最后一段标志落
  （和 `eng0` 的 `st_zero`、`comb_reverb` 的 `clr_run` 一个套路）。这一遍不出输出、
  `in_ready=0`。
- **关键坑**：综合器只认"地址寄存器 + 输出寄存器"这种 RAM 形状。直接写
  `h_rd <= hist[sec+1]`（组合地址）会被打回寄存器阵列——实测单模块 REG 3262、一个
  BSRAM 都不出；把读地址先打进 `raddr`、再 `h_rd <= hist[raddr]`，立刻变成
  REG 617 / BSRAM 8。顺便：5 项太浅**不是**问题，形状才是（我还试过把深度补到 16，
  没用）。

### 3.6 后级链（混音 → 腔体 → 混响 → y_data）

- **混音**：每声部乘自己的包络再累加（`y_acc`，64 位）。曾经的 bug 是"把跨声部运行和乘上
  最后一个声部的包络"，已改成逐声部包络。
- **腔体**：`body_router`（乐器 → 25 个 Q4.27 系数 + 内嵌 `body_biquad`）。93 拍/样本，
  用 `in_ready/out_valid` 反压；混音用 `mix_v/mix_q` 递进去，上一笔没接走就原地等。
  清历史**只在换乐器时**（起音不清，否则上一音的腔体尾音会被切掉）。
- **混响**：`reverb_router` + `parts/comb_reverb`，预设由 `voice_router` 的新输入
  `reverb_preset`（`REVERB_NONE/HALL/BATHROOM`）选。`NONE` 时是逐位直通的 6 拍延迟；
  湿声 = 4 条并联梳状线（延迟/反馈/加权都由预设给，Q4.27）。
  梳状线 4 拍 + 干湿混合 2 拍 = **6 拍**。
  延迟线复位**不写 0**：挂"清空中"标志、期间读作 0（回写照常写新数据），跑满 N 个
  采样后标志自动落 —— 既不空转 2048 拍，也不会把 BSRAM 上电的随机值（仿真里是 X）
  漏进来。
- **排空**：`S_DONE` 要同时等 `mix_outstd`（腔体）和 `rev_outstd`（混响）归零才报 `done`，
  否则最后一帧的 `y_data` 会丢。

### 3.7 状态清零（省拍数的关键）

- **死声部**：包络 `emap < 1` 时**只在归零那一帧**清一次状态（`dead_ev → dead_f`），
  不是每帧都清。早先每帧清 → 全静音时 16 个声部 × 80 模态 = 2754 拍/采样（132 MHz）。
- **note-on**：`eng0` 不再跑"清零 pass"，而是把 `st_zero` 变成"读状态时按 0 处理"
  （`q_eff/v_eff`），逐位等价但省 `n_modes` 拍。
- **松键**：ADSR 现在有 release 段（`R_STEP`，每采样下降量，由 `env_router` 按乐器给：
  默认 1.048576e6 ≈ 43 ms 满量程，打击乐 2.097e6 ≈ 21 ms）。包络降到 0 之后
  `voice_dead` 才置位，再清一次状态——所以"松键后还要等释放走完"才会 static 归零。

### 3.8 flash 加载（W25Q64）

- 标准 1 线 SPI、模式 0、命令 `0x03`，`SCK = CLK/SCK_DIV`（默认 /4 ≈ 22 MHz，上限 50 MHz）。
- 布局（**和 `tools/flash_image.py` 是同一份契约**）：
  ```
  base = inst * N_MODES * 64
  第 m 个模态 64 字节：+0 a11  +4 a12  +8 a21  +12 a22  +16 gq  +20 gv  +24 wo
                     +32 c0  +36 s0  +40 gam +44 theta0 +48 g  +52 k12 +56 k21
  字段：大端 signed 32-bit；没用的字节填 0
  ```
- 一个乐器一张表，16 个 slot 共用 → loader 读一遍、写 16 份。
- 一次加载 = `N_MODES × 2090` 拍：48 模态 ≈ 100k 拍（1.15 ms @87 MHz），80 模态 ≈ 167k（1.9 ms）。
- `err` 输出：第一个字是 `FFFFFFFF` 判为没烧过。**目前没接进 `voice_router`**。

### 3.9 时序 / 面积现状（`TOP=voice_router`，N_MODES=48，含腔体）

| 项 | 数值 |
|---|---|
| Fmax（100 MHz 约束） | **85.26 MHz**（slack −1.73 ns） |
| 最坏路径 | `u_rev/u_comb/c1`——混响梳状线写 RAM 的数据路径（乘法 + 65 位加 + 饱和），11.7 ns |
| Logic | 10186（7173 LUT + 3013 ALU）/138240 = 7% |
| Register | 4555 /139140 = 3% |
| BSRAM | 79 / 340（腔体历史 8 + 混响 32 + 其余 39）|
| DSP | 26 × MULT27X36 |

**满足 48 kHz**（需要 71.5 MHz），余量约 **19%**。

腔体的历史阵列已经搬进 RAM（见 3.6b）：REG 少了 1677 个，最坏路径从腔体挪到了混响，
Fmax 76.27 → 85.26 MHz。下一个瓶颈是混响写 RAM 那一段（−1.73 ns），想再快就把
"加 + 饱和"和"写 RAM"拆成两级（组合延迟 +1 拍，`reverb_router` 的对齐要跟着改）。

> 历史教训：同一份 RTL 我量到过 85 / 58 / 76 / 85 MHz 四个数，差别全在布局。
> "大面积 FF 阵列 + 5:1 mux"这种结构对布局极其敏感，能搬 RAM 就搬。

另外注意：报告里 10 ns 周期算出来的 "required" 是 16 ns，也就是时钟树被算了 ~6 ns——
`voice_router.cst` 现在**故意不写 IO_LOC**（P16/R15 那个封装不认），上板时按原理图把
clk 放到专用时钟脚再复测，否则 Fmax 会被低估。

### 3.10 踩过的坑（改之前先看这里）

1. **`xsim 2017.4` 对 `logic signed [3:0][31:0]` 这类 packed 2D 端口**，在嵌套实例里取元素会
   算出 X（后两路全 X）。→ 系数/延迟这类小数组一律用 **scalar 端口**。
2. **不能用 `always_ff` 里 `for` + 2D 打包数组做多路 RAM**：`mem[k][...]` 的层次化下标 + 宽
   函数入参同样会出 X。→ 4 条梳状线**写开**成 4 个 1D 数组。
3. **BSRAM 仿真初值是 X**，而 `X * 0 = X`（不是 0）。直通/零权重挡不住 X。→ tb 里手动清延迟线
   （真机上电是随机值，乘 0 得 0，没这个问题）。
4. **`assign ld_co = st_co;`（结构体输出 + 连续赋值）会让 xvlog 2017.4 卡死**。→ 直接用输出
   寄存器当装配寄存器。
5. **残留的 xvlog/xsim 进程会锁住 work 库**，表现是"编译卡住不动"。→ 先 `Get-Process xvlog`
   清干净再编。
6. **这个设计对面积/布局很敏感**：loader 少 448 个 FF，Fmax 从 66 → 85.6 MHz。别随手加宽位。

---

## 4. 怎么跑

### 4.1 一键脚本（推荐）

```powershell
# 腔体：系数对账 + 生成黄金向量 + 三个用例逐位比对
pwsh -File rtl/router/tools/run_bq.ps1

# flash 加载器：镜像打包自检 + W25Q64 行为模型 + 写口逐笔检查
pwsh -File rtl/router/tools/run_flash.ps1
```

### 4.2 手工编（仓根目录，xsim）

先确认没有遗留进程：`Get-Process xvlog,xelab,xsim,xsimk`。

```powershell
$env:PATH = "E:\Xilinx\Vivado\2017.4\bin;" + $env:PATH
$common = @('rtl/math/pkg/fxp_pkg.sv','rtl/drivers/pkg/clk_rst_pkg.sv',
            'rtl/drivers/pkg/pad_driver_pkg.sv','rtl/router/pkg/modal_step_pkg.sv',
            'rtl/router/pkg/router_pkg.sv','rtl/router/parts/envelope.sv',
            'rtl/router/parts/excitation.sv','rtl/router/parts/modulation.sv',
            'rtl/router/parts/body_biquad.sv','rtl/router/parts/comb_reverb.sv',
            'rtl/router/engines/eng0.sv','rtl/router/engines/eng1.sv',
            'rtl/router/routers/env_router.sv','rtl/router/routers/exc_router.sv',
            'rtl/router/routers/mod_router.sv','rtl/router/routers/body_router.sv',
            'rtl/router/routers/reverb_router.sv','rtl/router/loader.sv',
            'rtl/router/voice_router.sv')
xvlog -sv @common rtl/router/<tb>.sv
# tb_excitation 用不到这么多文件，它自己的头部注释里写了最小列表
xelab <tb> -s <snap> --debug typical -timescale 1ns/1ps
xsim <snap> -runall
```

### 4.3 综合 / PnR（Gowin）

```powershell
$env:TOP='voice_router'    # 或 fmax_router
$gwsh='E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe'
"source rtl/router/synth_pnr_router.tcl" | & $gwsh -nocomp
# 报告：build/<top>_pnr/<top>_pnr/impl/pnr/<top>_pnr_tr_content.html（Fmax）
#       build/<top>_pnr/<top>_pnr/impl/gwsynthesis/<top>_pnr_syn.rpt.html（资源）
```

`rtl/router/voice_router.sdc`（100 MHz 时钟）和 `voice_router.cst`（只有 clk/rst_n 两个引脚）
是 PnR 必须的（原来在 `rtl/simsynth/fmax.*`，那个目录删掉后挪过来并改了名）。
cst 里的引脚是占位的，上板前要按原理图重写。

---

## 5. 测试清单（现状）

| Testbench | 覆盖什么 | 状态 |
|---|---|---|
| `tb_body_biquad.sv` | 腔体三用例：全直通 / 单段 / 5 段（走真的 body_router），512×3 样本与 Python 模型逐位比对 | ✅ PASS |
| `tb_voice_router.sv` | R1 钢琴+混响 NONE（body+reverb 逐位直通）、R1b 切 HALL（输出必须和干声不同）、R2 松键后 release 走完才归零、R3 吉他（调制器/腔体）| ✅ PASS |
| `tb_throughput.sv` | 80 模态 × 16 声部的每采样拍数（dead/live 两相 + 作业总拍）| ✅ PASS |
| `tb_loader_flash.sv` | W25Q64 行为模型 + 写口逐笔比对 + 空白片 err（表由 Python 打包）| ✅ PASS |
| `tb_reverb.sv` | NONE 逐位直通 / HALL、BATHROOM 的抽头位置与衰减（延迟线由 DUT 自己清）| ✅ PASS |
| `tb_excitation.sv` | 脉冲串：1 脉冲 / N=2 三脉冲 / N=7 持续 / clear / 声部独立 | ✅ PASS |
| `tb_modulation.sv` | 调制器递推 | ✅ PASS |
| `tb_eng1_g.sv` | ABC 引擎的 golden 值（y = 3×−2²⁸）| ✅ PASS |
| `tb_fmax_router.sv` | 探针顶层冒烟（打印 y_valid 脉冲数/状态，无 PASS 判据）| ⚠️ 仅冒烟 |

---

## 6. 待实现 / 待测试

### 6.1 必需（要出声/上板前）

1. **混响预设的上层来源**：`voice_router` 已经加了 `reverb_preset` 输入并且接进了链，
   但"谁来决定预设"（UI / 上位机 / 按键）还没定。
2. **flash 引脚/CST**：现在 `fmax.cst` 只约束了 `clk`/`rst_n`，QSPI 四个数据脚 + CS + SCK
   还没分到具体引脚（要按板子原理图填），上板前必须补。
3. **真片验证加载**：`tb_loader_flash` 只验证了协议和写口，**没有**在真板子上读过真 W25Q64；
   频率/上电时序/`SCK_DIV=2`（≈44 MHz）都没试过。
4. **加载出错策略**（`err`）：`ROUTER.md` 里写的是"策略待定"。现在 `err` 悬空，
   `S_LOAD` 无论如何都会走完。要么加一根顶层输出，要么让 FSM 停在错误态。

### 6.2 功能上还空着的

5. **BASS / PIANO 的腔体系数**：`body_router` 里这两支现在是直通（只有 GUITAR 填了 5 段）。
6. **混响预设参数**：HALL/BATHROOM 的延迟/反馈/干湿是占位数（HALL 按 Freeverb 换算、
   T60≈2.5 s；BATHROOM≈0.8 s），要按听感调。
7. **`table_base()`（`router_pkg`）**：还是 `inst × 80` 的占位，加载基地址另算（`inst × N_MODES × 64`
   字节）。两处要统一，现在只有 loader 在用真值。
8. **`eng_sel`**：CELESTA/PAD → eng1，其余 → eng0，是按乐器号拍脑袋分的；eng1 在整条链里
   **从来没跑过真实音频**（只有 golden TB）。
9. **`y_out[]`（64 深度）**：只写不读，纯调试遗留，占 BSRAM，可以删。
10. **多声部混音的 64 位溢出**：16 个声部满量程理论上会回绕（实际信号远不到），
    要保险就加宽到 68 位再饱和。

### 6.3 已验证但值得再收紧的

11. **`tb_voice_router` 里 R3（吉他）几乎没声音**：`ymax` 只有钢琴的 1/100，是 tb 里造的那套
    合成调制参数（`pm_*`）把模态压死了。跟腔体无关，但"吉他真的能响"还没被验证过。
12. **模块名/端口一致性**：`rtl/core/post_chain.sv`（队友那版）还在按**老的 6 端口**
    `comb_reverb` 和 **ROM 版** `body_biquad` 实例化，跟 `rtl/router/parts/` 不是一套，
    谁拿它当 top 编会直接端口不匹配。
13. **混响延迟线清空**：复位后靠"清空标志 + 读作 0"（跑满 N 个采样自动落），
    所以上电后**头 N 个（2048）采样只有干声**，没有湿声。这是有意的，不是 bug。
14. **`envelope_ADSR` 没有 release 段**：`!gate` 直接归零，松键是硬切（会咔哒）。原来就这样。

### 6.4 已知的设计选择（不是 bug）

- **加载阻塞**：`S_LOAD` 等 `ld_done`，这段时间 `fmap` 冻结、不出 `y_valid`，
  上层看到的就是"静音 + not ready"。换乐器头 1~2 ms 没声音，是有意省逻辑。
- **腔体在起音时清历史**：会切掉上一音的腔体尾音；想保留就只留"换乐器清"。
- **`fmap_q` 打一拍、`note_on` 打一拍**：都是为了切断长组合链，晚一拍不影响功能。

---

## 7. 相关文档

- `rtl/simsynth/ROUTER.md`（已删）—— 旧版路由器的结构/时序分析，在 git 历史里：
  `git show 9c64f6de:rtl/simsynth/ROUTER.md`；引擎那部分还有参考价值
- `rtl/math/pkg/fxp_pkg.sv` —— 定点函数（`fx_shift_rnd` / `fx_sat` …），注释里写了 Gowin 的限制
- `docs/ENGINE_INTERNAL.md` —— 引擎内部递推的推导
