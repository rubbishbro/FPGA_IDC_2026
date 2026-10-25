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
`voice_router` 持有：7 个系数阵列 + q/v 状态 + 7 个调制参数阵列（都按 `N_MODES` 开，
默认 64）+ 16 个激励快照寄存器。
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

**一次作业 = 一个采样**（没有 `n_samples` / `X_DEPTH`）：`start` 一次，跑完 16 个声部
出 1 个 `y_data`，`done` 在腔体+混响都排空之后给。上层按采样节拍一个 tick 发一次 `start`
（注意别在一个 tick 里发两次——两次会用同一张 `xmap`/`emap` 快照）。

一个采样：
`S_RUN_X(等节拍) → S_XWR(16 拍写 x_ram) → 每个声部 [S_RUN_V 等引擎 → S_ENVMUL → S_ENVACC → S_ADV]`

每声部 = `n_modes + 8`（引擎，见 `eng0.sv` 顶部注释）+ 3（包络流水/推进）；
起音那一帧再加 1（走 `S_MOD`）。

实测（`tb_throughput`，钢琴 80 模态 × 16 声部，节拍周期设 1 拍）：

| 场景 | 每采样拍数 | 48 kHz 需要 |
|---|---|---|
| 稳态 | **1577** | **75.7 MHz** |
| 16 声部同时起音那一帧 | ~1593 | ~76.5 MHz |

（改动前一次作业跑 64 个采样，腔体那 93 拍能和下一个采样的引擎计算重叠，所以只要 1474；
现在一个作业只跑一个采样，**每个采样都要自己等一次腔体排空**，于是多出 ~99 拍。
想把这 99 拍找回来，就得让 `done` 在"混音交给腔体"那一拍就报（而不是等排空），
代价是调用方要自己等 `y_valid`——暂时没做，78 MHz 下 1577 拍 = 49.5 kHz，够用但只有 3% 余量。）

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

> 包络一共两个模块：`envelope_ADSR`（钢琴/马林巴/电钢）和 `envelope_dyn0`
> （吉他/贝斯/颤音琴），"无包络"那一路在 `env_router` 里直接用常数 1.0
> （原来的 `envelope_const` 模块没人用，已删）。两个模块都输出 `dead`。
>
> 有符号钳位（`emap` 是 Q1.31，一旦超到 bit31 就会被读成负数）：
> - `envelope_dyn0`：`fmap << SHIFT` 钳在 0x7FFF_FFFF。
> - `envelope_ADSR` 起音：**这里原来有个真 bug**。旧写法靠 `lvl + A_STEP < lvl`
>   判溢出，它只抓得住"绕回"（结果 ≥ 2^32）；落在 `[2^31, 2^32)` 的和判不出来，
>   而有符号 Q1.31 把 `0x8000_0000` 读成 −1.0。默认 `A_STEP = 0x0100_0000` 从 0
>   一路加上去**正好命中 0x8000_0000**，于是每次起音峰值都会打一个满幅负峰（一个
>   采样，听感是"啪"一下）。现在用 33 位和：`atk_sum[32] || atk_sum[31:0] >= 0x7FFF_FFFF`
>   就钳住并转衰减；衰减阈值也用 33 位算（`S_LEVEL` 配大了同样会绕回）。
> - `emap` 输出寄存器再加一道兜底：`lvl > 0x7FFF_FFFF` 就输出 `0x7FFF_FFFF`。
> - `tb_envelope` 盯着这条：起音全程 `emap >= 0`。
>
> 激励和包络里的采样节拍端口叫 `clk_en`（**当时钟使能用**，不是数据）：两个模块里
> 每个 `always_ff` 都必须带 `else if (clk_en)`。顺手修了两个问题：
> `envelope_ADSR` 的 `note_on_q` 原来跟着每个时钟走（`onset` 只有一拍宽，没撞上
> 节拍就丢，retrigger 时 lvl 也不会清 0），现在改成 `clk_en` 采样；`envelope_const`
> 和 ADSR 的输出寄存器原来是每个时钟都写常数值，也补上了使能。

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
  漏进来。**清空开关是外部的**（`comb_reverb.clr`）：`reverb_router` 在复位和
  `preset` 变化时给一拍，避免上一个预设的尾音串到新预设里。
  内部乘法全部做**饱和**：`(s*w)>>>27` 是 96 位乘积移位后还有 69 位，直接塞进
  64 位是截断；4 路求和、干湿相加也都用 65/68 位加法 + 饱和（以前是直接加，超了
  会回绕 → 爆音/极性翻转）。
