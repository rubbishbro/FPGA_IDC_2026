# 共享箱体滤波（body）交付报告

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期：2026-10-04。范围：`rtl/body_design.md`（父会话本轮更新为 68bit/Q34 guard 局部方案）规定的共享 4-biquad 箱体模块、离线 ROM/整数模型、真实 guitar 歌曲闭环集成。**未**迁移噪声/note_off/声部分配/方案C，**未**做四乐器混奏分组，**未**声称 12.5MHz 诊断时钟下的 48k 保真。

---

## 1. 结论摘要

| 项 | 结果 |
|---|---|
| 独立模块 `body_filter.sv` | 4 乐器各冲激/负冲激/阶跃/交替/4096 随机/64bit 饱和/静默，逐帧 `out_sum/out_sat/sat_count` **与每 section 的 x1/x2/y1/y2 内部状态**逐位一致 |
| 单帧周期 | 输入握手到 `out_valid` 最坏 **74** 个核心周期（门槛 ≤128） |
| 隔离 Gowin 100MHz STA | **Fmax 121.176MHz、setup/hold 违反 0、TNS 0**（proj3）；**全 64bit 输出可观测补证 proj4：Fmax 100.266MHz、0/0、最坏 +0.026ns**。仅隔离 body，非完整板 PNR 结论 |
| 父会话独立黄金 `test_body_filter_review.py` | 4 乐器 × 2 用例全过（父会话亲跑为准） |
| 整数模型 vs `scipy.sosfilt` | 峰值误差 ≤ 6.6e-8（门槛 1e-5），20Hz..20kHz 频响误差 ≤ 1.8e-6 dB（门槛 0.01dB） |
| 长静默极限环残余（末 4096 采样） | guitar 4.66e-9 / piano 5.77e-8 / banjo 9.31e-10 / mandolin 4.66e-9，均 ≤2e-7；Q30 原方案 piano 9.19e-7 超门槛（见 §3） |
| 真实 guitar 歌曲端到端（4096 采样，含多事件/重装） | 见 §6（`test_body_demo.py`） |
| 旧 ENABLE_BODY=0 回归 | 见 §6（29 用例基线，默认路径未改） |
| chain `--body`（32 声部，本 DS 预跑） | 512 样本逐位一致，1 次启动欠载、稳定欠载 0；`max modal+body processing = 1032` 周期（预算 2083） |

> 本报告的仿真数值均由本 DS 运行；独立验收以父会话亲跑 `sim/test_body_filter_review.py` 及其它复跑为准。

### 1.1 最终版本与校验

父会话只读审查提出 5 项收尾修正（§7 第 5–9 项）、随后针对真实 Gowin 100MHz 失败授权局部流水（§7 第 10–11 项）后，RTL/生成器为最终 **v3（流水线版）**，已整包重跑：模块单测 10/10、独立 review 四乐器各 2/2、拒绝/数值 review 全过、chain `--body` 1/1、隔离 Gowin STA 100MHz 通过。关键文件 sha256：

| 文件 | sha256 |
|---|---|
| `rtl/core/body_filter.sv` | `00d8e13d3d695f14f1b8c709b17c8a923f09968cd737bfcfc77f052ffbcf9456` |
| `python/modal_sim/gen_body_rom.py` | `6e7410048f707c234dc8bc343fcf1ea8cd41cdb85017c868ce618e118a539d51` |
| `python/modal_sim/body_fixed_point.py` | `2ce7c073e7f2306b118d21a60d47ef39d47995396bf5f93b5b71c9816e935769` |
| `rtl/rom/body_coeff.mem` | `64920ba53a4f73a0beee0b544225fabf4d83a4f538269a4307dc14830208e646` |
| `rtl/rom/body_manifest.json` | `77d360a3afe2debd74b691a7045ed5ffbc466c3a7bef846dbc5006c2d123cfdd` |
| `sim/test_body_filter.py` | `8a07a17b0c9f3659649b96077eba6e1bbe2d911ad831b3690bbbe3937111f04d` |

