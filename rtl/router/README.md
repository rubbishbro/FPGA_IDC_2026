# Router —— 物理模型合成器的数字后端

一块 FPGA 上的 16 声部模态（modal）合成器：**16 个声部 × N_MODES 个模态**，每个模态一个
二阶谐振器，逐采样递推；后级接腔体（body）滤波和 4 路梳状混响；系数从 W25Q64 flash
按乐器加载。

- 采样率 48 kHz，目标主频 100 MHz（实测可跑到 87 MHz），**每采样 865 拍**。
- 两套引擎：`eng0`（7 个并行乘法的直接型，钢琴/马林巴/电钢）和 `eng1`（ABC 递推，
  吉他/贝斯/颤音琴）。同一时刻只用一种，但**两个引擎实例各管 8 个声部并行跑**。

本文档按"结构 → 约定 → 取舍 → 现状 → 测试 → 待定"组织。想改代码先看 §4（约定）和
§5（取舍），那里写了"为什么不能那样改"。

---

## 1. 概览

```
                        ┌──────────────── 一个采样（865 拍）──────────────┐
 fmap[16]  ──滞回──► note_on ──┬─► excitation_gen ─► xmap ─► x_q ─┐
 (0..255 力度)                 │                                  ├─► eng A (声部 0..7)  ─┐
                               └─► envelope(ADSR/dyn0) ─► emap ──┐ │                        ├─► y_acc ─► mix
                                            │                   │ └─► eng B (声部 8..15) ─┘   (每声部乘自己的包络再累加)
                                            └─► dead ─► 状态清零 │
                                                                └──► 每声部 y×emap
   inst ──► loader(W25Q64) ──► 系数表 / 调制参数表（RAM）
   inst ──► modulation0（后台）──► 改写系数表 a11/a12/a21/a22

 mix ─► body_router（腔体，5 段 Q4.27 biquad）─► reverb_router（4 路梳状）─► y_data
```

---

## 2. 目录结构

```
rtl/router/
├── voice_router.sv          ★顶层：存储（双 bank）+ 两个引擎 + 调度 FSM + 后级链
├── loader.sv                weight_loader：W25Q64 四线 SPI 读 + 记录装配 + 写口
├── fmax_router.sv           时序/面积探针（clk/rst_n/led），给 PnR 用的薄外壳
├── voice_router.sdc/.cst    时序约束 / 管脚（cst 故意没有 IO_LOC，见 §8）
├── synth_pnr_router.tcl     综合 + PnR 脚本（TOP=voice_router）
├── syn_only.tcl             只综合
├── pkg/
│   ├── modal_step_pkg.sv    ★位宽/定点契约：coeff_t、QW/VW/XW/YW、饱和
│   └── router_pkg.sv        instrument_e / reverb_preset / mod_par_t / eng_sel()
├── engines/
│   ├── eng0.sv              7 乘法并行引擎（直接型，一个模态 5 级流水）
│   └── eng1.sv              ABC 引擎（acc = G*x - a1*y1 - a2*y2）
├── routers/
│   ├── eng_router.sv        双引擎薄封装（按乐器二选一），两个实例各管 8 个声部
│   ├── env_router.sv        按乐器选包络（ADSR / dyn0 / 常数 1.0）
│   ├── exc_router.sv        按乐器选激励参数（脉冲数/宽度/间隔）
│   ├── mod_router.sv        只有吉他/贝斯才启用 modulation0
│   ├── body_router.sv       按乐器选 25 个腔体系数（5 段 × 5 抽头）
│   └── reverb_router.sv     预设（NONE/HALL/BATHROOM）+ 干湿混合
├── parts/
│   ├── envelope.sv          envelope_ADSR / envelope_dyn0（都输出 dead）
│   ├── excitation.sv        excitation_gen：N+1 个脉冲的锯齿串（可无限）
│   ├── modulation.sv        modulation0：alpha/揉弦改系数（单乘法器串行 15 步）
│   ├── body_biquad.sv       5 段 biquad，历史存 BSRAM
│   └── comb_reverb.sv       4 路并联梳状线（读作零的清空）
├── tb/                      所有 testbench（见 §7）
└── tools/
    ├── flash_image.py       flash 镜像打包（record/table/image/parse + 自检）
    ├── bq_gen.py            腔体系数对账 + 生成回归向量
    ├── run_bq.ps1           腔体回归一键跑
    ├── run_flash.ps1        加载器回归一键跑
    ├── run_all.ps1          **全部回归一键跑**（编译一次 + 逐个跑 + 汇总）
    ├── golden_seq_piano.txt 4 个真实钢琴模态的系数（TB 用）
    └── bq_*.mem / flash_demo.mem  回归向量 / 镜像（生成物，可重跑生成）
```