- **排空**：`S_DONE` 要同时等 `mix_outstd`（腔体）和 `rev_outstd`（混响）归零才报 `done`，
  否则最后一帧的 `y_data` 会丢。

### 3.7 状态清零（省拍数的关键）

- **死声部**：由**包络模块自己给** `dead`（`envelope_ADSR`：松键后 release 走完、
  电平真正归零才给；`envelope_dyn0`：没按住就给；常数包络永远不给），router 只在
  `dead` 的**上升沿**清一次状态（`dead_ev → dead_f`），不是每帧都清。早先每帧清 →
  全静音时 16 个声部 × 80 模态 = 2754 拍/采样（132 MHz）。
  > 为什么不让顶层拿 `emap == 0` 猜：ADSR 从 0 起爬，起音头几个采样 `emap` 也是 0，
  > 猜"空了"就会把刚打进去的激励清掉（retrigger 的听感是"没声音"）。
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
- **写口地址 = `{sel, addr}`**：最高位 `sel` 选表（0 = 系数表，1 = 调制参数表），
  低位 `addr = {slot, mode}`。`voice_router` 直接拿 `ld_addr[CO_SLOT]` 当选择、
  `ld_addr[CO_SLOT-1:0]` 当索引 —— **地址是纯拼接，路径上没有乘法器/比较器**。
  为此每声部的模态槽数补齐到 2 的幂（`NMP = 1<<clog2(N_MODES)`，数组开
  `SLOTS*NMP`）：`N_MODES=64` 时 `NMP=64` 完全等价，非 2 的幂时多占一点 RAM 但
  地址仍然只靠移位。两张表宽度一样，都按 `N_MODES` 开（不再有单独的 `PM_MODES`，
  但是物理槽数是 `NMP`）。
  注意：flash 里仍然只存真实模态（`TBL_BYTES = N_MODES*64`），补齐只影响 RAM 寻址。

- 四线模式下一个模态 ≈ 1078 拍（`SCK_DIV=8`）：64 模态 ≈ 69k 拍 ≈ 0.8 ms @87 MHz。
- **物理层：标准四线（Quad）SPI，模式 0，命令 `0x6B`**（Fast Read Quad Output）：
  8 钟指令（只有 DQ0 出）→ 24 位地址 4 位一拍（6 钟）→ 8 钟 dummy → 之后数据 4 位
  一拍。`SCK = CLK / SCK_DIV`（`SCK_DIV` 必须 ≥ 4、取 4 的倍数，一个 SCK 的四个相位
  各占 `SCK_DIV/4` 个时钟）。
  **前提**：flash 的 QE 位（状态寄存器 2 的 bit1）必须已经置位 —— 那是一次性配置
  （烧片/上电时做），loader 不做，否则每次加载都要写状态寄存器并等 tSR（~10 ms）。
- `err` 输出：第一个字是 `FFFFFFFF` 判为没烧过。**目前没接进 `voice_router`**。

### 3.9 时序 / 面积现状（`TOP=voice_router`，N_MODES=64，含腔体+混响）

