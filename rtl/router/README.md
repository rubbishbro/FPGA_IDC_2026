# Router —— 物理模型合成器的数字后端

更新：2026-10-29，核对32b92498及工作区。当前合同按下文维护；历史周期/PnR和兼容副本结果保留日期，不能升级为当前整机证明。最新复测、当前顶层音频缺口及运行器限制见[验证记录](../../docs/工程评审与验证.md#global-docs-2026-10-29)和[问题台账](../../docs/bugs.md)。

一块 FPGA 上的 16 声部模态（modal）合成器：**16 个声部 × N_MODES 个模态**，每个模态一个
二阶谐振器，逐采样递推；后级接腔体（body）滤波和 4 路梳状混响；系数从 W25Q64 flash
按乐器加载。

- nominal采样率48kHz，目标主频100MHz；当前演奏顶层缺I2S接口，恢复外部采样模式后Fs应由音频参考决定；旧 eng0 钢琴 64 模态记录为 **每采样约 735 拍**，不推广为 eng1 或当前整机保证。
- 两套引擎：`eng0`（7 个并行乘法的直接型）和 `eng1`（ABC 递推）。
  **当前 `eng_sel()` 把 `INST_PIANO`/`INST_GUITAR` 派给 `eng0`（模态引擎），其余乐器
  （FLUTE/TRUMPET/…）先默认派给 `eng1`** —— 分配还是占位，见 `router_pkg.sv` 的注释。同一时刻只用一种，
  但**两个引擎实例各管 8 个声部并行跑**。
- 旧eng0测量的每采样拍数取决于 `n_modes`：8 组 × (n_modes + 14) + 收尾。`n_modes=80` 实测 **865 拍**，
  `n_modes=64` 约 **735 拍**（钢琴 64 模态；吉他 20 模态，帧更短，由 `n_modes_of()` 定）。

> eng1的ABC系数格式独立：G Q2.24、a1 Q2.20、a2 UQ0.24。状态递推沿用输入激励的小数位，当前router激励XF=24；旧独立模型的Q30幅度不能直接套用当前router的PCM定标。

本文档按"结构 → 约定 → 取舍 → 现状 → 测试 → 待定"组织。想改代码先看 §4（约定）和
§5（取舍），那里写了"为什么不能那样改"。

---

## MIDI演奏选源增量（3.2）

2026-10-28已增加 [midi_voice_top.sv](midi_voice_top.sv) 连接MIDI状态层与真实voice_router；router内 [performance_input_mux.sv](routers/performance_input_mux.sv) 选择压力垫或MIDI的门控/激励力度，MIDI不伪装成fmap。原实例默认MIDI_ENABLE=0。激励模块新增明确的力度、重触发和逐槽清除输入；3.2阶段未改计算核心，后续工作区eng1已改流水，专用持续音色形状仍待补入。

当前仓库源文件已前移必要声明，能够直接通过Questa编译；前文兼容副本限制仍描述早先补测。新增正式入口`python3 sim/run_router_midi.py`，3.2阶段五项、后续联合配置扩展至11项曾通过，当前工作区不可据此直接宣称全量重验通过；pending音色模态数和eng1 B结果锁存问题已在router修复。原压力垫256采样修改前后逐点一致。端口、切源/通道语义和验证限制统一见[MIDI接入3.2](../../docs/MIDI演奏与通信接入.md#router-midi-step32)，新入口不使用兼容副本或7061抑制，不替代真实Flash、音色资源、48k吞吐或上板验收。

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
├── midi_voice_top.sv        MIDI状态层、通道映射、控制分流与voice_router连接入口
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
│   ├── performance_input_mux.sv 压力垫/MIDI演奏控制选源与帧完成确认
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
| `weight_loader` | 四线 SPI 读 + 写口 | `start/busy/done/err`、`ld_we/ld_addr/ld_co/ld_pm`、`qspi_*` | 1024 拍/记录 @SCK_DIV=4 |
| `eng0` | 直接型引擎：`y = Σ (coef × 状态)` | `co_re/co_addr/co_data`、`st_re/st_addr/st_q/st_qdot`、`st_we/...`、`x_re/x_data` | 每模态 5 级流水，N+8 拍/作业 |
| `eng1` | ABC 引擎：`y = clamp((G*x - a1*y1 - a2*y2)>>24)` | 同上 | 五级流水，II=1模态/拍，末尾排空 |
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
  +0  a11   +4  a12   +8  a21   +12 a22        ← 系数表
  +16 gq    +20 gv    +24 wo    +28 保留(0)
  +32 a11_0 +36 a12_0 +40 a22_0 +44 wo_0       ← 参数表：4 个基值
  +48 s11   +52 s12   +56 s22   +60 swo        ← 参数表：4 个对 lambda 的斜率
```

参数表**只存 4 个基值 + 4 个斜率**：`a21 = −a12`、`S21 = −2a12 − S12` 都由 RTL 现算
（`a21` 的 Q 和 `a12` 不同，见 §4.2）。基值带 `_0` 后缀是为了和系数表的同名字段区分
（`flash_image.parse()` 把一条记录读成一个 dict，重名会互相覆盖）。

**每个声部一张表**（loader 一对一写，不复制）。想给 16 个声部不同音高，就在 flash 里
预先排好 16 张表。

### 4.2 位宽与定点（各处不同，别串）

**模态链只有一个二进制点：`QF = XF = YF = 24`。** 状态、激励、输出都是 Q24
（1.0 = 2²⁴ = 16 777 216）。以前 `XF=28`、`YF=40` 都是占位值：`YF=40` 只是标签
（算术出来本来就是 Q24），`XF=28` 则是**真 bug** —— `gq·x` 是
`(x_int·gq_int)>>>SH_GQ` 直接加进 `q_int`，`XF≠QF` 就差 `2^(XF−QF)`。
实测 `XF=28/QF=24` 时状态峰值是 Python 模型的 **16.3 倍**（0.452 vs 0.0277），
改回 24 后实测 **0.02826 vs 0.0277**（差 2%，来自激励斜坡 32 拍 vs Python 24 拍）。

| 位置 | 格式 | 位宽 | 说明 |
|---|---|---|---|
| `emap`（包络） | **Q1.31 有符号** | 32 | 1.0 = 2^31−1；乘法用 `(y*E)>>>31` |
| `xmap`（激励） | **Q24** | 32 | `x = (fmap<<SHIFT)/2^24`；钢琴 SHIFT=16 → 250 时 x=0.977 |
| `coeff_t` 各字段 | 见下表 | 32 | 每个字段一个 Q（编译期常量） |
| `q_ram/v_ram`（状态） | **Q24** 有符号 | 32 | s8.24，±128；实测单模态峰值 0.03~0.18 |
| `y`（单模态）/ `mix_q` | **Q24** | 64 | 实测 Σ\|y\| 峰值：单音 0.27 / 16 键齐按 0.68 |

| 腔体系数 | **Q4.27** | 32 | 5 段 × 5 抽头 |
| 混响增益/延迟 | **Q4.27** | 32 | 延迟单位 = 采样点 |
| `mix`/`y_acc`/`y_data` | 有符号 | 64 | 后级全 64 位；实测峰值只有 2⁶³ 的 1e−10 量级 |

**系数各字段的 Q**（`modal_step_pkg` 的 `SH_*`，必须和 `tools/piano_flash.py` 的 `SH` 一致）
—— "用掉"是拿整张钢琴表（40 音 × 64 模态）实测的：

| 字段 | 整表 max\|v\| | 刚好装下 +2× 余量的 Q | 现在用的 Q | 用掉 int32 |
|---|---|---|---|---|
| `a11` / `a22` | 1.00 | 30 | 28 | 12.5% |
| `a12` | 1.00 | 30 | **30** | **50%** |
| `a21` | 1.00 | 30 | 23 | 0.4% |
| `gq` | 1.36e−2（钢琴参考） | 36 | **32** | 约2.7%；吉他约41% |
| `gv` | 2.53e−2 | 35 | **34** | 16% |
| `wo` | 0.99 | 30 | **29** | 25% |

**当前gq/gv/wo为Q32/Q34/Q29**，以modal_step_pkg和两个打包器的实际常量为准。上表峰值仅为此前钢琴参考，整张当前选表的量化余量应由打包器检查；改Q必须重生成镜像并回归。

`a11/a12/a21/a22` **暂时保持** Q28/Q30/Q23/Q28：`modulation.sv` 会写这四个字段，
它的内部链路是按 Q30/Q23 调的，改 Q 必须连它的输出移位一起改 —— 等吉他系数表能跑通、
能用 `tb_music` 验一遍揉弦再动。真要改的话是**三处一起改**：
`modal_step_pkg.SH_*`、`tools/piano_flash.py` 的 `SH`、`modulation.sv` 的输出移位。

> 为什么 `gq/gv` 这么小（1e−6~1e−2）而 `wo` 接近 1：物理上 `gq·wo`、`gv·wo`
> 的乘积是不变量，而 `wo`（= 桥力权重 `n·(−1)ⁿ·8f₀²`）已经顶到 1 附近，
> **没有余量把大小在 `gq` 和 `wo` 之间再倒** —— 生成器里的归一化已经把它用满了。

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
永远是 0.25。吉他现在**走「无包络」分支**（`use_adsr=0`/`use_dyn=0` → `emap` 恒 1.0、
`dead` 恒 0），所以状态 RAM 的清零**不能**再靠 `dead`（见 §5.3 的 `init_zero`）。
`envelope_dyn0` 还留着（`emap = fmap<<23`，力度驱动），但吉他暂时不用它。

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

**当前默认链已统一为scaled表直接量化。** 28日早期“打包器仍读旧表”的发现见工程验证历史记录；下表为29日工作区事实。

| 文件/工具 | 当前合同 |
|---|---|
| sythsound/piano_coeff_gen.py → piano_coeff_scaled.txt | MIDI40..79，每音64条；矩阵a12=es*omega0/wd、a21=-es*omega0/wd，gq/gv/wo已定标 |
| tools/piano_flash.py | 默认读scaled表，不再scale_mode；按SH量化，默认16个不连续MIDI音，可显式生成连续32音及manifest |
| sythsound/guitar_coeff_gen.py → guitar_coeff_scaled.txt | 已逐MIDI调用，40个不同音高、每音20条；矩阵平衡、负a21，gq/wo定标，gv=0 |
| sythsound/guitar_param_gen.py → guitar_param.txt | 调制基值a11/a12/a22/wo及S11/S12/S22/Swo，不是旧七系数原型；一阶近似范围需独立验证 |
| tools/guitar_flash.py | 直接量化系数/参数，默认16音、每槽64记录，前20有效其余补零；区域起点0x010000 |
| tools/*_flash.bin/.mem | 29日内存重打包均与当前输入逐字节一致，所有量化字段零饱和；hash见[本次记录](../../docs/工程评审与验证.md#global-docs-2026-10-29) |

当前字段小数位a11/a12/a21/a22=28/30/23/28，gq/gv/wo=32/34/29；eng0状态/激励/输出均Q24。eng1的G/a1/a2另有合同，见[模型说明](../../docs/ENG1_PY_MODEL.md)。旧piano_coeff.txt/guitar_coeff.txt不再是默认资源输入，不能把旧物理域表直接喂给只量化的新工具。

候选资源应另存输出，避免覆盖测试输入：

```bash
python3 rtl/router/tools/piano_flash.py --verify
python3 rtl/router/tools/guitar_flash.py --verify
python3 rtl/router/tools/piano_flash.py --notes 32 --first-midi 40 \
  --out /tmp/piano32.bin --mem /tmp/piano32.mem --manifest /tmp/piano32.json
```

40..71仅演示连续32音，不冻结正式音域。默认16音布局64KiB/乐器，32音128KiB/乐器；loader的FLASH_NOTES和资源基址须一起切换。钢琴manifest绑定音符、Q、步长和输入/镜像hash；吉他工具目前没有同等manifest/32音CLI。量化不饱和、镜像相同、行为模型读回正确分别有用，但都不替代真实音高、稳定性或DAC听测。

### 4.6 调制器（吉他揉弦）的公式

`modulation0` 一次处理一个声部，**只改 a11/a12/a21/a22/wo 五个字段**，而且**只改最低
`MOD_TOP` 个模态**（`MOD_TOP = 4`）；更高的模态一个字段都不写（保持系数表里的基值）。

模型：揉弦主要调**弦张力**，一阶近似下所有模态频率同比例变成 `alpha = 1 + lambda`，
所以每个系数都能写成"基值 + lambda·斜率"（斜率在参数表里，由
`sythsound/guitar_param_gen.py` 生成）：

```
a11' = a11_0 + lambda·S11        a12' = a12_0 + lambda·S12
a22' = a22_0 + lambda·S22        wo'  = wo_0  + lambda·Swo
a21' = −a12'                     （a21 恒等于 −a12，不单独存斜率）
```

一个模态 15 拍（单乘法器串行）：

| 状态 | 干什么 |
|---|---|
| `S_RD` | 给参数表地址（8 个字：4 基值 + 4 斜率） |
| `S_W` | 等两级读延迟，把 8 个参数锁进本地寄存器；`mode >= MOD_TOP` 直接跳 `S_OUT` |
| 4×(`S_LD → S_MUL → S_APPLY`) | `prod = lambda·Sxx`（Q30×Q29 → Q59），右移 31/29/31/30 落到 Q28/Q30/Q28/Q29 并加到基值上 |
| `S_OUT` | 写回 5 个字段；`a21' = −(a12' >>> (SH_A12−SH_A21))`（**a12 是 Q30、a21 是 Q23**，差 7 位） |

**lambda 的映射**（Q30，只做非负方向）：

```
LAM_OFF  = 242                        fmap <= 242 -> lambda = 0（不调制）
LAM_STEP = 0.035·2^30/13 = 2,890,843  fmap = 255 -> lambda = 0.0349999
LAM_MAX  = 13·LAM_STEP
lam_q = (fmap−242 <= 0) ? 0 : ((fmap−242 >= 13) ? LAM_MAX : LAM_STEP·(fmap−242))
```

常数乘法（综合成移位加法，不额外占乘法器）。**负方向禁用**：一阶线性化在
`lambda < 0` 一侧会把某些高模态的 `a12` 推大，使 `det = a11·a22 − a12·a21 > 1`
→ `|eig| > 1` 自激。

为什么只调最低 4 个模态（`_analysis/lam035_ntop.py` 实测，lambda 扫到 0.035）：

| MOD_TOP | max\|eig\| | |
|---|---|---|
| 4 | 0.999987 | ✓ |
| 5 | 1.000005 | ✗ |
| 6 | 1.000056 | ✗ |
| 20 | 1.000851 | ✗ |

高模态的 `theta` 接近 π/2、`a12 = sin(theta)` 贴着 1，一阶展开的二阶误差
~(lambda·theta)² 很容易把它推出稳定域；而揉弦听感主要来自基频和前几个谐波，
所以不动高模态最划算。

**灵敏度公式的坑**（`S12` 曾经小 4~5 个数量级）：`a12` 的硬件域系数是
`k·a12_phys`，而 `k = omega0` 本身随 alpha 变（`k' = k`），所以

```
S12 = a12 + k·d(a12_phys)/d(alpha)
```

漏掉前面那个 `+a12` 时，`S12/a12` 只有 1e-5 量级（`a12_phys = es·sin(theta)/wd`
的 alpha 依赖几乎完全抵消，`theta·cos − sin ≈ −theta³/3`），结果调制只改幅度
（`wo ±3.5%` = 颤音），音高纹丝不动。补上之后 fmap=255 时音高 +59.6 音分。

- **幂等**：基值单独存（参数表的 4 个 `*_0`），重复跑结果一样，不依赖上次写回的值。
- **触发**：`voice_router` 在"起音沿"和"按住期间 fmap 变化"两种情况登记 `mod_req`，
  调制器空闲时按最低位服务。

---
## 5. 设计取舍（为什么这样 + 代价）

- 默认只按 `NOTE_SLOT=4`（按住 HOLD 采样后松开）；`ALL16=1` 才是 16 键同时按下（压力/饱和用例），不再是早期那个 8 音旋律用例。

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
  实测 **526 994 拍 ≈ 5.3 ms**（`SCK_DIV=4`，四线模式）。
**2026-10-28 用 W25Q128 公开行为模型重验**（`_analysis/tb_loader_ref.sv`）：
钢琴表 2048 笔写（1024 系数 + 1024 参数）零差异；吉他表 640 笔零差异；
空片（全 FF）4837 拍、`err=1`、两张表全填 0。

**协议细节（0x6B Fast Read Quad Output）**：
```
CS↓ → 指令 8 SCK（DQ0 单线）→ 地址 24 SCK（**DQ0 单线**，MSB 先）
     → 8 个 dummy SCK（总线交给 flash）→ 数据 4 位并出（每字节 2 SCK）
头部总共 40 个 SCK；`qspi_dq_oe` 只在 beat<32 时驱动
```
之前这里把 24 位地址按"4 位一拍"发了 6 拍（那是 0xEB Quad-I/O 的格式），
配 0x6B 的指令在真芯片上会读错地址 —— 基准模型一挂就露馅了。
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

**两个乐器的端到端实测**（`tb_music`，混响 NONE，0.5 s，24 000 采样）：

| 用例 | n_modes | 峰值（= 满幅的几倍） | 削波 | 仿真墙钟 |
|---|---|---|---|---|
| 钢琴 单音（ADSR） | 64 | 2 985 903 = 0.178 | 0 | 444 s |
| 吉他 单音（无包络、无调制） | 20 | 2 738 927 = 0.163 | 0 | ~460 s |
| 吉他 单音 + 揉弦（λ→0.035） | 20 | 2 923 002 = 0.174 | 0 | ~500 s |
| 吉他 16 音齐响 + 揉弦 | 20 | 12 183 302 = **0.726** | 0 | 808 s |

（"满幅"= Q24 的 1.0 = 16 777 216。）

---

## 7. 测试

### 7.1 音乐集成 TB

当前音乐TB为tb/tb_music.sv，已连接w25q_dut和vendor W25Q128模型，通过实际weight_loader写RAM，并统计16槽×两个半区写口覆盖。源码头部仍有“无Flash模型/直灌RAM”的旧注释，应以实例及加载流程为准。原直灌RAM和常量输出仍被判PASS的发现保留在[28日补测](../../docs/工程评审与验证.md#questa-2026-10-28)，不能混成当前加载方式。

```text
系数镜像 → MEM.TXT → W25Q128模型 ↔ QSPI/weight_loader → RAM
fmap → 激励/包络 → 双bank引擎 → 后级 → y_valid/y_data
                                     → music_dec.txt → 试听WAV
```

case.txt选择钢琴/吉他与压力调制；两者物理存储均64条/槽，实际计算64/20。默认16音吉他区域起点0x010000。DBG打印逐级值与MODTRK；这些为诊断，不是独立数学golden。TB时钟仍10ns而CLK_HZ参数48MHz，逻辑1000拍/样本不能用作真实48kHz整机计时。

### 7.2 运行入口与已知缺口

```powershell
pwsh -File rtl/router/tools/run_all.ps1
pwsh -File rtl/router/tools/run_guitar.ps1
pwsh -File rtl/router/tools/run_loader.ps1
```

这些是已有Windows/Vivado 2017.4入口，本次未运行xsim。**当前run_all未列w25q_dut/vendor模型，也没有准备MEM.TXT；run_loader仍调用被忽略的_analysis/gen_mem.py和mk_blank64.py，吉他参数仍用旧20模态。** 仅在已有work库/本机辅助文件时成功，不表示干净clone可复现。可维护的MEM生成器已在tools/gen_mem.py；修复运行器、统一布局后再完整验证，不用文档声称命令一键通过。

Linux正式接口/配置回归为python3 sim/run_router_midi.py；流水算术与PCM模块为python3 sim/run_audio.py --test eng1 --test bridge。完整音频系统当前受顶层缺端口阻塞，见[sim说明](../../sim/README.md)。

### 7.3 判据与覆盖

音乐TB检查帧数、无X和非零输出，打印削波与峰值；削波统计不拦PASS，WAV导出按峰值归一化。实际loader+Flash模型提供读取/写口证据，仍不证明真片QE/物理时序、全部音高正确或波形golden。独立loader偏移/超时、MIDI生命周期、联合配置、eng1算术和PCM/I2S分别由各自正式TB覆盖，仓库并非只有音乐TB。

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

当前问题只在[bugs](../../docs/bugs.md)维护状态；本节保留本模块的实现约束。

- SLOTS合法值4/8/16，旧n_voices/n_modes/n_samples/X_DEPTH接口已移除。
- 普通reload在持键期间挂起；加载完成必须检查err/table_valid，不可用ready/done假报成功。失败保持静音，显式请求才重试。
- 存储64条/槽与实际计算64/20/48不同；每乐器区域步长由FLASH_NOTES×N_MODES×64决定。
- DEBUG_PORT只返回最近缓存状态，eng0完整波形golden与真实音色bank独立性仍需补充。
- 当前CST缺最终IO_LOC，历史85.44MHz/PnR不是当前整机100MHz签核。
- 揉弦只调最低MOD_TOP=4、lambda<=0.035；历史探针中扩大到5/6模态超出稳定边界。线性化参照及量化后极点/幅度须独立重验，不能只依据guitar_param_gen --verify。
- 当前音频顶层端口缺失、忙时panic回退、持续音色前端、混响宽乘积、调制原子提交及Windows运行器分别见台账，不在这里另维护第二份修复清单。

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
10. **`xvlog` 编译突然变慢（700~1100 s/文件）= work 库坏了**：删掉 `xsim.dir`、`.Xil`、
    `*.jou/*.log` 再来一遍，单文件 2 s、全量 21 个文件 40 s。别怀疑代码。
11. **`tri` 是 SystemVerilog 保留字**（net 类型），`int tri` 直接语法错误；而 xelab 失败后
    再 `xsim` 会**跑旧快照**，看起来"改了没生效"。
12. **参数表不拆 bank**：地址是 `{slot, mode}` = `slot*64 + mode`；系数表才是
    `(slot%8)*64 + mode`。TB 里 poke 用错会把 slot 8~15 盖到 0~7 上。
13. **字段的 Q 不一样**：`a12` 是 Q30、`a21` 是 Q23（`SH_A12 - SH_A21 = 7`）。
    `a21 = -a12` 必须右移 7 位，否则 a21 大 128 倍 → `det > 1` → 自激（表现为
    "只要写系数就爆满幅"）。
14. **数组 poke 要看 `$fscanf` 的返回值**：`_analysis/case.txt` 少一行时后面那个变量
    保持默认值，别指望报错。

---

## 10. 相关文档

- [当前问题与验证缺口](../../docs/bugs.md)：F01–F11 当前状态、新发现和验收边界。
- `rtl/simsynth/ROUTER.md`（已删）：旧版路由器的结构/时序分析，在 git 历史里。

以下为27/28日早期记录：当时未运行音乐xsim/PnR，Questa旧eng1 intended有3个零模态失败、模型33项通过。后续流水已修空作业，当前256组对拍通过；旧结果不代表当前未修。详细日期化结果见[验证记录](../../docs/工程评审与验证.md#verification)及[Questa补测](../../docs/工程评审与验证.md#questa-2026-10-28)。

## 当前MIDI分组装载合同（2026-10-28）

现有midi_voice_top开启`NOTE_BANKS=1`时使用连续32音资源、16个工作槽，`note_bank`选择半区，`first_midi_note`必须匹配镜像清单；默认0兼容旧16音镜像。切组先清理实际声部与内部尾音，再整组装载，成功后提交active；加载失败保持静音并显式重试，不进行跨组动态分配。

weight_loader接收并锁存16×32bit字节偏移、inst及mask，源地址为`inst*(FLASH_NOTES*N_MODES*64)+offset[slot]`，目的仍为`{sel,slot,mode}`。6Bh已改为8串行命令、24串行地址、8 dummy及quad数据，QE由板级初始化提供。范围/对齐/空表/abort/timeout失败将目标填零，done必须结合err判断。支持32音的piano_flash打包器保留默认16音产物不变；正式32音资源和范围尚待确认。

完整接口、故障处理、测试及保留项见[MIDI当前修复](../../docs/MIDI演奏与通信接入.md#midi-bank-fixes)。本轮无新增生产模块，eng0/eng1源码不变；8项Questa和原PAD256点一致性通过不替代真实Flash、满规模吞吐或PCM/I2S验收。

## 联合配置后端（2026-10-28）

midi_voice_top设CONFIG_BACKEND=1后，既有清理/加载状态机接sidebar_system的backend请求/结果，使用实际audio_config_t快照同步音色/通道/来源/音区/混响。sidebar_system同时设AUDIO_BACKEND=1；普通并行配置口不再作为第二个写入者。默认RESOURCE_MASK只开钢琴，音量和调制深度能力保持关闭。完整接线、字段编号、故障和资源限制见[MIDI联合配置实施](../../docs/MIDI演奏与通信接入.md#joint-config-backend)。

voice_router新增table_valid，失败不提交inst_prev、不出音频、不自动重试同一目标；维护及清理操作仍允许真实退休，成功换表首帧重清状态。pad_voice_top引出load_err/table_valid，默认N_MODES统一64。不要再用done表示成功。当前源码已移除忙时panic挂起/抢占逻辑，原取消装载结论仅属于先前快照，须按台账M14复验。新增正式回归见sim说明；核心算法未改。

## eng1五级流水与I2S输出（2026-10-28至29）

eng1已改为R/M/S/N/W五级跨模态流水，II=1，保持原位宽/符号/舍入/饱和，空作业不读写RAM；存储64模态，n_modes_of为钢琴64、吉他20、其余eng1首版48。先前每模态5拍、约24k出样及零模态失败的记录是实施前基线，当前以sim/run_audio.py的生产源回归为准。

音频模块和voice_router.EXTERNAL_SAMPLE_TICK接口仍在；当前midi_voice_top/pad_voice_top缺少AUDIO_ENABLE、audio_clk和I2S实例/端口。恢复接线时应保持I2S帧作为激励/包络/合成统一时基、Q24转PCM16、计划静音和独立诊断的合同；panic音频队列flush仍暂缓。详见[音频说明](../audio/README.md)。

先前接线快照的回归保留于[流水/I2S记录](../../docs/工程评审与验证.md#i2s-pipeline-test)；29日本次256组eng1及PCM模块复测通过，系统展开失败见[最新记录](../../docs/工程评审与验证.md#global-docs-2026-10-29)。尚无统一板级顶层或本次PnR/上板结论。