依赖方向：`voice_router` → `routers/*` → `parts/*` → `pkg/*`。
`parts/*` 之间**没有**横向依赖，只有 `pkg`。

---

## 3. 架构与模块关系

### 3.1 层次

```
voice_router                      存储 + 调度 + 后级
├── weight_loader                 ① 系数/参数加载（阻塞 ~6.5 ms/次）
├── exc_router ──► excitation_gen ② 激励 xmap
├── env_router ──► envelope_*     ③ 包络 emap + dead
├── mod_router ──► modulation0    ④ 后台改系数（a11/a12/a21/a22）
├── eng_router (A) ──► eng0|eng1  ⑤ 声部 0..7   → bank A
├── eng_router (B) ──► eng0|eng1  ⑤'声部 8..15  → bank B
├── body_router ──► body_biquad   ⑥ 腔体
└── reverb_router ──► comb_reverb ⑦ 混响
```

### 3.2 模块职责与接口

| 模块 | 职责 | 关键接口 | 周期/延迟 |
|---|---|---|---|
| `voice_router` | 存储、调度、混音 | `start/ready/busy/done`、`fmap[16]`、`inst`、`reverb_preset`、`n_modes`、`reload`、`y_valid/y_data`、`ns_rd_*`(debug) | 865 拍/采样 |
| `voice_router` | **声部数是参数 `SLOTS`**（不是端口） | `SLOTS` 必须是 2 的幂 | — |
| `weight_loader` | 四线 SPI 读 + 写口 | `start/busy/done/err`、`ld_we/ld_addr/ld_co/ld_pm`、`qspi_*` | ~520 拍/记录 |
| `eng0` | 直接型引擎：`y = Σ (coef × 状态)` | `co_re/co_addr/co_data`、`st_re/st_addr/st_q/st_qdot`、`st_we/...`、`x_re/x_data` | 每模态 5 级流水，N+8 拍/作业 |
| `eng1` | ABC 引擎：`y = clamp((G*x - a1*y1 - a2*y2)>>24)` | 同上 | 每模态 ~5 拍 |
| `eng_router` | 按 `inst` 在 eng0/eng1 间二选一 | 作业口 + 一套存储口 | 无额外延迟 |
| `envelope_ADSR` | A/D/S/R + `dead` | `A_STEP/D_STEP/S_LEVEL/R_STEP`、`emap`、`dead` | 每采样 |
| `envelope_dyn0` | `emap = fmap<<SHIFT`（钳位）、`dead = ~gate` | 同上 | 每采样 |
| `excitation_gen` | N+1 个脉冲串 / 无限 | `PW_LEN/GAP_LEN/N_PULSE/clear`、`xmap/xmap_valid` | 每采样 |
| `modulation0` | alpha/揉弦改系数 | `start/busy/done`、`p_*`(参数读)、`co_we/co_mode/co_wdata` | 15 步/模态，单乘法器 |
| `body_biquad` | 5 段 biquad | `in_valid/in_ready/x`、`out_valid/y`、`clr` | 93 拍/样本 |
| `comb_reverb` | 4 路梳状 | `in_valid/x`、`out_valid/y`、`clr` | 4 拍 + 2 拍混合 |

### 3.3 一次采样的调度（`voice_router` FSM）

```
S_IDLE ──start──► (换乐器/reload? S_LOAD : S_RUN_X)
S_LOAD  ──ld_done──► S_RUN_X
S_RUN_X ──xmap_valid──► S_XS      （等激励发生器出一个采样；xmap 整张打进 x_q）
S_XS    ─────────────► S_RUN_V    （g=0，两个引擎同时 start）
S_RUN_V ──era_yv&&erb_yv──► S_ENVMUL   （取 A 声部的 y 和 emap[g]）
S_ENVMUL/S_ENVACC ─► S_ADV        （乘 → 累加）
S_ADV   ──还有 B?──► S_ENVMUL（pick_b=1，同一套流水再算一次）
        ──这组完了──► g++ → S_RUN_V
        ──全部声部完──► mix_v=1 → S_DONE
S_DONE  ──腔体+混响排空──► S_IDLE（done）
```