| 项 | 数值 |
|---|---|
| Fmax（100 MHz 约束） | **80.32 MHz**（slack −2.18 ns） |
| 最坏路径 | `u_rev/u_comb/c4`——混响梳状线写 RAM 的数据路径（乘法 + 65 位加 + 饱和），11.4 ns |
| Logic | 10390（7435 LUT + 2955 ALU）/138240 = 8% |
| Register | 5548 /139140 = 4% |
| BSRAM | 77 / 340（腔体历史 8 + 混响 32 + 其余 37）|
| DSP | 26 × MULT27X36 |

**满足 48 kHz**（需要 75.7 MHz），余量约 **6%**。想再多点余量就按 3.3 说的把
腔体排空从 `done` 里摘出去（省 99 拍 → 1478 拍，只要 71 MHz），或者给 eng1 的累加链
插一级寄存器。

> 饱和要放在"和"那一级，别塞在乘法后面：给 `(s*w)>>>27` 每项加 32 位比较器 + 64 位
> mux，PnR 直接从 85 掉到 57 MHz。现在的做法是每项保留 69 位、在求和/相加那一级
> **一次**饱和（比较只看高 8 位）。

腔体的历史阵列已经搬进 RAM（见 3.6b）：REG 少了 1677 个，最坏路径从腔体挪到了混响，
那一刻的 Fmax 是 85.26 MHz（腔体历史进 RAM 之后）。现在 N_MODES 提到 64、又去掉了
采样深度，最坏路径已经换成了 eng1 的累加链。

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
| `tb_voice_router.sv` | R1 钢琴+混响 NONE（body+reverb 逐位直通）、R1b 切 HALL（输出和干声不同）、R2 松键后 release 走完才归零、R3 吉他（调制器/腔体）。1 作业 = 1 采样，逐采样比对 | ✅ PASS |
| `tb_throughput.sv` | 80 模态 × 16 声部的每采样拍数（1 作业 = 1 采样，dead/live 两相）| ✅ PASS |
| `tb_loader_flash.sv` | W25Q64 行为模型 + 写口逐笔比对 + 空白片 err（表由 Python 打包）| ✅ PASS |
| `tb_reverb.sv` | NONE 逐位直通 / HALL、BATHROOM 的抽头位置与衰减（延迟线由 DUT 自己清）| ✅ PASS |
| `tb_excitation.sv` | 脉冲串：1 脉冲 / N=2 三脉冲 / N=7 持续 / clear / 声部独立 | ✅ PASS |
| `tb_envelope.sv` | 定点边界：起音不许翻负（A_STEP 正好命中 0x8000_0000）、dyn0 的 `fmap<<SHIFT` 越界钳位、`dead` 只在 release 走完才给 | ✅ PASS |
| `tb_modulation.sv` | 调制器递推 | ✅ PASS |
| `tb_eng1_g.sv` | ABC 引擎 golden 值；**另外验证 `st_zero` 对每个模态都生效**（历史灌非零、清零后 y 必须回 0），以及不清零时历史确实参与运算 | ✅ PASS |
| `tb_fmax_router.sv` | 探针顶层冒烟（打印 y_valid 脉冲数/状态，无 PASS 判据）| ⚠️ 仅冒烟 |

---

## 6. 待实现 / 待测试

### 6.1 必需（要出声/上板前）

0. **吉他 16 键齐按的首帧会掉音**（实测）：`modulation0` 是**单乘法器串行**的
   （每模态 15 步 × 约 3 拍），一个声部 = `n_modes × 46` 拍。钢琴 80 模态 × 16 声部
   同时起音 = 16 × 3680 ≈ **60k 拍 ≈ 29 个采样周期**（`tb_throughput` 的 `gtr-mod`
   相位实测 71413 拍 / 8 作业，首帧 ~60k）。稳态没这问题（1577 拍）。
   修法：调制器并行化（15 步并行 = ~1 拍/模态 → 16 声部约 1.3k 拍，能进一帧），
   或者把调制挪到后台、算完安全提交系数（原报告 F07 的做法）。
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
9. **eng1 的累加链**：现在全设计的最坏路径（−2.82 ns）。它只在 CELESTA/PAD 上用，
但照样占着时序；中间插一级寄存器能把它换出关键路径。
10. **多声部混音的 64 位溢出**：16 个声部满量程理论上会回绕（实际信号远不到），
    要保险就加宽到 68 位再饱和。