> `body_filter.sv` 在流水实现期间按父会话授权更新（端口/系数/DFI 递推/饱和语义逐位不变，仅改调度）；父会话已备新增 reset phases 64..120 亲跑最终验收。`gen_body_rom.py`/ROM/整数模型未再改动。

> 父会话后续用 `chain-review --body`（原 `Patch.sos` 独立 68Q34 golden）与 `--diagnostic-12m5`（80ns）做完整 chain 亲跑；本报告不替代其结论。

---

## 2. 交付文件

新增：

- `rtl/core/body_filter.sv` —— 共享 4 section DFI 箱体，68×32 共享乘法数据路径。
- `python/modal_sim/gen_body_rom.py` —— 离线生成器（只读 `params.Patch(name).sos`）。
- `python/modal_sim/body_fixed_point.py` —— 独立 DFI 整数模型（可配置 guard bits）。
- `rtl/rom/body_coeff.mem` —— 80×32bit，`inst*20 + section*5 + tap`，tap 顺序 b0,b1,b2,a1,a2。
- `rtl/rom/body_manifest.json` —— 浮点 SOS、量化整数、布局、来源、量化极点半径、文件 hash。
- `sim/test_body_filter.py` —— 本模块 RTL 单测（含逐 section 状态、ROM 缺失、clear/reset/busy、周期）。
- `sim/test_body_model.py` —— 纯 Python：生成器/量化/可重现/非法拒绝 + 整数 vs 浮点 + 长静默极限环。
- `sim/body_helpers.py` —— 共用 `song_player`+2C 整数链 golden（端到端用）。
- `sim/test_body_demo.py` —— 真实 guitar 歌曲 → modal_engine → body → 适配 → FIFO → 标准 I2S 端到端。

修改（仅此一个旧文件）：

- `rtl/audio/audio_demo_core.sv`：新增参数 `ENABLE_BODY`（默认 0）、`BODY_INSTRUMENT`、`BODY_FILE`；新增输出 `body_overflow_sticky`；`ENABLE_BODY=1 && MODE_SONG` 时插入 body。默认 0 时走原路径，旧接口行为不变（仅多一个未连接输出）。

未改：`params.py`、`engine.py`、旧 `fixed_point.py`、`gen_hw_rom.py`、原模态 ROM、`DECISIONS.md`、旧正式 tests、父会话 `*_review.py`、`rtl/platform/*`、`rtl/body_design.md`。

---

## 3. 数值格式（本轮局部修正）

原始局部方案（内部 Q30/signed64）经父会话数值预检发现 piano 静默残余 1.06e-6 > 2e-7，不能靠 zero 阈值或改原浮点参考掩盖。父会话已把正式局部规格更新为：

- 系数：有符号 32bit **Q2.30**，`floor(c*2^30+0.5)`；每 section 存 b0,b1,b2,a1,a2，a0 规范化为 1。越界/非有限/不稳定**拒绝**，不静默夹。
- 外部 `in_sum`/`out_sum`：有符号 64bit、Q30（与 `mix_sum` 一致）。
- 内部：4 个 section 的 x1/x2/y1/y2 及级间均为 **signed(64+4)=68bit / Q34**；首级输入 `in_sum <<< 4`（显式符号扩展后再移，保 64bit 全幅）。
- 乘积：(68+32)=**100bit**，显式符号扩展进入 **104bit** 累加器。
- DFI：`acc=b0*x+b1*x1+b2*x2-a1*y1-a2*y2`；每 section 一次 `(acc+2^29)>>>30` 后饱和到 signed68，更新该 section 历史；仅末级再 `(y+8)>>>4` 转回 Q30 并饱和 signed64。末级转换饱和并入 `out_sat[3]`（与 section3 的 68bit 饱和相或）。
- `out_sat[3:0]` 每 section 至多 1 bit，`sat_count[2:0]` 为其 popcount。