拍数：`2 + np_lat×(N_MODES+8 + 6) + 收尾`。`np_lat = min(n_voices, SLOTS/2)`，
N_MODES=64 时 = 8×(72+6)+固定 ≈ **865 拍**。

---

## 4. 约定（改之前必须知道）

### 4.1 地址

**RAM（系数表 / 状态 / 调制参数）**

```
addr = slot * NMP + mode          NMP = 1 << clog2(N_MODES)   // 补齐到 2 的幂
系数表、状态、参数表**深度都是 SLOTS*NMP**，三张表地址完全一样。
```

- 补齐的意义：地址退化成 `{slot, mode}` 的**纯拼接**（移位），地址路径上不放乘法器/比较器。
  `N_MODES=64` 时 `NMP=64` 和地址 = `slot*64+mode` 完全等价；非 2 的幂（如 48）时多占 33% RAM，但不会错位。
- 引擎读的 9 个阵列按声部分成 **A/B 两个 bank**（`slot < HS` → A），bank 内地址 =
  `{slot[HVW-1:0], mode}`。**两个引擎同拍读不同地址 = 2R1W**，一块 BSRAM 只有两个端口，所以必须拆 bank。
- `pm_*` 参数表**不拆**：引擎不读，只有 `modulation0` 读、loader 写。

**写口（loader / 调制器 → RAM）**

```
ld_addr = {sel, slot, mode}      sel = 1 表示写调制参数表，0 表示写系数表
```

`voice_router` 直接 `ld_sel_pm = ld_addr[CO_SLOT]`、`ld_idx = ld_addr[CO_SLOT-1:0]`。

**flash**

```
base = inst * TABLE_BYTES        TABLE_BYTES = SLOTS * N_MODES * 64
记录顺序 = RAM 地址顺序（slot-major）：slot 0 的 N_MODES 条，然后 slot 1 ...
第 (slot, mode) 条记录 64 字节（大端 signed 32-bit）：
  +0  a11   +4  a12   +8  a21   +12 a22
  +16 gq    +20 gv    +24 wo    +28 保留(0)
  +32 c0    +36 s0    +40 gam   +44 theta0
  +48 g     +52 k12   +56 k21   +60 保留(0)
```

**每个声部一张表**（loader 一对一写，不复制）。想给 16 个声部不同音高，就在 flash 里
预先排好 16 张表。

### 4.2 位宽与定点（各处不同，别串）

| 位置 | 格式 | 位宽 | 说明 |
|---|---|---|---|
| `emap`（包络） | **Q1.31 有符号** | 32 | 1.0 = 2^31−1；乘法用 `(y*E)>>>31` |
| `xmap`（激励） | 力度 << SHIFT | 32 | SHIFT 由乐器给，最大 255<<20 < 2^31 |
| `coeff_t.a11/a12/a21/a22/gq/gv/wo` | 见 `modal_step_pkg` | 32 | 引擎内部按自己的 Q 解释（eng1：G Q2.24、a1 Q2.20、a2 UQ0.24） |
| `q_ram/v_ram`（状态） | Q2.30 有符号 | 32 | eng1 的 y1/y2 |
| 腔体系数 | **Q4.27** | 32 | 5 段 × 5 抽头 |
| 混响增益/延迟 | **Q4.27** | 32 | 延迟单位 = 采样点 |
| `mix`/`y_acc` | 有符号 | 64 | 跨声部累加 |
| `y_data` | 有符号 | 64 | 后级全 64 位，进 WAV 前再归一化 |

有符号钳位一律**看符号位**，不要用"比较上限"（见 §9 起音那个坑）。

### 4.3 时序约定

- **RAM 读都是"地址这拍给、数据下一拍有效"**（同步读）。引擎按这个写，router 侧
  一律 `if (xx_re) r <= mem[addr];`。
- **BSRAM 推断要求**：一个阵列只能有**一个读口 + 一个写口**，读地址/写地址/写数据
  都必须是寄存器（或寄存器 + 简单 mux）。多一个读口（哪怕只给 debug）就会退化成
  寄存器阵列（实测 REG 5.5k → 72k，PnR 卡死）。
- `clk_en`（采样节拍）在 `envelope_*`/`excitation_gen` 里当**时钟使能**用，不是数据。
- `valid/ready` 只在腔体那一段用反压（`mix_v` + `body_accept`），其它地方是固定延迟：
  混响 6 拍（梳状 4 + 混合 2）→ `y_valid` 比 `mix_v` 晚 6+93 拍。