### 6.3 已验证但值得再收紧的

11. **`tb_voice_router` 里 R3（吉他）几乎没声音**：`ymax` 只有钢琴的 1/100，是 tb 里造的那套
    合成调制参数（`pm_*`）把模态压死了。跟腔体无关，但"吉他真的能响"还没被验证过。
12. **模块名/端口一致性**：`rtl/core/post_chain.sv`（队友那版）还在按**老的 6 端口**
    `comb_reverb` 和 **ROM 版** `body_biquad` 实例化，跟 `rtl/router/parts/` 不是一套，
    谁拿它当 top 编会直接端口不匹配。
13. **本轮对照 handoff 修的几处**（都已验证）：
    - `eng1` 的乘法原来用 `y1_cur/y2_cur`（S_MUL 同拍被更新 → 非阻塞下看到的是**上一个
      模态**的状态），整条历史错位一个模态；现在直接用这一拍同步读回来的 `st_q/st_qdot`
      （清零时按 0）。`tb_eng1_g` 加了原报告的复现：[10,20,30] → [-10,-20,-30]。
    - `eng1` 的 `nmod_lat` 用模态**索引**位宽，64 模态时截成 0（整个作业空转）；改成
      `[IW:0]`。TB 加了 64 模态用例（y 必须是 64）。
    - 激励的 `clear` 原来只在 `clk_en` 上采，上层给的一拍脉冲会漏；现在挂起等节拍消费。
    - debug 读被引擎占用时不再报 `ns_rd_valid`。
    - 系数/状态/参数表的地址统一成 `slot*N_MODES + mode`（显式乘，不再靠 `{slot,mode}`
      拼接，N_MODES 不是 2 的幂时会错位）。
    - 引擎喂锁存后的 `n_modes`（和调制器一致）；loader 的 `wait_cnt` 位宽按终值开。
    - `tb_reverb` 加了"延迟线灌非零后再切 HALL"和"±2^40 大值 NONE 直通"两个用例。
14. **混响延迟线清空**：复位后靠"清空标志 + 读作 0"（跑满 N 个采样自动落），
    所以上电后**头 N 个（2048）采样只有干声**，没有湿声。这是有意的，不是 bug。
14. **`envelope_ADSR` 没有 release 段**：`!gate` 直接归零，松键是硬切（会咔哒）。原来就这样。

### 6.4 已知的设计选择（不是 bug）

- **加载阻塞**：`S_LOAD` 等 `ld_done`，这段时间 `fmap` 冻结、不出 `y_valid`，
  上层看到的就是"静音 + not ready"。换乐器头 1~2 ms 没声音，是有意省逻辑。
- **腔体只在换乐器时清历史**：起音不清，所以上一音的腔体尾音会跟着新音一起出来
  （起音清会把它切掉，听感更"干净"但丢尾巴；现在选的是保留）。
- **`fmap_q` 打一拍、`note_on` 打一拍**：都是为了切断长组合链，晚一拍不影响功能。
- **"空了"由包络定义，不是由 emap==0 定义**（见 3.7）：ADSR 走完 release 才给
  `dead`，dyn0 没按住就给。这样起音阶段不会被误判成"空"。

---

## 7. 想法池（只记录，未实现）

### 7.1 双 `voice_router` 薄外壳 —— 不同乐器并行

不在 `voice_router` 里改任何东西，在它上面套一层很薄的 `router_pair`：

```
fmap ──┬─► voice_router #0  (inst=A, preset=X)  ──┐
       └─► voice_router #1  (inst=B, preset=Y)  ──┴─► Σ（64 位饱和）──► y_data
```