guard 后的极限环残余（末 4096 采样，整数−浮点，归一化单位）：

| 乐器 | Q30 残余 | Q34(+4) 残余 |
|---|---:|---:|
| guitar | 1.07e-7 | **4.66e-9** |
| piano | 9.19e-7（超门槛） | **5.77e-8** |
| banjo | 2.05e-8 | **9.31e-10** |
| mandolin | 7.64e-8 | **4.66e-9** |

Q34 后四乐器均 ≤2e-7。该残余是“整数递推相对浮点的量化误差地板”，不是把递推自动 zero；递推逐帧照常更新。

---

## 4. RTL 结构与接口

端口：`clk/rst_n`、`clear_valid/clear_ready`、`in_valid/in_ready/in_sum[63:0]`、`out_valid/out_sum[63:0]/out_sat[3:0]/sat_count[2:0]`，另加诊断 `coeff_ready`、`coeff_error`。参数 `BODY_INSTRUMENT`（0..3，复位前静态）、`BODY_FILE`、`GUARD_BITS`（默认 4）。

- **共享单逻辑乘法**：一个 `op_c(32) * op_s(68)` 乘积数据路径，顺序调度 4×5=20 个乘积；`sec*5` 动态地址乘法已消除（`tap_idx` 寄存器递增 0..19 选系数，`tap` 寄存器 0..4 选操作数），不再生成 MULT12X12 地址乘法。
- **每乘积 3 级流水**：`S_OP`（寄存 `op_c/op_s/op_sub`）→ `S_MUL`（寄存精确 100bit 乘积）→ `S_ACC`（符号扩展后加减进 104bit 累加器）。乘法和 104bit 加法不同拍。
- **每 section 3 级 round 流水**：`S_RNDA` 寄存 `(acc+2^29)>>>30` → `S_RNDB` 寄存 signed68 clamp → `S_UPD` 更新 x1/x2/y1/y2；末级 `S_FIN` 做 `(y+8)>>>4` 与 signed64 clamp（末级饱和并入 `out_sat[3]`），然后 `S_OUT`。所有中间值都是精确宽整数，无中间 round/clamp/wrap。
- 饱和记录用 4bit 移位寄存器（每个 `S_UPD` 移入当前 section 的 sat68），去掉 `sec==3` 的 CE 比较器；语义与黄金逐位一致。
- 单帧握手到 `out_valid`：20×3 + 4×3(round/update) + FIN + OUT = **74** 拍（实测 74，门槛 ≤128）。
- section 级联：仅末级转 Q30；饱和到 signed68 的值继续喂下一级（与黄金一致）。
- ROM：80×32bit 同步预加载（20 词/乐器），`coeff_ready` 仅在 20 词全部载入后置位；`$isunknown` 检测到缺失/不足的初始化文件时进入 `coeff_error` 且永不 ready，**不伪造零滤波**（综合时该检测按 `` `ifdef SYNTHESIS `` 编译掉）。
- 优先级：异步 `rst_n` 最高（取消任意流水级的在算帧、清全部历史、重跑预加载、无幽灵 `out_valid`）；`clear` 仅空闲接受、只清历史/饱和记录、保留系数，且与 `in_valid` 同拍时优先；忙时 `in_ready=0`，held valid 不会被当成第二次接收。
- `out_valid` 单拍无反压；连续发送方须等 `in_ready`。

---

## 5. 离线生成器

`python/modal_sim/gen_body_rom.py`：

- 对四乐器分别 `Patch(name).sos` 逐系数按 `floor(c*2^30+0.5)` 量化；检查 4×6、a0≠0、有限、int32 范围、量化后 Jury 稳定（`S±a1+a2>0`、`S-a2>0`）与极点半径<1。
- 输出前先在内存完整构建；非法源在写入前抛 `BodyRomError`。每个输出文件写 `*.tmp` 后 `os.replace`（逐文件原子；不是跨两文件的全局事务），manifest hash 由内存内容计算，保证写出的 manifest 与它描述的 words 一致。规格只要求**坏源不污染旧输出**，不要求 OS 失效时的全局事务。
- manifest 含：`fs=48000`；`coeff_bits=32/frac=30`；`external_bits=64/frac=30`；`internal_bits=68/frac=34`、`guard_bits=4`；`product_bits=100`、`acc_bits=104`；布局 `inst*20+section*5+tap`；每乐器原始 **float SOS 4×6**、量化整数、来源 `Patch(name).sos`、量化极点半径；`sos_fit`（Levy/min-phase, order8, body_scale0.3, smooth15）；四个 `<inst>_body.npz` 源文件的 sha256；`coeff_sha256`。
- 可重现：连续两次运行 `body_coeff.mem` 与 `body_manifest.json` 字节一致（sha `64920ba5…`）。

---

## 6. 测试命令、退出码与结果

环境：`export PATH="$HOME/micromamba/envs/torch312/bin:$PATH"`；所有 build 目录绝对、`always=True`、`-g2012 -Wall`、XML 缺失/空/失败非零、有限超时；不写 `sim/results.xml`。

### 6.1 本模块 RTL 单测（`test_body_filter.py`）

命令：`python sim/test_body_filter.py --build-dir /tmp/opencode/body-implementation/final3`（最终 v3 流水版）

- 结果：**10/10 用例通过，退出 0**（4 乐器 × {patterns+state, clear/reset/busy} + 坏 ROM + 负 instrument）。
- 每乐器 **9055 帧**：`out_sum/out_sat/sat_count` 与**每 section 的 x1/x2/y1/y2 内部状态**逐位一致；最坏 **74** 核心周期；饱和数 guitar 495 / piano 806 / banjo 102 / mandolin 538。
- 坏 ROM：`coeff_error=1`、永不 `in_ready`、无输出。负 instrument（`BODY_INSTRUMENT=-1`）同样被拒绝，不被 `&3` 静默折成 mandolin。
- XML：`/tmp/opencode/body-implementation/final3/{inst0..3}/<case>/results.xml`、`.../badrom/run/results.xml`、`.../badinst/run/results.xml`。

### 6.2 父会话独立 review（`test_body_filter_review.py`，亲跑为准）

命令：`python sim/test_body_filter_review.py --instrument i --build-dir /tmp/opencode/body-review/i`

- 本 DS 复跑（最终 v3 流水版）：四乐器各 **2/2 通过，退出 0**；guitar 4713 帧逐位一致、最坏 74 周期、1 次 section 饱和；piano 14、banjo 6、mandolin 11。
- 父会话已亲跑同一 review 四乐器，各 2/2、退出 0，并增加了每帧 4 section 的 x1/x2/y1/y2 signed68 状态独立逐位核对；日志 `/tmp/opencode/body-review-parent-{piano,banjo,mandolin}.log`。父会话将用新增 reset phases 64..120 对最终流水版再亲跑。
- 拒绝 review `test_body_rejection_review.py`：1/1、退出 0（负/越界 instrument、缺文件、短文件四配置均不 ready 且有 error）。
- 数值 review `test_body_numeric_review.py`：3/3、退出 0。
- XML：`/tmp/opencode/body-review/final3_{0..3}/results.xml`、`/tmp/opencode/body-review/final3_rej/**/results.xml`。

### 6.3 纯 Python 模型/生成器（`test_body_model.py`）

命令：`python sim/test_body_model.py`

- 结果：全部 check 通过，退出 0（量化/布局/hash/可重现/非法拒绝；整数 vs scipy；长静默极限环）。

### 6.4 真实 guitar 端到端（`test_body_demo.py`）

命令：`python sim/test_body_demo.py --build-dir /tmp/opencode/body-implementation/body_demo`

- 结果：**1/1 PASS，退出 0**。`4096` 采样逐位一致（`ENABLE_BODY=1, BODY_INSTRUMENT=0`），含多次事件与声部重装、箱体历史不重置。
- 启动：`startup underflow=1`，2 个前导静音帧；稳定期 `underflow=0`。
- 预算：engine max busy **254** 核心周期、body max latency **75** 核心周期（frame budget 2048）。
- 诊断：`deadline_error=0`、`tx_overflow_sticky=0`、`body_overflow_sticky=0`、`engine_error_valid=0`。
- XML：`/tmp/opencode/body-implementation/body_demo_final3/results.xml`。

### 6.5 旧 ENABLE_BODY=0 回归基线（29 用例 = transport 20 + song_player 5 + audio_demo 4）

| 命令 | 结果 | 退出 |
|---|---|---|
| `python sim/test_song_player.py --build-dir /tmp/opencode/body-implementation/baseline_song_player` | **5/5 PASS** | 0 |
| `python sim/test_audio_transport.py --build-dir /tmp/opencode/body-implementation/baseline_audio_transport` | **20/20 PASS**（16 main + 4 mic） | 0 |
| `python sim/test_audio_demo.py --build-dir /tmp/opencode/body-implementation/baseline_final3` | **4/4 PASS**（mock SONG / playback_ready / MIC / real engine） | 0 |

> 默认 `ENABLE_BODY=0`，`audio_demo_core` 走原路径；real-engine 4096 采样仍逐位一致、steady underflow=0、engine max busy=254。旧 XML/行为不变。流水版 body（`ENABLE_BODY=1`）IDC demo 同样 4096 采样逐位一致、body max latency 75。

（XML 路径为绝对 build 目录下 `results*.xml`；不写 `sim/results.xml`。）

### 6.6 父会话 chain review `--body`（本 DS 预跑；父会话最终亲跑为准）

命令：`python sim/test_audio_chain_review.py --body --samples 512 --gap 16 --voices 32 --build-dir /tmp/opencode/body-implementation/chain_body_final3`

- 结果：**1/1 PASS，退出 0**。32 声部、512 golden 样本、33 事件、513 解码 I2S 帧、1 次启动欠载、**稳定期欠载 0**；`body=1`，`max modal+body processing = 1032` 核心周期（12.288MHz 预算 2083）。
- golden 来自原 `guitar_coeff.mem` 与独立 68Q34 body 公式；body Q30 输出与 PCM 全部逐样本一致。
- XML：`/tmp/opencode/body-implementation/chain_body_final3/results.xml`。
- 父会话另有 `--diagnostic-12m5`（80ns/48.828125kHz）与新增 reset phases 的亲跑，本报告不替代。

### 6.7 隔离 Gowin 100MHz 综合/P&R（临时 top，非生产 platform）

临时目录 `/tmp/opencode/body-timing`（独立、不与板 DS 的 `build/gowin` 共用）：`body_timing_top.sv` 只实例化真实 `rtl/core/body_filter.sv`（真实只读 `rtl/rom/body_coeff.mem`），CST 用真实板 pin 模板（clk=P16、rst=U4、PMOD2 C21/B20/B19/A17），SDC 直接 `create_clock -period 10`。

| 项 | 值 |
|---|---|
| 工具/目标 | Gowin V1.9.12.04；GW5AST-LV138FPG676AES，Device Version B（AES/ES） |
| 延迟模型 | setup Slow 0.873V 0C ES；hold Fast 0.927V 85C ES |
| 约束 | 单一 `clk` 10.000ns（100MHz）；无其它时钟 |
| Actual Fmax | **121.176 MHz**（Level 3） |
| Setup/Hold 违反端点 | **0 / 0**；TNS setup/hold = 0.000 |
| 最坏 setup | +1.748ns：`sec[0] → state[3]/D`（FSM 次态逻辑），8.051ns data |
| 最坏 hold | +0.237ns：`pre_idx → coef SDPB/ADA`，0.274ns data |
| 资源 | Logic 1461（1156 LUT + 305 ALU）、FF 1506、BSRAM SDPB 2、DSP 6（MULT27X36 3）、CLS 3%、I/O 6 |
| 报告 | `/tmp/opencode/body-timing/proj3/body_timing/impl/pnr/body_timing.{tr,rpt.txt}`；日志 `/tmp/opencode/body-timing/gowin3.log` |

边界：这是**隔离 body** 结果，不是完整板最终 PNR/时序结论。临时 SDC 只约束内部 100MHz 时钟，可观测输出脚未加 output delay（它们只是防止优化的观测位，不在 body 时序契约内）；报告无未约束内部端点。完整板（含模态引擎/地址控制）的合并验时由父会话/板 DS 负责，本报告不声称已通过。

**完整输出可观测性补证（proj4）**：proj3 的 harness 只驱动 `out_sum[2:0]` 到引脚，故 `out_sum` 高 61bit 与部分输出适配寄存器**理论上**可能被优化掉——它作为“完整 64bit 输出接口”的孤立证据不充分。父会话指出后，仅在临时 harness（不改最终 RTL）改进：把**全部 64bit `out_sum`、4bit `out_sat`、3bit `sat_count`、`out_valid` 及 `coeff_ready/coeff_error`/握手位**异或进寄存器奇偶累加器 `par_sum/par_sat/par_cnt/par_ctl`，再折叠到 4 个真实 PMOD2 引脚。proj4 独立 synth/P&R 100MHz：

| 项 | proj3（仅低 3bit 观察） | proj4（全输出观察） |
|---|---|---|
| Actual Fmax | 121.176 MHz | **100.266 MHz** |
| Setup/Hold 违反端点 | 0 / 0 | **0 / 0**，TNS 0.000 |
| 最坏 setup | +1.748ns `sec→state[3]/D` | +0.026ns `sec[0]→n30701/A[10]`（操作数 mux→DSP 输入） |
| 最坏 hold | +0.237ns `pre_idx→coef` | +0.247ns `yout_19→out_sum_19/D`（末级输出寄存在场） |
| 资源 | Logic 1461 / FF 1506 / DSP 3×MULT27X36 | Logic 1667 / FF 1701 / DSP 3×MULT27X36 / BSRAM 2 |
| 报告 | `…/proj3/…/body_timing.tr` | `…/proj4/…/body_timing.tr`，日志 `gowin4.log` |

proj4 仍**通过** 100MHz（正裕量、0 违反），且额外证明 **body 的 64bit 输出/适配寄存器未被优化**（`yout[19]→out_sum[19]` 出现在 hold 路径即为其保留证据）。proj4 的 worst setup **0.026ns 裕量很小**，但路径仍在 body 数据通路内（`sec` 选择→操作数→DSP），不是观测器自身路径；观测器本身仅 1 个 XOR 级（`par_ctl_6` hold 0.247ns 为普通 FF 反馈）。proj3 证据保留，如上标注其局限。**两者都不等于完整板最终时序通过**，全板完整接口仍须父会话/板 DS 合并后重验。

> 过程记录：仅“syn/PnR 返回 0”不作为通过。首版流水（3 拍/乘积，单拍 round）隔离 Fmax 100.309MHz、setup 违反 0、最坏 +0.031ns；round 再流水后 proj2 Fmax 100.673MHz、最坏 +0.067ns；再去掉 `sec==3` CE 后 proj3 **Fmax 121.176MHz、最坏 +1.748ns**。三轮均读实际 `.tr` 判定，未用退出码冒充时序通过。

---

## 7. 修复闭环

| # | 缺陷 | 定位与修复 |
|---|---|---|
| 1 | 末级 round 常量错造为 1 而非 `2^(G-1)=8`，guitar 第 6 帧差 1 LSB | `FINAL_RND` 拼接改为 `{1'b1,{(GUARD_BITS-1){1'b0}}}`；父会话 review 转 4/4 通过 |
| 2 | 首级 guard 左移在 64bit 内发生会截断全幅输入 | 改为显式 68bit 符号扩展后再 `<<<4` |
| 3 | manifest 布局字符串写成 `*16`（实际 `*20`） | 生成器布局串改为 `instrument_index*20`，重生成 manifest |
| 4 | 端到端测试用相对模态 ROM 路径，vvp cwd 下找不到 | `test_body_demo` 传绝对 `COEFF_FILE/INDEX_FILE/BODY_FILE` |
| 5 | 父会话审查：`S_PRE` 只判 `BODY_INSTRUMENT>3`，`-1 & 3` 会被静默折成 mandolin | 改为 `(BODY_INSTRUMENT < 0) || (BODY_INSTRUMENT > 3)` 拒绝；`test_body_filter` 新增负参数用例 `body_bad_instrument` |
| 6 | 注释称“single physical 68x32 multiplier”，不能保证只用一个物理 DSP | 改为“single logical 68x32 multiplier data path…Gowin may split a wide DSP” |
| 7 | `gen_body_rom` / `body_fixed_point` docstring 布局仍写 `instrument*16` | 改为 `instrument*20`（代码本就是 20） |
| 8 | `write_products` 注释夸称两文件“绝不出现新旧混合” | 改为逐文件写临时+替换、校验先于写入的承诺，明确两 `os.replace` 非全局事务 |
| 9 | manifest 只有 `state_bits64/frac30` | 增加 `external64/Q30`、`internal68/Q34/guard4`、`product100/acc104`、`fs48000`、每乐器 float SOS 4×6、`sos_fit`、源 `<inst>_body.npz` sha256；不再声称内部 Q30 |
| 10 | 真实 Gowin full-body 100MHz 失败（旧路径 19.635ns）：报告的 `n41_s` 实为 `sec*5` 的 MULT12X12 地址乘法，并与 68×32 宽乘法、104bit acc 同拍 | 消除 `sec*5`（寄存器 `tap_idx` 0..19 选系数、`tap` 0..4 选操作数）；`S_OP`→`S_MUL`→`S_ACC` 三级流水，寄存精确 100bit 乘积、104bit 加法独立成拍；**不改端口/系数/DFI/饱和语义** |
| 11 | 乘积/acc 分开后 round/clamp 链成最坏（首版 +0.031ns、round 再流水后 +0.067ns，隔离刚过） | round 拆 `S_RNDA/S_RNDB/S_UPD/S_FIN`；饱和记录改 4bit 移位寄存器去掉 `sec==3` CE；隔离 proj3 **Fmax 121.176MHz、setup/hold 违反 0、最坏 +1.748ns**（无需手动 partial-product/CSA，Gowin 自身用 3×MULT27X36 完成 68×32） |

---

## 8. 未完成 / 边界（明确不在本轮）

- 噪声支路仍按 `engine.py` 独立成型后相加，本轮**未**搬进箱体前；不声称完成原算法全部迁移。
- note_off/release、方案C kill 的定点迁移未做。
- 四乐器混奏分组未做；本轮演示仅 guitar（BODY_INSTRUMENT=0）。
- 平台/Gowin：`rtl/platform` 未改，BODY 开关与真实综合/布局布线由父会话在功能审查后协调；旧的 ROM 未加载 provisional bitstream 不作为本模块硬件结论。
- 隔离 Gowin body STA 通过（Fmax 121.176MHz、0 违反）**不等于完整板最终 PNR/时序通过**：完整工程仍含模态引擎的地址/控制路径（板 DS 正在优化）和顶层 `playback_ready→amp_sd` 等路径；body 与全量合并后的时序由父会话/板 DS 重验。
- 12.5MHz 音频时钟仅出声诊断，箱体参考仍 48kHz，未据此改 SOS/系数。
- 上板出声/完整 part 由实物验收。