- `done` 要等腔体和混响**都排空**（`mix_outstd/rev_outstd`），否则最后一帧会丢。

### 4.4 事件语义

| 信号 | 语义 | 谁产生 |
|---|---|---|
| `fmap[i]` | 力度 0..255（0 = 松键） | 外部（压力传感器） |
| `note_on[i]` | **滞回门控电平**：按下 >2、松开 <1，不是脉冲 | `voice_router`（打一拍输出） |
| `note_ev/note_f` | 起音沿 / 攒到帧头的那份 | 各消费模块自己取（`excitation_gen`、`envelope_*` 内部各有一份） |
| `dead[i]` | 这个声部**真的空了**：ADSR 走完 release 才给；dyn0 没按住就给 | `envelope_*` |
| `clear` | 换乐器：清激励状态机 / 腔体历史 | `voice_router`（`inst != inst_prev`） |
| `mod_req[i]` | 后台调制请求位图 | `voice_router`，`modulation0` 空闲时按最低位服务 |
| `reload` | 强制重灌系数（不清状态） | 外部 |
| `input_hold` | 加载期间冻结 `fmap_q`（= 忽略输入） | `voice_router` |

**为什么要 `dead` 而不是拿 `emap==0` 判断**：ADSR 从 0 起爬，起音头几个采样 `emap` 也是 0；
用它判断"空了"会把刚打进去的激励清掉（听感 = 没声音）。

---

## 5. 设计取舍（为什么这样 + 代价）

### 5.1 两个引擎并行 + 双 bank —— 1577 → 865 拍

- **做法**：`voice_router` 实例化两个 `eng_router`，各管 `SLOTS/2 = 8` 个声部；一次作业
  跑 8 组，每组两个声部同时起算，等两个 `y_valid` 都到齐后**复用同一套**包络乘/累加
  流水串行算两次。
- **为什么必须拆 bank**：两个引擎同拍读不同地址 = 2R1W = 三个端口，BSRAM 只有两个。
  拆分后每 bank 512 字 × 32 位正好一块 512×36。
- **代价**：引擎逻辑翻倍（Logic 10.5k → 12.5k，LUT 7.6k → 8.8k）；地址要按声部分 bank
  （`slot[VWID-1]` 选 bank）。
- **没选"复制阵列"**：那要多 32 块 BSRAM。

### 5.2 调制放后台 —— 首帧不再掉音

- **做法**：起音声部只置一个 `mod_req[i]`，`S_RUN_V` 不停等；调制器空闲且不在加载时
  发一拍 `start`，`done` 时清那一位。
- **为什么能并行**：调制器写系数用 `ca_*` 的**写口**，引擎读系数用**读口**，同一块
  1R1W RAM 的两个端口；而且 `co_we=4'b1111` 是**一拍写齐 4 个字段**，引擎不会读到
  半新半旧的系数。新系数下一帧生效（20.8 µs，vibrato 听不出）。
- **为什么用位图**：单个"待处理"寄存器会被同帧第二个起音冲掉；位图谁请求都不丢。
- **为什么不用"15 步并行"**：那要再加 15 个乘法器；串行 + 后台已经把 60k 拍的首帧尖峰
  摊到 ~38 帧里，实测吉他 16 键齐按从 71413 拍/8 作业降到 12616。
- **代价**：调制器是幂等的（无跨轮状态），所以重复请求只是白花拍数；`mod_req` 排空
  需要几十帧（`tb_voice_router` 的 R3c 专门盯这个，防止"不挡引擎"变成"永远不算"）。

### 5.3 状态清零用"读作零"，不是"清一遍"

- **做法**：`st_zero` 时引擎把读回来的状态当 0 用（`q_eff = zero_job ? 0 : st_q`），
  照样写回新值。
- **为什么**：清零 pass 要 N_MODES 拍 × 声部。全静音时每帧都清 = 16×80 拍（132 MHz）。
  只在"刚起音/刚空了"那一帧清一次，而且用读作零，一个额外周期都不花。
- **代价**：状态 RAM 里的旧值不会真的被抹掉（无所谓，读的时候屏蔽）。

### 5.4 腔体历史进 RAM