- 每个 router 带自己那 16 个声部的全部存储（系数/状态/引擎/后级），互不相干；
  "不同引擎"自然成立——A 的乐器走 eng0、B 的走 eng1，各自由 `eng_sel` 决定。
- **flash**：每个 `weight_loader` 本来就按 `inst` 算基址，两个 router 给不同 `inst`
  就是不同地址；想**同一个乐器同时加载两份**，在镜像里再放一份表即可
  （8 MB 片子里 5 个乐器 × 80 模态 × 64 B 才 25 KB，放十份也无所谓）。
  两个 loader 共用一条 QSPI → **加载串行化**（薄外壳排队发 `reload`），省掉总线仲裁。
- **资源**大致翻倍：Logic ~2×10186、REG ~2×4555、BSRAM ~2×79 = 158/340，装得下。
  每个 router 的每采样拍数不变（1577），因为是**真并行**，采样周期不动。
- 还没定 / 要小心：
  1. **两路 `y_valid` 求和对齐**：同拍启动就基本对齐，但一边先 `done`（声部全灭）
     时只剩一路。要么强制同步启动/停止，要么在薄外壳里加个 1~2 深的对齐 FIFO。
  2. **声部怎么分**：fmap 是 16 路，薄外壳得决定哪些槽位给 A、哪些给 B
     （简单：0..7 → A、8..15 → B；或者按"谁空闲"动态分配）。
  3. **混响只在薄外壳里放一份**（推荐）：两个 router 的 `reverb_preset` 都给
     `REVERB_NONE`（此时是 6 拍逐位直通的延迟），在薄外壳里"先求和、再串一个
     `reverb_router`"——两个乐器同一个房间，听感反而更自然，还省掉 32 个 BSRAM
     和每个 router 一份的干湿混合。
  4. 面积翻倍后 Fmax 会不会掉得实测（现在 78.06 MHz / 余量只有 3%）。

### 7.2 同种引擎并行（每引擎 8 声部）

- 目标**不是** Fmax（并行不改关键路径），而是把每采样拍数砍半：
  `18 + 16×(n_modes+11)` = 1474 → `18 + 8×(n_modes+8) + 16×3` ≈ **782 拍**
  → 48 kHz 只要 **37.5 MHz**（现在要 75.7）。同样 78 MHz 下模态上限 80 → ~150。
- 代价：`eng0` 单独综合 = 811 LUT + 503 ALU + 541 FF + 14 DSP，再放一份约
  +1314 LUT/ALU、+541 FF、+14 DSP（约当前总量的 13%）。
- 关键实现点：**存储按声部切 bank**（`[N_MODES × 16]` → 两个 `[N_MODES × 8]`），
  总 bit 数不变、BSRAM 数量基本不变，等于凭空多一套端口；调度器改成两引擎同步跑，
  包络/累加先串行（只占 6%）。
- `eng1` 时序比 `eng0` 差，真要复制先用 `eng0`。

### 7.3 想要 100 MHz 的话（按收益排序）

1. `comb_reverb` 写 RAM 那段（现在 −1.73 ns）：把"加 + 饱和"和"写 RAM"拆成两级。
2. 包络的 64×32 乘法（之前 −1.68 ns）：拆成两级流水。
3. `eng1` 的累加链（−1.4 ns 左右）。

---

## 8. 相关文档

- `rtl/simsynth/ROUTER.md`（已删）—— 旧版路由器的结构/时序分析，在 git 历史里：
  `git show 9c64f6de:rtl/simsynth/ROUTER.md`；引擎那部分还有参考价值
- `rtl/math/pkg/fxp_pkg.sv` —— 定点函数（`fx_shift_rnd` / `fx_sat` …），注释里写了 Gowin 的限制
- `docs/ENGINE_INTERNAL.md` —— 引擎内部递推的推导
