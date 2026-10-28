# Router —— 物理模型合成器的数字后端

更新：2026-10-28，基于 `8e9d1cda` 与工作区核对。以下结构/接口为当前源码；735/865拍、85.44MHz是既有阶段记录，未重跑xsim／PnR。Questa补测使用声明顺序兼容副本，不能写成原版直接编译通过；当前问题见[台账](../../docs/bugs.md)，工具入口见[sim](../../sim/README.md#questa)，详细结果见[补测记录](../../docs/工程评审与验证.md#questa-2026-10-28)。

一块 FPGA 上的 16 声部模态（modal）合成器：**16 个声部 × N_MODES 个模态**，每个模态一个
二阶谐振器，逐采样递推；后级接腔体（body）滤波和 4 路梳状混响；系数从 W25Q64 flash
按乐器加载。

- 采样率 48 kHz，目标主频 100 MHz；旧 eng0 钢琴 64 模态记录为 **每采样约 735 拍**，不推广为 eng1 或当前整机保证。
- 两套引擎：`eng0`（7 个并行乘法的直接型）和 `eng1`（ABC 递推）。
  **当前 `eng_sel()` 把 `INST_PIANO`/`INST_GUITAR` 派给 `eng0`（模态引擎），其余乐器
  （FLUTE/TRUMPET/…）先默认派给 `eng1`** —— 分配还是占位，见 `router_pkg.sv` 的注释。同一时刻只用一种，
  但**两个引擎实例各管 8 个声部并行跑**。
- 旧 eng0 每采样拍数记录取决于 `n_modes`：8 组 × (n_modes + 14) + 收尾。`n_modes=80` 实测 **865 拍**，
  `n_modes=64` 约 **735 拍**（钢琴 64、吉他 20；`n_modes_of()` 定义后再受 N_MODES 限幅）。

本文档按"结构 → 约定 → 取舍 → 现状 → 测试 → 待定"组织。想改代码先看 §4（约定）和
§5（取舍），那里写了"为什么不能那样改"。

---

## 1. 概览

```
                        ┌───────────── 一个采样（eng0 64 模态旧记录约 735 拍）─────────────┐
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
│   ├── eng_router.sv        双引擎薄封装（按乐器二选一），默认两个实例各管 8 个声部
│   ├── env_router.sv        按乐器选包络（ADSR / dyn0 / 常数 1.0）
│   ├── exc_router.sv        按乐器选激励参数（幅度/斜坡/宽度/间隔/脉冲数）
│   ├── mod_router.sv        当前只有吉他启用 modulation0
│   ├── body_router.sv       按乐器选 25 个腔体系数（5 段 × 5 抽头）
│   └── reverb_router.sv     预设（NONE/HALL/BATHROOM）+ 干湿混合
├── parts/
│   ├── envelope.sv          envelope_ADSR / envelope_dyn0（都输出 dead）
│   ├── excitation.sv        excitation_gen：锤击包络串（斜坡+指数尾巴，可无限）
│   ├── modulation.sv        modulation0：alpha/揉弦改系数（单乘法器串行 15 步）
│   ├── body_biquad.sv       5 段 biquad，历史存 BSRAM
│   └── comb_reverb.sv       4 路并联梳状线（读作零的清空）
├── tb/tb_music.sv           音乐集成 TB：完整音乐合成（见 §7）
└── tools/
    ├── flash_image.py       flash 镜像打包（record/table/image/parse + 自检）
    ├── piano_flash.py       物理域表 -> (sq/sv 归一化) -> Q 整数 -> flash 镜像
    ├── dec2wav.py           y_data 序列 -> 16-bit WAV（按峰值归一化）
    ├── piano_flash.bin      上一步的产物（inst=0，16 slot 各一个音，64 KB）
    ├── bq_gen.py            腔体系数对账（--check：RTL 字面量 vs Python 模型）
    ├── run_all.ps1          音乐集成回归入口（生成镜像 -> 编译 -> 仿真 -> 自检 -> 出 WAV）
    ├── piano_flash.mem      上一步的 $readmemh 字节文件（按需生成，不入库）
    └── bq_*.mem / flash_demo.mem  历史回归向量 / 镜像（生成物，可重跑生成）
```

依赖方向：`voice_router` → `routers/*` → `parts/*` → `pkg/*`。
`parts/*` 之间**没有**横向依赖，只有 `pkg`。

---

## 3. 架构与模块关系

### 3.1 层次

```
voice_router                      存储 + 调度 + 后级
├── weight_loader                 ① 系数/参数加载（阻塞 约 5.3ms/次的旧记录）
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
| `voice_router` | 存储、调度、混音 | `start`、**`done`(电平：1=空闲可 start)**、**`ready`(1=会执行挂起的配置变更)**、`load_err`、`fmap[16]`、`inst`、`reverb_preset`、`reload`、`y_valid/y_data`、`ns_rd_*`(debug) | 旧 eng0 记录约 735 拍/采样（64 模态） |
| `voice_router` | **声部数是参数 `SLOTS`**（不是端口） | `SLOTS` ∈ {4, 8, 16}：**只能 ≤16**（硬件只有 16 个按键），且必须 2 的幂、≥4（要拆两个 bank） | — |
| `weight_loader` | 四线 SPI 读 + 写口 | `start/busy/done/err`、`ld_we/ld_addr/ld_co/ld_pm`、`qspi_*` | ~520 拍/记录 |
| `eng0` | 直接型引擎：`y = Σ (coef × 状态)` | `co_re/co_addr/co_data`、`st_re/st_addr/st_q/st_qdot`、`st_we/...`、`x_re/x_data` | 每模态 5 级流水，N+8 拍/作业 |
| `eng1` | ABC 引擎：`y = clamp((G*x - a1*y1 - a2*y2)>>24)` | 同上 | 每模态 ~5 拍 |
| `eng_router` | 按 `inst` 在 eng0/eng1 间二选一 | 作业口 + 一套存储口 | 无额外延迟 |
| `envelope_ADSR` | A/D/S/R + `dead` | `A_STEP/D_STEP/S_LEVEL/R_STEP`、`emap`、`dead` | 每采样 |
| `envelope_dyn0` | `emap = fmap<<SHIFT`（钳位）、`dead = ~gate` | 同上 | 每采样 |
| `excitation_gen` | N+1 次锤击（斜坡 + 指数尾巴）/ 无限 | `SHIFT/RISE_SH/PW_LEN/GAP_LEN/N_PULSE/clear`、`xmap/xmap_valid` | 每采样 |
| `modulation0` | alpha/揉弦改系数 | `start/busy/done`、`p_*`(参数读)、`co_we/co_mode/co_wdata` | 15 步/模态，单乘法器 |
| `body_biquad` | 5 段 biquad | `in_valid/in_ready/x`、`out_valid/y`、`clr` | 93 拍/样本 |
| `comb_reverb` | 4 路梳状 | `in_valid/x`、`out_valid/y`、`clr` | 4 拍 + 2 拍混合 |

### 3.3 一次采样的调度（`voice_router` FSM）

```
S_DONE  ──start──► 有待执行的 inst/reload 变更且 ready? ──► S_LOAD
        │                                          └─否──► S_RUN_X（用旧表先出这一帧）
        └─无变更──────────────────────────────────────────► S_RUN_X
S_LOAD  ──ld_done──► S_RUN_X
S_RUN_X ──xmap_valid──► S_XS      （等激励发生器出一个采样；xmap 整张打进 x_q）
S_XS    ─────────────► S_RUN_V    （g=0，两个引擎同时 start）
S_RUN_V ──era_yv&&erb_yv──► S_ENVMUL   （取 A 声部的 y 和 emap[g]）
S_ENVMUL/S_ENVACC ─► S_ADV        （乘 → 累加）
S_ADV   ──还没算 B──► S_ENVMUL（pick_b=1，同一套流水再算一次）
        ──这组完了──► g++ → S_RUN_V
        ──全部声部完──► mix_v=1 → S_WAIT
S_WAIT  ──腔体+混响排空──► S_DONE（done 才变 1）
```

拍数：`固定 + HS×(n_modes + 8) + HS×6 + 排空`，`HS = SLOTS/2 = 8`。
旧 eng0 记录 `n_modes=64` 时 ≈ **735 拍**（`n_modes_of(INST_PIANO) = 64`）。

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
| `q_ram/v_ram`（状态） | eng0：s8.24；eng1：Q2.30 | 32 | 共享存储位宽，不共享二进制点解释 |
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
| `note_on[i]` | **滞回门控电平**：按下 >230、保持 ≥26、松开 <26，不是脉冲 | `voice_router`（打一拍输出） |
| `note_ev/note_f` | 起音沿 / 攒到帧头的那份 | 各消费模块自己取（`excitation_gen`、`envelope_*` 内部各有一份） |
| `dead[i]` | 这个声部**真的空了**：ADSR 走完 release 才给；dyn0 没按住就给 | `envelope_*` |
| `clear` | 换乐器：清激励状态机 / 腔体历史 | **各子模块内部**比较自己的 `inst_q` 产生（`exc_router`/`body_router`）；混响的 `clr` 来自 `preset` 比较。`voice_router` 不产生 `clear` |
| `mod_req[i]` | 后台调制请求位图 | `voice_router`，`modulation0` 空闲时按最低位服务 |
| `reload` | 强制重灌系数（不清状态） | 外部 |
| `input_hold` | 加载期间冻结 `fmap_q`（= 忽略输入） | `voice_router` |

**为什么要 `dead` 而不是拿 `emap==0` 判断**：ADSR 从 0 起爬，起音头几个采样 `emap` 也是 0；
用它判断"空了"会把刚打进去的激励清掉（听感 = 没声音）。

### 4.4b 激励的形状（怎么对 Python 的 `SF`）

`excitation_gen` 每个声部一个"力包络"状态机（**没有乘法器**，全移位/加法）：

```
按下沿 → X_ATT   : acc += target>>RISE_SH，共 PW_LEN 拍（线性上升）
       → X_DECAY : acc -= (acc>>6)+(acc>>8)+(acc>>10)      （指数尾巴，tau≈48 采样≈1 ms）
                   同时数 GAP_LEN 拍；到期 → 下一次锤击
下一次锤击：target ← target - (target>>2) - (target>>4)   （×0.6875 ≈ Python 的 0.7）
松开       ：当前这一串走完就停
```

周期 = `PW_LEN + GAP_LEN`。钢琴的取值（`exc_router.sv` 的 `INST_PIANO`）：

| 参数 | 值 | 对应 Python `SF`（`sim_piano.py`） |
|---|---|---|
| `SHIFT` | 20 | `amplitude`（峰值 = fmap<<20；250<<20/2^28 = 0.977，Python demo 是 1.0） |
| `RISE_SH` / `PW_LEN` | 5 / 32 | `attack` 0.5 ms（24 采样），这里 0.67 ms |
| `GAP_LEN` | 448 | `delta` 10 ms（周期 480 = 10 ms ✓） |
| 衰减 | `>>6+>>8+>>10` | `tau` 1 ms ✓ |
| `N_PULSE` | 3 | `pulse_num` 4 ✓ |
| 递减 | 0.6875^k | 0.7^k ✓ |

**包络的起音峰值是固定的满幅 1.0**（`0x7FFF_FFFF`，Q1.31），**力度不影响包络**：
`envelope_ADSR` 虽然有 `fmap` 端口，但模块内部**没有用它**；`env_router` 里的
`A_STEP/D_STEP/S_LEVEL/R_STEP` 是常量（钢琴：2.67 ms 爬满、32 ms 衰到 0.25、
松键 10.7 ms 归零）。所以现在**力度只通过激励影响音色/音头强度**，持续段电平
永远是 0.25。只有吉他走的 `envelope_dyn0` 是力度驱动的（`emap = fmap<<23`）。

> 想让力度也缩放包络电平，最小改法是起音那一拍把 `fmap<<SHIFT` 锁存成 `peak[i]`
> （衰减目标用 `peak>>2`），每声部多 2 个 32 位寄存器、不用乘法器 —— 现在是
> **故意没做**（先让激励承担力度差异，见 §4.4b 上面的激励对照）。

**为什么不是矩形**：早期版本是 `PW_LEN=1, GAP_LEN=0`（4 个单采样尖峰），
激励面积只有 4.0、频谱质心 7.3 kHz（Python 是 144 / 0.79 kHz）——能量全堆到
高频，听感"薄、不密集"。现在旧测量记录（当时 `_analysis/exc_cmp.py`，该临时脚本不在当前仓库）：面积 138、
质心 671 Hz、脉冲峰 0.977/0.692/0.476（Python 0.958/0.671/0.470）。
### 4.5 系数域与当前生成链

eng0 的七系数对应状态空间：

```text
q' = a11*q + a12*v + gq*x
v' = a21*q + a22*v + gv*x
y  = wo*q
```

一般物理域到定标域的变换令 `q_s=sq*q, v_s=sv*v, k=sq/sv`：
`a12'=a12*k, a21'=a21/k, gq'=gq*sq, gv'=gv*sv, wo'=wo/sq`，a11/a22 不变。
恢复力 a21 为负；物理域可选 `k=sqrt(abs(a21/a12))` 平衡矩阵元幅度，两者符号相反，不能写成 `a12'=a21'`。

<a id="coefficient-pipeline"></a>

**生成器输出与打包器输入是两条尚未统一的链，不能再画成一个默认箭头。**

| 当前文件/工具 | 实际合同 |
|---|---|
| `sythsound/piano_coeff_gen.py` | main写`piano_coeff_scaled.txt`；MIDI40..79、每音64条（32模态的两组微失谐）；矩阵已采用a12=es*omega0/wd、a21=-es*omega0/wd，gq/gv/wo已定标 |
| `sythsound/piano_coeff.txt` | 仍是打包器默认输入的旧表，矩阵未平衡；不是当前生成器默认写入目标 |
| `sythsound/piano_coeff_scaled.txt` | 新生成器的已平衡/定标表；若采用，须显式传`--coeff`并另存镜像，当前默认脚本未切换 |
| `tools/piano_flash.py` | 默认读旧piano_coeff.txt，scale_mode后Q量化；对新scaled表仍走scale_mode，已是冗余兼容步骤，不能据注释声称输入一律为物理域 |
| `tools/piano_flash.bin/.mem` | 本轮内存重打包确认，两份现有镜像匹配旧默认表；不匹配改用scaled表生成的镜像 |
| `sythsound/guitar_coeff_gen.py` | 写guitar_coeff_scaled.txt，但a12=es/wd、a21=-es*omega0²/wd，只缩放gq/wo；不具备钢琴同样的矩阵平衡合同 |

新scaled钢琴表的全部非零矩阵比值k=1；当前打包器对其首模态选k=1、sq=1。旧默认表首模态则为k≈517.165、sq=512，因而“生成侧已改”不意味着当前默认打包链已经使用新表。检查必须区分生成器版本、所选输入、最终镜像，不直接删除scale_mode或自动替换已验证资源。

对表时可另存候选镜像，避免覆盖现有TB资源：

```bash
mkdir -p /tmp/fpga-coeff-review
python rtl/router/tools/piano_flash.py --coeff sythsound/piano_coeff.txt --out /tmp/fpga-coeff-review/legacy.bin --mem /tmp/fpga-coeff-review/legacy.mem
python rtl/router/tools/piano_flash.py --coeff sythsound/piano_coeff_scaled.txt --out /tmp/fpga-coeff-review/scaled.bin --mem /tmp/fpga-coeff-review/scaled.mem
```

这只比较格式/定标与镜像，不证明新表音色、状态余量或实时出声。切换表前需重测极点/量化、正常与全槽幅度、激励/包络链和RTL golden。`--raw`跳过额外定标的选择也须单独核对，不能当成自动兼容开关。

吉他当前脚本main的40..79循环仍固定调用print_guitar_coeff_by_midi(66)，现有guitar_coeff.txt的40个音标签实际只有一组不同的系数正文，不能计作40个可用音高。新增guitar_param_gen.py仍是七系数原型（a21为正），不是mod_par_t参数生成器，尚未接入router镜像链；详见 [问题台账](../../docs/bugs.md)。

字段小数位：a11=28、a12=30、a21=23、a22=28、gq=31、gv=27、wo=15；
eng0 状态 QF=24、激励 XF=28、输出 YF=40。eng1 的 G/a1/a2 使用另一套格式，
见 `engines/eng1.sv` 和 [模型说明](../../docs/ENG1_PY_MODEL.md)。

音乐 TB 从 `tools/piano_flash.mem` 灌最终整数表；这避免另维护旧黄金文件，
但仍须独立核对生成器→定标→量化→引擎的数学和数值合同。

### 4.6 调制器（吉他揉弦）的公式

`modulation0` 一次处理一个声部的 `n_modes` 个模态，**只改 a11/a12/a21/a22**（gq/gv/wo 不动）。
输入是参数表里的 `c0/s0/gam/theta0/g/k12/k21` 加上从 `fmap` 得到的 `alpha`：

```
alpha = 1 + K_ALPHA·fmap            K_ALPHA = 50 cent / 255（Q30，常数 123437）
```

然后每个模态按 15 步（单乘法器串行，每步 `S_LD → S_MUL → S_APPLY` 三拍）算：

| step | 算的东西 | 含义 |
|---|---|---|
| 1 | `D  = (alpha−1)·theta0` | 频率偏移量 |
| 2 | `d  = 1 − gam/FS` | 每采样的衰减因子（`gam` 是 Q16.16） |
| 3 | `c  = c0 − s0·D` | `cos(theta0 + D)` 的一阶展开 |
| 4 | `s  = s0 + c0·D` | `sin(theta0 + D)` 的一阶展开 |
| 5 | `ea = d·c` | a11/a22 的对称部分 |
| 7 | `a12a = d·s·g/alpha` | 未归一化的 a12（`g = Δt/theta0`） |
| 8 | `a12  = a12a·k12` | **乘 sq/sv**，回到硬件的状态定标 |
| 9 | `t  = a12·gam` | 反对称部分 |
| 11/12 | `w0 = omega0·2^16`、`w2 = omega0²` | |
| 13 | `a21 = −a12·alpha²·w0²·k21` | **乘 sv/sq** |
| out | `a11' = (ea+t)>>2`、`a22' = (ea−t)>>2`、`a12'`、`a21'` | 写回（Q28/Q30/Q23） |

- 门控：`theta0 >= 0.8 rad`（`TH_GATE`）或 `fmap == 0` 时 `co_we = 0`，一个字段都不写
  （高模态的 theta0 很大，硬调会把谐振点推飞）。
- `a21` 里那个 `alpha²` 和 `w0²`：频率改 alpha 倍后，a21（≈ `es·ω0²/ωd`）要按 `ω0²` 缩放；
  `k21` 再把状态定标换回去。
- 因为是"改频率 → 重新推系数"，所以**幂等**：同一个 `(声部, fmap)` 跑几遍结果一样。

---

## 5. 设计取舍与历史测量（为什么这样 + 代价）

### 5.1 两个引擎并行 + 双 bank —— 1577 → 735 拍（64 模态）

- **做法**：`voice_router` 实例化两个 `eng_router`，各管 `SLOTS/2 = 8` 个声部；一次作业
  跑 8 组，每组两个声部同时起算，等两个 `y_valid` 都到齐后**复用同一套**包络乘/累加
  流水串行算两次。
- **为什么必须拆 bank**：两个引擎同拍读不同地址 = 2R1W = 三个端口，BSRAM 只有两个。
  拆分后每 bank 512 字 × 32 位正好一块 512×36。
- **代价**：引擎逻辑翻倍（Logic 10.5k → 12.5k，LUT 7.6k → 8.8k）；地址要按声部分 bank
  （`slot[VWID-1]` 选 bank）。
- **没选"复制阵列"**：那要多 32 块 BSRAM。

### 5.2 调制放后台

- **做法**：起音声部只置一个 `mod_req[i]`，`S_RUN_V` 不停等；调制器空闲且不在加载时
  发一拍 `start`，`done` 时清那一位。
- **为什么能并行**：调制器写系数用 `ca_*` 的**写口**，引擎读系数用**读口**，同一块
  1R1W RAM 的两个端口；而且 `co_we=4'b1111` 是**一拍写齐 4 个字段**，引擎不会读到
  半新半旧的系数。四字段同拍写入；整张表仍逐模态更新，并非帧头原子切换。引擎并发读取时的同址语义和跨模态一致性仍需验证。
- **为什么用位图**：单个"待处理"寄存器会被同帧第二个起音冲掉；位图谁请求都不丢。
- **为什么不用"15 步并行"**：那要再加 15 个乘法器；串行 + 后台已经把 60k 拍的首帧尖峰
  摊到 ~38 帧里，实测吉他 16 键齐按从 71413 拍/8 作业降到 12616。
- **代价**：调制器是幂等的（无跨轮状态），所以重复请求只是白花拍数；`mod_req` 排空
  需要几十帧（旧 R3c 曾检查排空，对应 TB 已删除，本轮未复验）。

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
- **饱和**一共有三处：① 4 路求和 `sum4`（71 位判断溢出）；② 每路写回 RAM 的 `wd`
  （65 位加 + 饱和）；③ 干湿相加 `y_sum`。**湿声加权** `t1..t4` 保留 69 位，而反馈
  `fb1..fb4` 是 64 位（乘积后截断再移位）。
- **流水**：写 RAM 的数据必须先进寄存器（`wd`），**不能**让"65 位加 + 饱和 mux"直接怼
  RAM 的 D 口（实测那条路 13.8 ns，72 MHz）。
- **边界**：延迟 6 拍；反馈仍以 64 位目标计算，中间乘积并非一律保留完整 96 位。求和/写回/干湿饱和不能代替乘法范围检查，见 F09。

### 5.6 包络/激励的采样节拍用 `clk_en`

- 不用 `CLK_HZ/SR_HZ` 分频器各自分频（会漂），统一由 router 给 `smp_tick`，包络/激励
  当**时钟使能**用。
- 事件（`clear`/起始沿）只在节拍上被消费，所以 `clear` 要**挂起**等节拍（否则一拍脉冲会漏）。
- 包络/激励内部的 `onset` 也是在 `clk_en` 上采（电平保持一个节拍）。

### 5.7 加载是阻塞的

- 换乐器 → 停帧 → 重灌 → 继续。一次 64 KB（16 声部 × 64 模态 × 64 字节）：
  实测 **526 994 拍 ≈ 5.3 ms**（`SCK_DIV=4`，四线模式；原 `tb_loader_flash` 量的，TB 已删）。
  换句话说：**中途 reload 会丢掉约 250 个采样**，所以才有"等键全松再 reload"的策略问题（§8.2）。
- **代价**：切换乐器时会断供样；旧记录约 5.3ms，整机须定义补静音/缓冲策略。要更快只能改 PHY（默认 4 拍/SCK；100MHz 输入对应 25MHz SCK）。
- Quad 模式要求 flash 的 **QE 位**已置位（状态寄存器 2 bit1）——一次性配置，loader 不做
  （否则每次加载都要写状态寄存器 + 等 tSR ~10 ms）。

---

## 6. 现状数据

`TOP=voice_router`，`N_MODES=64`，`SLOTS=16`，含腔体 + 混响：

| 项 | 数值 |
|---|---|
| 旧 eng0 每采样记录 | **735 拍**（n_modes=64）；不包含当前整机采集/加载/输出预算，也不适用于 eng1 |
| 旧 Fmax 记录（100 MHz 约束，本轮未构建） | **85.44 MHz**（slack −1.7 ns），48 kHz 余量 2 倍 |
| Logic / Register / BSRAM | 10433（6787 LUT + 3646 ALU）/ 138240 = 8%；Register 5086 / 139140 = 4%；BSRAM **66** / 340 = 20% |
| 关键路径 | 混响梳状写 RAM / 干湿相加（约 −1.4 ns） |

瓶颈的顺序：混响（`u_rev`）> eng1 累加链 > eng0。要冲 100 MHz 按这个顺序拆。

---

## 7. 测试

### 7.1 音乐集成 TB

2026-10-28补测：原版Questa编译有14条先使用后声明错误；只在隔离副本调整声明后，默认24000点和4096点ALL16通过原TB判据。把另一隔离副本的输出固定为1，原TB仍打印PASS，证明该判据不能验证波形正确性。完整参数、7061诊断抑制、模块补测及失败结果统一见[补测记录](../../docs/工程评审与验证.md#questa-2026-10-28)，本目录的正式脚本仍为下面的xsim入口。

**模块级 TB 全部删掉了**（`tb_voice_router`/`tb_throughput`/`tb_reverb`/`tb_envelope`/
`tb_excitation`/`tb_modulation`/`tb_eng1_g`/`tb_loader_flash`/`tb_body_biquad`/
`tb_fmax_router`）。理由：内部信号/端口一改，它们就得跟着改，同步成本高；而且照样
漏 bug（问题台账中两个严重 bug 就躲在"只按声部 0"、"只查有没有写"这种盲区里）。

音乐集成入口为 `tb/tb_music.sv`；另有 `tb_eng1_cosim.sv` 做独立 eng1 算术对拍，不能称仓库只剩一个 TB：

```
喂 fmap（按键/力度/松键） + inst + reverb_preset
        ↓  voice_router（内部自己做 loader 之外的一切）
y_valid / y_data（每采样一个 64 位样本）
        ↓  自检：帧数、无 X、有声音
_analysis/music_dec.txt  →  tools/dec2wav.py  →  _analysis/music.wav
```

- 系数不再是"黄金向量"，而是从 `tools/piano_flash.mem`（`piano_flash.py` 生成的**完整
  系数表**）灌进 RAM —— 和上板时 loader 写进去的是同一份数据。
- **每个slot一个音高**（镜像默认MIDI列表并非全程等间隔），弹不同slot选择不同表。当前TB默认只按NOTE_SLOT=4，按住HOLD采样后松开；ALL16=1才是16键同时按下，不再是旧8音旋律用例。
- 没有 flash 行为模型，第一个 load 被跳过（直接灌 RAM 镜像）；`flash_image.py --selftest` 检查打包格式，`piano_flash.py` 报告量化；两者均不验证 loader 的真实 SPI 时序/命令。

### 7.2 怎么跑

```powershell
pwsh -File rtl/router/tools/run_all.ps1                # 一条命令：镜像 -> 编译 -> 仿真 -> 自检 -> 出 WAV
pwsh -File rtl/router/tools/run_all.ps1 -SkipBuild     # 只重跑（编译过了）
pwsh -File rtl/router/tools/run_all.ps1 -SkipFlash     # 镜像已生成，不重新跑 python
```

它会依次做：

1. `tools/piano_flash.py` → `tools/piano_flash.mem`（**回归的前置条件**，脚本里自动做，
   需要先准备 Python/numpy、PowerShell 与 Windows Vivado xsim）
2. **逐个文件**编译（21 个）：一条 `xvlog` 塞 20 个文件时偶发长时间不返回，逐个编
   稳定在 1 s/个
3. `xelab` + `xsim`，抓 `RESULT: PASS`
4. 导出 `_analysis/music.wav`

手动跑（调试用）：

```powershell
$env:PATH = "E:\Xilinx\Vivado\2017.4\bin;" + $env:PATH
xvlog.bat --nolog -sv rtl/router/tb/tb_music.sv     # RTL 先逐个编进 work 库
xelab.bat --nolog tb_music -s tb_mu --debug typical -timescale 1ns/1ps
xsim.bat tb_mu --nolog -runall
python rtl/router/tools/dec2wav.py _analysis/music_dec.txt _analysis/music.wav 48000
```

### 7.3 它实际检查什么

| 检查 | 判据 |
|---|---|
| 帧数 | `n_out == NSAMP`（每采样恰好一个 `y_valid`）—— 抓"作业少跑/多跑" |
| 无 X | 输出里没有 `x` —— 抓"系数没灌到、RAM 读空、位宽截断" |
| 有声音 | `|ymax| > 0` —— 抓"引擎一个模态都没算"（`n_modes` 被截成 0 那类） |
| 削波计数 | 打印 `n_clip`，>0 说明增益链有问题（不拦 PASS） |

**已知没覆盖**（见 §8）：`DEBUG_PORT` 读口；loader 的 SPI 时序（只有格式自检）；
少于 16 声部的配置；`eng1`（现在只由 `eng_sel` 的默认分支用到，钢琴/吉他走 eng0）。

### 7.4 历史：删掉的模块级 TB 各自覆盖过什么

留着供追溯（这些文件已从仓库删除）。2026-10-28从 `b75efa42^` 提取7份模块TB至隔离目录，对当前模块补跑；通过、过期TB与模型局限见[补测记录](../../docs/工程评审与验证.md#questa-2026-10-28)，不等于正式回归入口已经恢复：

| 原 TB | 覆盖 |
|---|---|
| `tb_voice_router` | R1 钢琴+混响直通、R1b 切 HALL、R2 松键归零、R3 吉他调制、R3c 调制队列排空、R5 reload 推迟策略（R5a–e）、R7 bank B 独立性（**一直没通过**） |
| `tb_throughput` | 每采样拍数（64 模态 ≈735，80 模态 ≈865） |
| `tb_reverb` / `tb_excitation` / `tb_envelope` / `tb_modulation` | 各模块的边界与数值 |
| `tb_eng1_g` | eng1 的 ABC 递推 golden 值、`nmod_lat` 位宽 |
| `tb_loader_flash` | W25Q64 四线行为模型 + 写口逐笔比对 + 空白片 `err`（1244 拍填 0） |
| `tb_body_biquad` | 腔体 5 段 biquad 逐样本对 Python 模型 |

---
## 8. 待确定项 / 已知问题

1. ~~`n_voices < SLOTS/2` 会挂~~ **已解决**：`n_voices` 端口删掉了，声部数 = `SLOTS`
   参数。**`SLOTS` 只能 ≤ 16**（fmap 是 mat4x4，硬件只有 16 个按键），且必须是
   2 的幂、≥ 4（两个 bank，`HS = SLOTS/2`）；实际可用 4 / 8 / 16。
   `xmap/emap`、`env_router`/`exc_router` 及 `envelope_*`/`excitation_gen` 都已按
   `SLOTS` 参数化（`voice_router` 里有 `translate_off` 的参数检查）。
2. ~~`reload` 会挂~~ **不是 bug**：reload = 完整重灌 527k 拍 ≈ **5.3 ms**。
   **推迟策略已实现**：`reload` 在 router 内部取上升沿 → `reload_pend`；
   `change_pend = (inst != inst_prev) || reload_pend`；
   `ready = !change_pend || (note_on == 0)`。有变更且还有键按着 → `ready=0`，
   这一帧照常跑（旧表），等松键后的第一帧才真正重灌。
   （旧 R5a–R5e 覆盖过，TB 已删；当前 tb_music 绕过 loader，不能据此证明重载策略。）
   调制和加载互斥：`load_now` 挡住"同一拍就要开始加载"时的 `mod_start`；已经起跑的
   调制在加载期间（`ld_busy || ld_start`）对系数表的写一律丢弃，避免 loader 写完之后
   又被旧调制改回某个地址。
3. **`loader.err` 只送到端口（`load_err`），router 不处理**：坏表时 loader 把两张表
   全填 0（`W_FILL`，实测 1244 拍）并拉高 `err` 电平 → 输出静音而不是乱响；
   上层/UI 负责提示。"重试/报警"这类策略放上层。
4. **`n_modes` 已不是 voice_router 的外部输入**：来自 n_modes_of(inst)，引擎和调制器使用锁存的 nm_lat。
      `n_modes_of(inst)` 现在会在 `voice_router` 里限幅到 `N_MODES`（`nm_lat <= min(...)`），
   所以 `N_MODES` 改小也不会读飞；但 `n_modes_of` 本身是按满配 64/20 写的，改表深度要一起改。
5. **`DEBUG_PORT` 现在只吐"最近一次引擎读到的状态字"**（不能任意地址读），因为没有
   多余的 RAM 读口。要真调试得在外面加 ILA，或者接受多一块 RAM 复制的代价。
6. **`eng0` 缺独立的 golden 值测试**（用 Python 模型逐样本对比），现在只有端到端。
7. **音高 / 系数表**：默认打包器仍读取旧piano_coeff.txt，生成器已写入另一份piano_coeff_scaled.txt；当前镜像属于旧默认输入。16slot资源与新旧表的定标/量化合同见§4.5，旧“零饱和”记录不能证明新表已进入音乐回归。
8. **R7历史未通过记录**：旧用例只按声部15时观察到状态未有效写入，原TB已删除。2026-10-28在声明兼容副本中，用16槽不同状态夹具完成4帧、64次A/B独立比较并通过；该证据不等于原R7的真实音色场景及全部触发／释放交互已关闭，详见[补测记录](../../docs/工程评审与验证.md#questa-2026-10-28)。
9. **`voice_router.cst` 故意没有 `IO_LOC`**：P16/R15 在 GW5AST-LV138FPG676AES 上无效
   （PR2017/PR2028），要上板得按实际板子补。
10. 想冲 100 MHz：混响写 RAM 已拆两级，下一个是干湿相加（`u_rev/y_63`）和 eng1 累加链。

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

- [当前问题与验证缺口](../../docs/bugs.md)：F01–F11 当前状态、新发现和验收边界。
- `rtl/simsynth/ROUTER.md`（已删）：旧版路由器的结构/时序分析，在 git 历史里。

2026-10-27未运行音乐xsim／PnR；28日Questa补测没有改变这个xsim／PnR边界。Questa的eng1 intended对拍同样为66项中3个n_modes=0失败，独立模型33项通过不覆盖该RTL边界。详细日期化结果见[验证记录](../../docs/工程评审与验证.md#verification)及[Questa补测](../../docs/工程评审与验证.md#questa-2026-10-28)。