- 5 段 × 5 抽头的历史是 272 位/样本。放寄存器（REG 3262、一个 BSRAM 都不出）放不下。
- **关键坑**：综合器只认"地址寄存器 + 输出寄存器"的 RAM 形状。直接写
  `h_rd <= hist[sec+1]`（组合地址）会被打回寄存器阵列；把读地址先打进 `raddr`、
  再 `h_rd <= hist[raddr]`，立刻变成 REG 617 / BSRAM 8。
- **代价**：93 拍/样本（含 RAM 延迟），比组合读多几拍；用 `in_ready` 反压。

### 5.5 混响：清空外置 + 求和处饱和

- **清空**：延迟线复位**不写 0**，而是挂"清空中"标志、期间**读作 0**（回写照常写新数据），
  跑满 N=2048 个采样后自动落。既不空转 2048 拍，也不会把 BSRAM 上电随机值放出来。
  `clr` 由 `reverb_router` 在**切预设时**给（外部控制），所以 NONE→HALL 不会读到
  没写过的区域。
- **饱和**：梳状反馈的乘法保留 69 位，只在 4 路求和处做一次饱和；写 RAM 的数据先打
  寄存器（`wd`），**不能**让"65 位加 + 饱和 mux"直接怼 RAM 的 D 口（实测那条路 13.8 ns，
  72 MHz）。干湿相加也在 add 阶段饱和。
- **代价**：延迟 6 拍；饱和点只有两处（求和、相加），不会逐级截断。

### 5.6 包络/激励的采样节拍用 `clk_en`

- 不用 `CLK_HZ/SR_HZ` 分频器各自分频（会漂），统一由 router 给 `smp_tick`，包络/激励
  当**时钟使能**用。
- 事件（`clear`/起始沿）只在节拍上被消费，所以 `clear` 要**挂起**等节拍（否则一拍脉冲会漏）。
- 包络/激励内部的 `onset` 也是在 `clk_en` 上采（电平保持一个节拍）。

### 5.7 加载是阻塞的

- 换乐器 → 停帧 → 重灌 → 继续。一次 64 KB（16 声部 × 64 模态 × 64 字节）：
  `tb_voice_router` 的 R5 实测 **526 994 拍 ≈ 5.3 ms**（`SCK_DIV=4`，四线模式）。
  换句话说：**中途 reload 会丢掉约 250 个采样**，所以才有"等键全松再 reload"的策略问题（§8.2）。
- **代价**：切换乐器时 6.5 ms 断音。要更快只能改 PHY（现在 4 拍/SCK，四线 20 MHz）。
- Quad 模式要求 flash 的 **QE 位**已置位（状态寄存器 2 bit1）——一次性配置，loader 不做
  （否则每次加载都要写状态寄存器 + 等 tSR ~10 ms）。

---

## 6. 现状数据

`TOP=voice_router`，`N_MODES=64`，`SLOTS=16`，含腔体 + 混响：

| 项 | 数值 |
|---|---|
| 每采样 | **865 拍**（48 kHz 只要 **41.5 MHz**） |
| Fmax（100 MHz 约束） | **85.44 MHz**（slack −1.7 ns），48 kHz 余量 2 倍 |
| Logic / Register / BSRAM | 10433（6787 LUT + 3646 ALU）/ 138240 = 8%；Register 5086 / 139140 = 4%；BSRAM **66** / 340 = 20% |
| 关键路径 | 混响梳状写 RAM / 干湿相加（约 −1.4 ns） |

瓶颈的顺序：混响（`u_rev`）> eng1 累加链 > eng0。要冲 100 MHz 按这个顺序拆。

---

## 7. 测试

### 7.1 怎么跑

都在仓根目录跑（TBs 在 `rtl/router/tb/`，读的向量文件路径相对仓根）：

```powershell
$env:PATH = "E:\Xilinx\Vivado\2017.4\bin;" + $env:PATH
xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/drivers/pkg/clk_rst_pkg.sv ^
          rtl/drivers/pkg/pad_driver_pkg.sv rtl/router/pkg/modal_step_pkg.sv ^
          rtl/router/pkg/router_pkg.sv rtl/router/parts/*.sv rtl/router/engines/*.sv ^
          rtl/router/routers/*.sv rtl/router/loader.sv rtl/router/voice_router.sv ^
          rtl/router/tb/tb_voice_router.sv
xelab tb_voice_router -s tbv_body --debug typical -timescale 1ns/1ps
xsim tbv_body --runall
```

一键脚本：

```powershell
pwsh -File rtl/router/tools/run_all.ps1              # 全部（编译一次，逐个跑，出汇总）
pwsh -File rtl/router/tools/run_all.ps1 -SkipMusic    # 跳过 1 秒音频渲染
pwsh -File rtl/router/tools/run_all.ps1 -Only tb_reverb
pwsh -File rtl/router/tools/run_bq.ps1                # 腔体（会重跑 Python 生成向量）
pwsh -File rtl/router/tools/run_flash.ps1             # 加载器（会重跑 Python 打包）
```

### 7.2 清单与覆盖

| TB | 覆盖什么 | 结果 |
|---|---|---|
| `tb_voice_router.sv` | R1 钢琴+混响 NONE（body+混响逐位直通）、R1b 切 HALL（输出和干声不同）、R2 松键后 release 走完状态归零、R3 吉他（调制器+腔体）、R3c 后台调制队列排空、R5 reload 重灌（有限等待 80 万拍，实测 527k 拍完成）| ✅ PASS |
| `tb_throughput.sv` | 80 模态 × 16 声部的每采样拍数（dead/live/gtr-on/gtr-ss/gtr-mod 五个相位）| ✅ 865 拍 |
| `tb_reverb.sv` | NONE 逐位直通、**±2^40 大值直通**、延迟线灌非零后切 HALL、HALL/BATH 尾/中比、清空 | ✅ PASS |
| `tb_excitation.sv` | 单脉冲 / 三脉冲 / N=7 持续 / burst 中途 clear / 声部独立 / **非节拍 clear（挂起）** | ✅ PASS |
| `tb_envelope.sv` | 起音不翻负（`A_STEP` 正好命中 0x8000_0000）、`dead` 只在 release 走完给、dyn0 钳位 | ✅ PASS |
| `tb_modulation.sv` | 两个 fmap 下的 a11/a12/a21/a22 数值（相对误差 <1e-3）、门控模态、**fmap=0 一笔都不写** | ✅ PASS |
| `tb_eng1_g.sv` | eng1 golden 值、`st_zero` 覆盖所有模态、状态不错位一个模态、满 64 模态（`nmod_lat` 位宽） | ✅ PASS |
| `tb_loader_flash.sv` | W25Q64 四线行为模型 + 写口逐笔比对 + 空白片 `err` | ✅ PASS |
| `tb_body_biquad.sv` | 腔体直通/单段/5 段，逐样本对 Python 模型 | ✅ PASS |
| `tb_music.sv` | **不是自检**：渲染 1 秒音频到 WAV（见 7.3） | — |
| `tb_fmax_router.sv` | 面积/时序探针（`fmax_router` 外壳） | — |

**已知没覆盖**（见 §8）：
- `DEBUG_PORT` 读口（TB 里 `ns_rd_en` 恒 0）。
- `eng0` 没有独立的 golden 值测试（只在 `tb_voice_router` 里端到端跑）。
- 少于 `SLOTS` 个声部的配置（`n_voices` 端口已删，要少声部就改 `SLOTS` 参数）。

### 7.3 渲染音频

```powershell
xelab tb_music -s tb_mu --debug typical -timescale 1ns/1ps -generic_top "NSAMP=48000"
xsim tb_mu --runall
python _analysis/dec2wav.py _analysis/music_dec.txt _analysis/music.wav 48000
```

- `NSAMP` 是采样数（48000 = 1 秒），`NPER` 是触键间隔（采样数）。
- `CLK_HZ=48 MHz`（1000 拍/采样；一次作业 865 拍，留 135 拍余量）。
- 实测：1 秒音频 **231 秒**（约 12 万拍/秒的仿真速度）。100 MHz/48 kHz 配置要 ~2 倍。
- 用 `tools/golden_seq_piano.txt` 的 4 个真实模态；现在灌给全部 16 个声部，所以是
  "同一音高的节奏"。要出旋律得在 flash 里给 16 个 slot 预置不同音高的表（§4.1 已支持）。

---

## 8. 待确定项 / 已知问题

1. ~~`n_voices < SLOTS/2` 会挂~~ **已解决**：`n_voices` 端口删掉了，声部数 = `SLOTS`
   参数（必须是 2 的幂）。少声部就改参数重新综合。顺带省了 2k LUT / 1.3k REG。
2. ~~`reload` 会挂~~ **不是 bug**：实测 reload = 完整重灌 527k 拍 ≈ **5.3 ms**（≈250 个
   采样被丢掉）。前面以为"挂了"是我自己的 20 ms 看门狗到点了，不是 FSM 卡住。
   **待定的是策略**：建议改成"等所有键松开（`note_on == 0`）才真正重灌"，
   - gate 只对 `change_pend = (inst != inst_prev) || reload` 生效，否则按着键就再也不接帧；
   - 锁住期间 `ready=0`（主机才知道暂时不接 `start`），`fmap` 照常采（否则看不到松键）；
   - `inst_lat` 的锁存仍在 `S_IDLE`（和 load 同时切，各 part 与 RAM 内容始终一致）；
   - 纯 `reload`（乐器没变）建议也清一次激励/腔体，重启更确定；
   - 键一直按着 → 变更永不生效，这条要写进接口文档。
3. **`loader.err` 没接进 `S_LOAD`**：加载失败（没烧过）会当成功用，输出静音。策略待定
   （重试？报警？保持静音？）。
4. **`n_voices`/`n_modes` 是外部输入**：现在引擎和调制器都用 `start` 时锁存的那份，
   但 `tb_throughput` 用 `N_MODES=80` 而系数表只有 64 个模式——语义上应该限幅到
   `N_MODES`。
5. **`DEBUG_PORT` 现在只吐"最近一次引擎读到的状态字"**（不能任意地址读），因为没有
   多余的 RAM 读口。要真调试得在外面加 ILA，或者接受多一块 RAM 复制的代价。
6. **`eng0` 缺独立的 golden 值测试**（用 Python 模型逐样本对比），现在只有端到端。
7. **音高**：flash 已支持每声部一张表（§4.1），但还没有生成 16 个音高系数表的流程
   （需要 Python 模型批量算 → `flash_image.py` 打包）。
8. **`voice_router.cst` 故意没有 `IO_LOC`**：P16/R15 在 GW5AST-LV138FPG676AES 上无效
   （PR2017/PR2028），要上板得按实际板子补。
9. 想冲 100 MHz：混响写 RAM 已拆两级，下一个是干湿相加（`u_rev/y_63`）和 eng1 累加链。

---

## 9. 踩过的坑（速查）

1. **BSRAM 推断**要"一个读口 + 一个写口 + 地址寄存器"。多一个读口（哪怕 debug）就退化成
   FF：REG 5.5k → 72k，PnR 在 placement 卡半小时以上。
2. **`$signed` 在 PowerShell 里会被吃掉**：`` `$clog2 ``、`$signed` 写在双引号里会被当变量
   展开成空，生成出 `localparam int HVW = (HS);` 这种代码——表现为地址多出几位、越界读 X。
   改 RTL 一律用编辑器/单引号。
3. **包络起音钳位**不能靠"无符号绕回"判断：`lvl + A_STEP < lvl` 只抓得住 ≥2^32，而默认
   `A_STEP=0x0100_0000` 正好落到 `0x8000_0000`，按 Q1.31 读就是 −1.0（每个起音一个负峰）。
   要**看符号位**：`($signed(lvl)+$signed(step)) < 0`。
4. **状态清零**只掩第一个模态是不够的（eng1 的 `first_done` 条件）：所有模态都要读作零，
   否则 note-on 后旧谐振还在。
5. **多驱动**：两个引擎的输出不能接到同一个端口（`st_q_wdata` 等），要先各自出一份再 mux。
6. **同一拍赋值 + 使用**：`S_MUL` 里既更新 `y1_cur` 又用它参与乘法 → 非阻塞下乘法看到
   的是**上一个模态**的状态，整条历史错位。
7. **`note_on` 是电平不是脉冲**：谁要沿谁自己取（各模块各有一份 prev 寄存器）。
8. **xsim 的怪癖**：`wire x = expr;` 的初始化不生效；`logic signed [3:0][31:0]` 打包数组
   端口会给 X（改标量端口）；`string` 拼接在 task 里会崩（用 `$write` 循环）；同拍改
   激励要打在 `negedge`，否则会盖住被测信号。
9. **`git add -u` 不会加新文件**，但 index 里已有的会被带进提交——提交前看 `git status`。

---

## 10. 相关文档

- `_analysis/ROUTER_AUTHOR_HANDOFF.md`：外部审阅给的 F01–F11 问题清单（已逐条处理，
  处理结论见 git log 和 §8）。
- `rtl/simsynth/ROUTER.md`（已删）：旧版路由器的结构/时序分析，在 git 历史里。
