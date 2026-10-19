# 统一 IIR 合成数据格式与 C 类设计（讨论稿）

**日期**：2026-10-19  
**状态**：讨论稿，**未冻结**；只做格式/架构设计，未改 RTL、ROM、Python、NPZ、约束或下载文件。  
**更新（2026-10-19）**：按“C 截 48 模态 / 删除 B ext / C seed 走状态写口”修订；§0/§1/§3.2/§4.2–4.7/§6.3/§7.3–7.4/§8/§9/§11/§12/§13/§14/§15 已同步。  
**范围**：现有三系数 IIR 模态引擎（ENG1：`modal_engine` / `modal_poly_bank`）的 **A/B/C 三类**。  
**不在范围**：`rtl/simsynth` 的 7 字段物理引擎（ENG2，见[双引擎统一顶层架构](双引擎统一顶层架构.md)）；A 的 note-off/噪声/抢占；B 的气息/弓噪默认开启（G6）；C 的 room/reverb。

本文把“A/B 类统一数据格式”和“C 类设计”放在同一份契约里：先定义三类共用的记录、键、装载事务、力度语义和位宽，再说明每一类只在哪些字段上不同。凡标“建议”的，都是给作者冻结用的候选，不是已实现事实。

---

## 0. 一页结论

1. **统一的是“记录格式、键空间、装载事务、力度语义、控制块和路由”，不是把三类算法塞进同一个 always 块。** 算术核心保持冻结：72-bit 系数 word、Q2.30 状态、64-bit 单模态累加、4 lane、II=3。
2. **类只改变五件事**：激励 `x` 从哪来、起振方式（C 的 seed 写状态槽）、每声部控制块、后级路由（A 过 body，B/C 旁路）和噪声支路。
3. **力度拆成 `layer`（采样层，2-bit）＋`velocity`（连续幅度，8-bit）**。A 现在的 1-bit `dyn` 升级为 `layer`；B 的 mezzo-forte 有位置；C 只用一个采样层但保留连续力度。硬件对缺失 key **严格拒绝**，不做近音/换档回退。
4. **索引统一为 48-bit**：`present / n_modes / mode_offset / ctrl_index / version / flags / layer / class`。A/B/C 物理上分表，但每个表用同一种 index word 和同一套查表/校验流程。
5. **模态核心 72-bit 完全不变，记录流里不再有每模态扩展字**。B 的 `c1/c2` 删除（颤音/滑音由表情层给 `ratio`，刷新引擎从 `a1/a2` 反解 `θ/r` 后按 `a1=-2r·cos(ratio·θ)` 现算）；C 的 seed 不走记录流，直接写进现有状态槽 `{8'b0,y2,y1}`（装载侧写口；数据源可预生成或运行时生成）。
6. **C 类 = 共享递推 + 每模态 seed（随机相位）+ 每 piece 噪声 FIR + 一次性包络/定时器**。C 的模态部分与 A/B 同一条递推；差别是 `x=0`、初值非零、输出加噪声。C 截到 **48 模态**后听感验收通过（kick/snare/hat 均可用），全局 `N_MODES` 保持 **48**，三类模态数一致。
7. **容量模型仍是“声部上限 + 活跃模态预算”**：`NUM_VOICES=32`、`N_MODES=48`、`M_ACTIVE_MAX=1536`（A14+B10+C8 的上界，等于现 32×48）。分配器保证 `Σ n_modes(active) ≤ 1536`，周期基线不升。
8. **C 建议先做“常驻鼓组”**：8 个 C 声部在启动时各装好一个 piece 的系数；每次 hit 只写 48 个 seed 和计时器，不重装系数。这样避免 48 模态的实时装载和 216 周期/音的旧瓶颈。
9. **分阶段**：F0 冻结格式 + Python 打包/整数参考 → F1 A 走统一 loader 但逐位不变 → F2 B-L0（静态持续音）→ F3 C-L0（常驻鼓组 + 噪声）→ F4 B-L1（表情层 ratio/刷新）/C-L1（全相位/全噪声）。
10. **最大风险仍是时序**（现 setup 最坏 +1 ps）**和装载带宽**，不是 BSRAM/DSP 容量；每加一级都要真实综合/P&R，不能从面积推断时序。

---

## 1. 现状：三类为什么不统一

| 项 | A（拨/击） | B（持续音） | C（打击乐） |
|---|---|---|---|
| 现有 RTL | `modal_engine` + `modal_poly_bank` + `body_filter` | **无**，只有 `sustain_engine.py` | **无**，只有 `drumkit.py` |
| 键 | `{inst[1:0], midi[6:0], dyn[0]}`，index 20-bit | Python `(midi, dynamic)` 字符串 | Python `piece` 名 + 连续 velocity |
| 力度 | `dyn` 1-bit（piano/forte），RTL 歌曲固定 forte | 采样层 forte/mezzo-forte + 连续 `vel` | 只有一个采样层，连续 `vel` 缩放 |
| 模态数 | 48 | 48（表内最大 48） | **48**（截到 48 后听感验收通过） |
| 系数 word | 72-bit `G/a2/a1` | 同 A | 目前是浮点 `a/gamma/f`，尚未定点化 |
| 状态 | Q2.30 `y1/y2` | 同 A | 加性 `a·e^{-γt}·sin(2πft+φ)`，无递推状态 |
| 激励 | 7/12 样本升余弦，幅度 0.2 | 整数周期冲激串 × AR 包络 × AM | 一次性；模态初值 + 噪声 burst |
| 每模态扩展 | 无 | 无（表情层按 ratio 重算 a1） | 无（seed 写状态槽） |
| 装载 | note-on 时 216 周期/音 | 无 RTL；B 文档建议预装/burst | 无 RTL；建议常驻 + seed 写口 |
| 后级 | guitar body | 建议旁路 body | 建议旁路 body |
| 表 | 5,483 词 / 250 key | 5 种全动态 7,624 词 / 288 key | 6 piece / ≤288 个实际模态（按 6×48=288 分配） |

不统一的核心不是“代码写得不一样”，而是**六件事没有共同契约**：

1. 键的位宽/命名空间不同（2-bit 乐器、1-bit 力度，但三类模态数现在都是 48）。
2. 力度把“选哪张表”和“弹多响”混在一个 `dyn`/`vel` 里。
3. 三类起振方式没有统一契约：A 靠脉冲、B 靠冲激串、C 靠每模态 seed，而 seed 无处可放（不走 `x`）。
4. 激励接口只有 `x_vec`，没有“这个声部属于哪一类、x 应该由谁产生”的元数据。
5. 装载只有 A 的“查 index → clear → cfg”一条路，B/C 的 seed/控制/噪声没有事务语义。
6. 输出路由和增益没有类字段（A 走 body，B/C 应旁路；C 还要加噪声）。

---

## 2. 设计原则

1. **一个算术核心**：所有类都执行 `y[n] = G·x[n] − a1·y1 − a2·y2`；不改 Q 格式、舍入、饱和和 II=3。
2. **类是数据，不是数据通路**：`class` 是 2-bit 字段；类只选择激励生成器、控制块字段、后级路由和起振方式（seed）。
3. **物理表分开，逻辑格式统一**：A/B/C 各自 ROM（A 原表可不动），但 index/control/core 的字段布局相同；记录流不再有每模态扩展字。
4. **严格键**：硬件对 `(class, instrument, note, layer)` 做精确查表；缺项拒绝、保留原声部，不找近音、不换档。
5. **装载原子**：先完成 index/control/范围校验，再 clear/cfg/seed；失败不产生任何写副作用。
6. **确定性定点**：每个控制量都有冻结的 Q 格式；浮点只做参考，RTL 与 Python 整数模型逐位对拍。
7. **A-only 逐位兼容**：新格式的默认字段（class=A、layer=forte、velocity=255、pulse_scale=0.2、pulse_len=7）必须让现 v5 歌曲输出逐位不变。
8. **容量按“活跃模态”而不是“声部×最大模态”算**：C 的模态数降到 48 后，最坏预算回到 1,536 模态，周期不升。

---

## 3. 统一数据模型

```text
事件 Event{class, layer, instrument, note, velocity, gate, note_id}
   │
   ├─ 键 Key{class, instrument, note, layer}
   │     ↓ 查 class 对应的 index ROM
   │  Index{present, n_modes, mode_offset, ctrl_index, version, flags}
   │     ↓
   │  Control[256]  每键的静态控制参数（T/attack/release/piece_gain/noise...）
   │     ↓
   │  Mode core[72] × n_modes    （G/a2/a1，三类共用）
   │  Seed[n]        （仅 C；写状态槽，可预生成或运行时生成，不是记录扩展）
   │     ↓
   └─ Voice runtime{class, n_modes, velocity, env/phase/timer/pulse_pos,
                     ratio/lfo/glide, θ/r 或 a1 影子, seed_cnt}
         ↓ 每采样
      x_v = class 激励生成器（A 脉冲 / B 冲激串×包络×ratio / C 0）
         ↓
      modal bank（4 lane，共享）
         ↓ voice_sum
      class 后级（A body；B/C bypass；C 加噪声）
         ↓
      master gain/limiter → i16 → FIFO → I2S
```

**“Patch”就是一份键对应的完整数据**：index + control + n 个 core（C 另有 seed 表）。装载一份 patch 就是建立一个 voice 的“是什么声音”；之后每采样的 `x`、表情 `ratio` 和生命周期由 voice runtime 决定。

### 3.1 命名

| 名称 | 含义 |
|---|---|
| `class` | 0=A 拨/击；1=B 持续；2=C 打击；3=保留 |
| `layer` | 采样层：0=piano，1=mezzo，2=forte，3=保留 |
| `velocity` | 连续力度 0..255；不是采样层 |
| `patch` | 某键的 index+control+core（C 另有 seed 表） |
| `voice` | 一个发声槽；三类共用 32 个槽 |
| `mode` | 一个二阶谐振器；A/B/C 同一个递推 |
| `seed` | C 的每模态初值 `y1/y2`，不是激励 |

### 3.2 类差异只允许出现在这五处

| 位置 | A | B | C |
|---|---|---|---|
| 激励 `x` | 7/12 样本升余弦 | 冲激串 × AR 包络 × velocity × AM，速率×ratio | 模态 `x=0`，靠 seed 起振 |
| 起振方式 | 脉冲（无初态） | 冲激串（无初态；a1 影子是运行态） | seed 写状态槽 `{y2,y1}` |
| 控制块 | `pulse_len` | `T/attack/release`（表情参数走 EXP 预设） | `piece_gain/noise/timer/variant` |
| 噪声支路 | 不用 | 可选（G6 默认关） | 必用（每 piece FIR） |
| 后级 | body（guitar） | bypass | bypass |

---

## 4. 位级格式

### 4.1 事件 Event（64-bit）

| 位 | 字段 | 宽度 | 说明 |
|---|---|---:|---|
| `[1:0]` | `class` | 2 | 0=A，1=B，2=C，3=保留 |
| `[3:2]` | `layer` | 2 | 0=p，1=mf，2=f，3=保留 |
| `[7:4]` | `instrument` | 4 | A：0..3；B：0..7；C：kit id（0=默认） |
| `[14:8]` | `note` | 7 | MIDI 0..127；C 用 GM 打击乐 note |
| `[15]` | `gate` | 1 | 1=on，0=off |
| `[23:16]` | `velocity` | 8 | 0..255，连续 |
| `[35:24]` | `note_id` | 12 | 事件身份；同音重叠/精确 off 用 |
| `[37:36]` | `event_type` | 2 | 0=ON，1=OFF，2=RETRIG，3=CANCEL |
| `[53:38]` | `timestamp` | 16 | 可选：采样计数低 16 位，用于队列排序/延迟统计 |
| `[63:54]` | 保留 | 10 | 置 0 |

**OFF/CANCEL 只使用 `event_type` + `note_id`**；其余字段忽略，但保留统一布局，方便 FIFO 固定宽度。

**RETRIG 语义**：同一个 `note_id` 重新开音；A 重新武装脉冲，B 重置包络但保留相位（可配置），C 重新写 seed/清计时器。是否允许 RETRIG 由类决定；首版 A/B 只用 ON/OFF，C 用 ON + choke。

### 4.2 键与索引 Index（48-bit）

**键**：`Key = {class[1:0], instrument[3:0], note[6:0], layer[1:0]}`。

物理地址按类分开：

| 类 | index 地址 | 深度 | 说明 |
|---|---|---|---|
| A | `{inst[1:0], midi[6:0], layer[1]}` | 1024 | 先拒绝 layer=1/3；layer 0→0、2→1，用 `layer[1]` 而不是 `layer[0]` |
| B | `{inst[2:0], midi[6:0], layer[1:0]}` | 1,280（5 乐器 ×128×2；可补到 2,048） | 物理深度按实际表补；超出深度的地址视为空项 |
| C | `{kit[2:0], midi[6:0]}` | 128（kit 0） | layer 由 flag 忽略；GM 别名指向同一 offset |

**Index word（48-bit，三类同格式）**：

| 位 | 字段 | 宽度 | 说明 |
|---|---|---:|---|
| `[47]` | `present` | 1 | 0=空；空项必须拒绝 |
| `[46:40]` | `n_modes` | 7 | 1..48；0 非法；>N_MODES 非法 |
| `[39:26]` | `mode_offset` | 14 | core 词起始地址（16,384 词） |
| `[25:14]` | `ctrl_index` | 12 | control 记录索引（4096 条） |
| `[13:12]` | `version` | 2 | 0=仅 core；1=保留（原 B ext，已删除）；2=C seed（可选 seed 表）；3=保留 |
| `[11]` | `has_control` | 1 | 0 时用类默认控制块 |
| `[10]` | `has_seed` | 1 | 与 C 的 seed 表存在性一致，冗余校验 |
| `[9:8]` | `layer` | 2 | 与键一致，自检 |
| `[7:6]` | `class` | 2 | 与键一致，自检 |
| `[5:0]` | `flags` | 6 | bit0=body_bypass，bit1=noise_en，bit2=layer_ignore，bit3=choke，[5:4]保留 |

**校验顺序**（全部在 clear 之前）：

1. `present==1`；
2. `1 ≤ n_modes ≤ N_MODES`；
3. `mode_offset + n_modes ≤ COEFF_DEPTH`；
4. `version` 合法，且与 `has_seed`/seed 表深度一致；
5. `ctrl_index` 在 control 表范围内，`has_control` 时 control 记录 `class/layer` 与键一致；
6. seed 地址（C：`piece*V*N_MODES + variant*N_MODES + n_modes`）在 seed 表范围内；B 无扩展表，不检查。

任一失败 → `error` 单拍，返回 idle；**不 clear、不 cfg、不 seed、不写控制块**。

**A 的兼容特例**：首版可以让 A 继续读旧 20-bit index，由 loader 在内部合成 48-bit 视图（`class=A`、`layer=dyn?2:0`、`ctrl_index` 指向默认 A 控制、`version=0`）。这样 A 的 index/coefficient ROM 都不用改，先把统一 loader 和 B/C 接进来；F1 之后再决定是否生成统一 A index。

### 4.3 控制记录 Control（256-bit，4×64）

Control 是**每键静态参数**，不是每模态。低 64 位为公共头，其余按 `ctrl_format` 解释。只对存在的 key 存记录（稀疏 ctrl 表），不按 128×层数 稠密分配。

**Word 0（公共头）**：

| 位 | 字段 | 宽度 | 说明 |
|---|---|---:|---|
| `[1:0]` | `class` | 2 | 自检 |
| `[3:2]` | `layer` | 2 | 自检 |
| `[7:4]` | `instrument` | 4 | 自检 |
| `[15:8]` | `ctrl_format` | 8 | 0=A，1=B，2=C；其余保留 |
| `[31:16]` | `key_gain` | 16 | UQ1.15，默认 32768（1.0） |
| `[35:32]` | `flags` | 4 | bit0=body_bypass，bit1=noise_en，bit2=choke_en，bit3=reserved |
| `[38:36]` | `choke_group` | 3 | 0=无；1=hi-hat；其余保留 |
| `[58:39]` | `tail_samples` | 20 | 1..1,048,575 采样（约 21 s） |
| `[63:59]` | 保留 | 5 | 置 0 |

**A payload（word1）**：

| 位 | 字段 | 宽度 | 说明 |
|---|---|---:|---|
| `[3:0]` | `pulse_len` | 4 | 7=forte，12=piano（G2） |
| `[19:4]` | `pulse_scale` | 16 | UQ1.15，默认 0.2（见 §5.4） |
| 其余 | 0 | | |

**B payload（word1–3）**：

| 位 | 字段 | 宽度 | 说明 |
|---|---|---:|---|
| `[15:0]` | `period_T` | 16 | 整数周期 `T=round(fs/f0)`；L0 用 |
| `[39:16]` | `attack_step` | 24 | UQ0.24，`1−α_attack` |
| `[63:40]` | `release_step` | 24 | UQ0.24，`1−α_release` |
| `[119:64]` | 保留 | 56 | 原 `vib_inc/vib_depth/am_depth` 已移出，见下方“表情参数” |
| `[135:120]` | `noise_gain` | 16 | UQ3.13（0..8）；G6 默认 0；试验值可到 5.0 |
| 其余 | 0 | | |

**表情参数不在这里**：颤音速率/深度、AM、滑音时间、弯音范围是“怎么演奏”，不是“这个键是什么”。它们走 EXP 预设（每乐器一条，可由 UI/摇杆实时改），不随每个键存；同一音符因此可以用不同表情演奏。

**C payload（word1–3）**：

| 位 | 字段 | 宽度 | 说明 |
|---|---|---:|---|
| `[15:0]` | `piece_gain` | 16 | UQ3.13，0..8；含 `_piece_norm×KIT_GAIN` |
| `[31:16]` | `noise_gain` | 16 | UQ3.13（0..8），来自 `drums.npz` 的 `noise_gain` |
| `[47:32]` | `noise_env_gamma` | 16 | UQ8.8 s⁻¹；当前 0.7..40.7 |
| `[63:48]` | `noise_att_gamma` | 16 | UQ8.8 s⁻¹；无 attack 时 0 |
| `[79:64]` | `noise_att_amp` | 16 | UQ4.12（0..16），当前 ride 8.826、crash 0.396 |
| `[95:80]` | `noise_lf_gamma` | 16 | UQ8.8；当前数据全为 0（单段） |
| `[111:96]` | `noise_hf_gamma` | 16 | UQ8.8；当前数据全为 0 |
| `[115:112]` | `noise_filter_id` | 4 | 噪声 FIR 页号（16 页） |
| `[117:116]` | `variant_count` | 2 | 1..4；每 hit 轮换 seed 变体 |
| `[118]` | `choke_en` | 1 | hi-hat choke |
| `[119]` | 保留 | 1 | |
| `[139:120]` | `length_samples` | 20 | 渲染长度/回收计时器 |
| 其余 | 0 | | |

> 256-bit 是“够用且好对齐”的选择；实际只存存在的 key（A 250、B 288、C 6），约 544×32 B ≈ 17 KB ≈ 136 kbit，约 8 块 18 kbit BSRAM。

### 4.4 模态核心 Mode core（72-bit，不变）

```text
[71:46] G   Q2.24 signed 26
[45:22] a2  UQ0.24 unsigned 24
[21:0]  a1  Q2.20 signed 22
```

与 `python/modal_sim/fixed_point.py:pack_word()`、现 `rtl/rom/modal_coeff.mem`、`coeff_loader` 完全一致。B 的 72-bit word 也用它；C 的 `a1/a2` 用 `f/gamma` 算，**`G=0`（seed 路径）**。

### 4.5 扩展字 Extension（已取消）

记录流里不再有每模态扩展字。曾计划放在这里的两类数据，现在都有了别的落点：

| 原计划 | 现在 |
|---|---|
| B `c1/c2`（48-bit，a1 刷新） | **删除**。表情层给 `ratio`，刷新引擎在 note-on 从 `a1/a2` 反解 `r=sqrt(a2)`、`θ=acos(-a1/(2r))`，每 tick 算 `a1=-2r·cos(ratio·θ)`；`a2` 不变。 |
| C `y1/y2` seed（64-bit） | **不进记录流**。装载侧 seed 写口直接写状态槽 `{8'b0,y2,y1}`；数据源可预生成 seed 表（`c_seed.mem`，可选）或运行时 LFSR 生成。 |

- `version` 字段保留，但不再表示 ext 宽度：0=A/B，2=C（有 seed），1/3 保留。
- C 的 seed 表地址 `piece*V*N_MODES + variant*N_MODES + mode`（V 最大 4），与 core 地址 `mode_offset+mode` 独立。
- 三类共用同一条 72-bit core 流；loader 不需要 ext 步骤，只多一个可选的 seed 阶段。

### 4.6 每声部运行状态 Voice runtime

只列新增/关键字段；其余沿用现有 bank 的 `state_valid`、`y1/y2`。

| 字段 | 宽度 | 类 | 说明 |
|---|---:|---|---|
| `class` | 2 | 全 | 路由/激励选择 |
| `instrument` / `note` / `layer` | 4/7/2 | 全 | 元数据 |
| `n_modes` | 7 | 全 | 本声部模态数 |
| `velocity` | 16 | 全 | UQ1.15 |
| `key_gain` | 16 | 全 | UQ1.15 |
| `note_id` | 12 | 全 | 事件身份 |
| `gate` / `active` / `loaded` | 1×3 | 全 | 生命周期 |
| `pulse_pos` / `pulse_len` | 4/4 | A | 当前脉冲位置 |
| `period_T` | 16 | B | L0 整数周期 |
| `phase` / `inc` | 32/32 | B | L1 分数 NCO |
| `env` | 32 | B | UQ0.32 |
| `ratio` | 16 | B | UQ1.16，表情层输出（颤音+滑音+弯音）；切 UQ2.14 只改常量和饱和 |
| `lfo_phase` / `lfo_inc` | 24/24 | B | 颤音/漂移冻结振荡器 |
| `glide_target` / `glide_step` | 16/16 | B | 滑音目标/速率 |
| `bend` | 16 | B | Q7.9 cents，摇杆/弯音 |
| `theta` | 14 | B | 放 a1 影子剩余 14 bit：4-bit 指数 + 10-bit 尾数；`r` 不存，用 `sqrt(4a2−a1²)` 现算 |
| `tail_cnt` | 20 | B/C | 回收计时 |
| `variant` | 2 | C | 当前 seed 变体 |
| `seed_cnt` | 6 | C | 运行时生成的 seed 序号 |
| `noise_env0/1/2` | 32×3 | C | 噪声包络（LF/HF/attack） |
| `choke_group` | 3 | C | hi-hat choke |

**EXP 预设（每乐器一条，8 字节）**：`vib_rate / vib_depth / vib_delay / am_depth / glide_ms / bend_range / flags / reserved`。值先占位，后续调。UI 只做**控制面板**（改 RAM 副本），不做数据面板；默认不写 Flash，掉电丢失；以后若要记住上次设置，再加显式 `store` 写一个 sector。

粗估每声部约 180–220 bit，32 声部约 6–7 k FF；与现有 8,911 FF 同量级，需综合确认。

### 4.7 位宽总表

| 信号 | 格式 | 位宽 | 范围/分辨率 | 出处 |
|---|---|---:|---|---|
| 系数 core | `G Q2.24 / a2 UQ0.24 / a1 Q2.20` | 72 | 冻结 C1–C4 | 不变 |
| 状态 `y1/y2` | Q2.30 signed | 32×2 | ±2 / 9.31e-10 | 冻结 C5 |
| 单模态累加 | signed | 64 | 26×32 积 | 冻结 C6 |
| 混音/声部和 | Q2.30 signed | 64 | 30 frac | 不变 |
| 激励 `x` | Q2.30 signed | 32 | ±2 | 不变 |
| Velocity（事件） | 无符号 | 8 | 0..255 | 新 |
| Velocity（内部） | UQ1.15 | 16 | [0,2) / 3.05e-5 | 新 |
| Layer | 无符号 | 2 | 4 层 | 新 |
| B env | UQ0.32 | 32 | [0,1) / 2.33e-10 | B 文档 |
| B attack/release step | UQ0.24 | 24 | [0,1) / 5.96e-8 | B 文档 |
| B ratio | UQ1.16 | 16 | [0,2) / 1.53e-5 | 新 |
| B θ | UQ2.14 | 16 | [0,π] / 6.1e-5 rad | 新 |
| B r | UQ0.24 | 24 | (0,1] / 5.96e-8 | 新 |
| B phase/inc | UQ0.32 | 32 | [0,1) | B 文档 |
| B cents | Q7.9 signed | 16 | ±64 c / 0.002 c | B 文档 |
| C seed `y1/y2` | Q2.30 signed | 32×2 | ±2 | 新 |
| C piece_gain | UQ3.13 | 16 | 0..8 / 1.22e-4 | 新 |
| B/C noise_gain | UQ3.13 | 16 | 0..8 / 1.22e-4 | 新 |
| C noise_att_amp | UQ4.12 | 16 | 0..16 / 2.44e-4 | 新 |
| C noise coeff | Q1.22 signed | 24 | ±2 / 2.38e-7 | 新 |
| C noise sample | Q1.22 signed | 24 | ±2 | 新 |
| C noise acc | signed | 64 | 129×24 积 + 折叠和 | 新 |
| C noise env | UQ0.32 | 32 | [0,1) | 新 |
| index | 见 §4.2 | 48 | — | 新 |
| control | 见 §4.3 | 256 | — | 新 |
| 事件 | 见 §4.1 | 64 | — | 新 |
| `note_id` | 无符号 | 12 | 4096 | 新 |
| `tail_cnt` | 无符号 | 20 | 1M 采样 | 新 |

---

## 5. 力度、层与增益

### 5.1 把“选表”和“弹多响”分开

这是 A/B 统一里最容易出错的一条：

- **`layer`（2-bit）决定查哪张参数表**：A 的 piano/forte、B 的 piano/mezzo/forte、C 的采样层（当前只有一层）。
- **`velocity`（0..255）决定同一张表内弹多响**：A 缩放脉冲幅度，B 缩放驱动幅度，C 缩放输出。

硬件只使用事件里的 `layer` 和 `velocity`；**不根据 velocity 自动改 layer**。自动分层属于前端（song/MIDI/按键）的映射，建议：

| 类 | 建议阈值 | 说明 |
|---|---|---|
| A | `layer = velocity >= 160 ? forte : piano` | 两张表；160 是建议值，可配 |
| B | `velocity >= 192 ? forte : (velocity >= 128 ? mf : piano)` | 三张表；缺层严格拒绝 |
| C | `layer = 0`，忽略请求层 | 当前只有一层；`layer_ignore=1` |

**严格拒绝**：`(class,instrument,note,layer)` 不存在 → `error`，保留原声部；不自动找邻近音、不降级到其它力度。`layer=3`（保留值）直接拒绝；A 的 `layer=1`（mezzo）没有表时也拒绝，不能靠地址位悄悄落到 forte。`LAYER_FALLBACK` 只作为显式编译选项，默认关。

### 5.2 `velocity` 的定点

```text
vel_q = round(velocity * 32768 / 255)     // UQ1.15；255 → 32768 = 1.0
```

- 255 时乘 `32768` 再算术右移 15 位是**精确**的，保证 A 的默认满力度逐位不变。
- 中间力度按同一舍入规则；Python 参考必须用同一公式，不能用 `velocity/255` 浮点后各自舍入。

### 5.3 每类怎么用 velocity

| 类 | 应用点 | 公式 | 备注 |
|---|---|---|---|
| A | 脉冲幅度 | `x = pulse_table[pos] * vel_q >> 15` | `pulse_table` 已含 `pulse_scale`（默认 0.2） |
| B | 驱动幅度 | `x = imp * env * vel_q * am >> 31` | `env` UQ0.32、`vel_q` UQ1.15、`am` Q2.14；见 §6.2 |
| C | 声部输出 | `voice_sum = (modal + noise) * vel_q * piece_gain >> 28` | 线性，放在输出端最省 |

C 把 velocity 放在输出端，而不是 seed 里，有一个好处：seed 只由 piece/phase 决定，换力度不需要重写 48 个 seed；力度只改一个 16-bit 增益。

### 5.4 A 的增益契约（必须先冻结）

当前有两条 A 参考链，脉冲幅度不同：

- RTL 生产 `song_player.pulse_val()`：7 样本升余弦，**幅度 0.2**，Q2.30；`sim/integration/test_audio_chain_review.py` 和 `sim/support/body_helpers.py` 也用 0.2。
- `python/modal_sim/fixed_point.py:FixedModalSynth`：`amp = vel`，脉冲是 `(0.5−0.5cos)` 的**单位幅度**；`sim/unit/core/test_modal_bank.py` 直接用它做 bank 算术对拍。

两者差 5 倍（约 14 dB）。统一格式必须显式写 `pulse_scale`（UQ1.15，默认 0.2），并规定：

1. **RTL 生产默认 `pulse_scale=0.2`**，保证 v5 歌曲逐位不变；
2. `FixedModalSynth` 若继续用单位脉冲，必须在测试里显式乘 `0.2`，或把 `pulse_scale` 作为参数传入；
3. 生成 A 的 `G` 表时使用的归一化幅度必须和播放端一致；不能“表按 1.0 生成、播放按 0.2”，否则整体轻 14 dB。

同样，B 的 `DRIVE_K`、C 的 `_piece_norm×KIT_GAIN`、`NOISE_CAL` 都应变成数据字段/生成器常量，不能留在播放路径的隐式约定里。注意输出级 `audio_demo_core.sum_to_i16()` 还有 `SUM_ATT=3`（约 −18 dB）的演示衰减和 `+2^14` 舍入；这部分属于“输出适配”，不应再被 `key_gain`/`pulse_scale` 重复乘一次。统一增益契约建议固定为：

```text
表内归一化（G/piece_gain） → 每键 key_gain → 每类 class_gain
→ 混音（Q2.30） → master_gain → sum_to_i16（含 SUM_ATT）
```

**A 的首版实现取舍**：为了不动 bank 的 32 路 `x` 通道、也不在 `song_player` 里加 32 个乘法器，A 的 `load_vel` 在 `coeff_loader` 装载时缩放 `G`（`G'=round(G*vel_q/32768)`，`vel=255` 旁路），而不是逐采样缩放 `x`。对线性递推二者等价；区别是 aftertouch 这种运行中变化要等以后改成 x 侧。B/C 仍按本节在激励/输出端使用 velocity。

---

## 6. 激励

`x_vec` 接口保持不变：每声部每采样一个 signed 32-bit Q2.30。统一引擎不关心类；每类有自己的激励单元产生 `x`。

### 6.1 A：一次性升余弦

```text
pulse[i] = round(pulse_scale * (0.5 - 0.5*cos(2πi/L)) * 2^30), i=0..L-1
x[n] = (pulse_pos < L) ? pulse[pulse_pos] * vel_q >> 15 : 0
```

- `L=7`（forte）/`L=12`（piano），来自 G2 和 `fixed_point.py` 的 `tau_forte/tau_piano`。
- 脉冲在 note-on 被接受的样本开始；`pulse_pos` 每被接受的采样 +1。
- `x=0` 时谐振器仍要算反馈（自然尾音）；`SKIP_ZERO_INPUT` 只跳过 `G*x` 乘积。

### 6.2 B：整数周期冲激串 + AR 包络

L0（静态 B）：

```text
每采样：
  env  += ((target - env) * step) >> 24   // target=gate?1:0；step=attack/release_step，UQ0.24
  if (--T_cnt == 0) { imp=1; T_cnt=period_T-1; } else imp=0;
  x = imp * env * vel_q * am >> 31        // env UQ0.32, vel UQ1.15, am Q2.14 → Q2.30
```

- 首脉冲出现在第 `T` 个采样（相位 0 起步，不在 note-on 当拍发），与 Python `sustain_engine` 对齐。
- `am = 1 + am_depth*sin(2π·vib_phase)`，L0 可固定 `am=1`（关 AM）。
- **B 不能省 `G*x` 的乘法结构**：驱动逐采样存在；`SKIP_ZERO_INPUT` 对 B 没有收益，建议 B 存在时全局置 0。

L1（颤音/AM）：分数 NCO（`phase/inc`）、表情层给 `ratio`，刷新引擎按 `a1 = -2r·cos(ratio·θ)` 每 96 采样更新、每声部原子提交（θ/r 在 note-on 从 a1/a2 反解）。见 B 文档 §2.7/§5.1。

### 6.3 C：seed 起振 + 噪声

C 的模态部分不需要 `x`：

```text
x = 0
state = seed{y1,y2}   // 装载时写状态槽，不是每采样
y[n] = -a1*y1 - a2*y2
```

seed 不走 `x`，也不进记录流：它由装载侧 seed 写口写进 RAM 奇地址 `{8'b0,y2,y1}`，同时置 `state_valid`。数据源可以是预生成 seed 表（V 变体），或运行时用 LFSR + 共享 sin/cos LUT 生成（幅度放 G 或小 ROM）。

如果 L0 想先不做 seed，可以用一次冲激近似固定相位：

```text
G = sign * a * sin(theta)   // sign 由每模态伪随机符号给出
x[0] = 1（单位冲激），之后 0
```

但这只能给 0/π 两种相位，重复击打有“机关枪”感；只建议作为打通链路的过渡，不作为最终方案。

### 6.4 噪声支路（B 可选，C 必用）

噪声不是模态 bank 的一部分，单独一个 `noise_engine`：

```text
白噪 LFSR → 每 page 的 FIR（Q1.22 系数）→ 每 voice 的包络（UQ0.32）
          → × noise_gain × velocity × piece_gain → 加到 class 声部输出
```

- C 的 `drums.npz` 每个 piece 有 24 段 1/3 倍频程曲线，Python 用 257-tap `firwin2`，系数单位 RMS，L1 范数最大 11.56。
- B 的噪声是每乐器一条 257-tap FIR，默认 `noise_gain=0`（G6）。
- 噪声与模态的**时间对齐**必须显式定义：Python `_band_noise()` 用 `np.convolve(..., 'full')` 后取中段，等价于零相位/居中卷积；硬件因果 FIR 会引入 `(taps-1)/2` 采样延迟（257 tap→128 采样≈2.67 ms）。若直接接，噪声会比模态晚 2.67 ms，击打瞬态变软。
  - L0 建议 64-tap（延迟 32 采样≈0.67 ms），并把模态 seed 也延后同样采样，或接受这 0.67 ms；
  - L1 用 257-tap 时，整条 C 路径统一延迟 128 采样（约 2.67 ms），或改最小相位 FIR 后重新验证。**不能默认零延迟。**

---

## 7. 装载

### 7.1 统一事务

```text
IDLE
 └─ load_fire（锁存 Event + voice）
     → IDX_RD（读 class index）
     → IDX_CHK（present/n_modes/offset/version/ctrl 范围）
     → CTRL_RD（读 256-bit control）
     → CTRL_CHK（class/layer/instrument 自检）
     → CLEAR（清目标 voice 的 state_valid；coefficients 保留）
     → CORE（n 个 72-bit core；cfg 握手）
     → SEED（仅 C：n 个 seed 写状态槽，置 state_valid；B 无此步）
     → COMMIT（控制块 + class/n_modes/velocity 一次生效；voice_ready=1）
     → DONE（load_done 单拍）
```

- 只有 `COMMIT` 之后 voice 才能被 `sample` 使用；`CLEAR` 到 `COMMIT` 之间 voice 保持 inactive。
- `load` 与 `sample` 互斥；空闲时两者同拍到达，**load 优先**（沿用现 `modal_engine`）。
- 下游 `cfg/seed` 背压任意长，字段保持稳定；不丢词、不重复。
- reset 取消整个事务；已 clear 但未 commit 的 voice 视为 invalid，必须重新装载。

### 7.2 原子性与拒绝

- **所有校验在 clear 之前**：缺表、n 越界、offset 越界、control 非法、seed 越界都不产生 clear/cfg/seed。
- `CLEAR` 之后如果 reset，允许“半装”状态；整机 reset 同时清 loaded 位图，voice 不可用。
- 不允许用“先 clear 再发现错误”的实现；这正是现 `coeff_loader` 的契约，要保留。

### 7.3 C 的 seed 写口

给 `modal_poly_bank` 增加一个装载侧写口：

```text
seed_valid, seed_ready, seed_voice[VW], seed_mode[MW], seed_word[63:0]  // {y2,y1}
```

- 写进状态槽 `{8'b0, seed_word[63:32], seed_word[31:0]}`，同时置 `state_valid`。
- 与 compute 的写回互斥：装载期间 voice inactive，`sample` 不握手；bank 的 RAM 单端口不需要双写。
- `seed` 与 `cfg` 不能同拍写同一 lane；loader 串行发。
- seed 数据源：预生成 `c_seed.mem`（每 piece 48 模态 × V 变体），或运行时 LFSR + 共享 sin LUT 生成；两种都只用这个写口。

### 7.4 装载带宽：旧 216 周期/音不够

现 `coeff_loader` 每词约 4 拍（S_CRD/S_CFG 往返），48 模态约 216 拍/音。C 的 48 模态 × 2 字（core+seed）若沿用 4 拍/词 ≈ 384 拍/击，3 个同时击打就超过 1,100 拍，不能实时。

建议统一 loader 改成 **burst 流**：

| 模式 | 每拍 | A 48 模态 | B 48 模态 | C 48 模态（core+seed） |
|---|---:|---:|---:|---:|
| 旧 | 1 词/4 拍 | ~216 | ~216 | ~384 |
| 新 L0 | 1 词/拍 | ~70 | ~70 | ~112 |
| 新 L1 | 2 词/拍（core+seed 并行） | — | — | ~64 |

- A/B 的 48 词用 1 词/拍，加 index/control 开销约 70 拍/音。
- C 的 core 和 seed 若能在两个写口并行，48 拍 + 开销 ≈ 64 拍/击；否则 96+开销 ≈ 112。
- 3 个 C 同时击打：64×3=192 拍，能塞进 2,048−1,506≈542 拍的剩余；112×3=336 也在余量内。
- 8 个 C 同时击打：64×8=512 拍，接近 542 拍余量，需要事件队列跨帧分摊；不要承诺“任意 8 击同采样”。

**C 常驻方案**（推荐 L0）：启动时把 8 个 C 声部的 core 装好（每声部一个 piece，允许 2 个声部同 piece），之后每次 hit 只写 48 个 seed（1 词/拍=48 拍，2 词/拍=24 拍）和计时器/包络。这样实时路径没有 48 模态的系数搬运，也避开 216 周期/音的旧瓶颈。

### 7.5 A 的兼容适配器

首版保留旧 A 端口：

```text
load_instrument[1:0] → class=A, instrument
load_midi[6:0]       → note
load_dyn             → layer = dyn ? 2 : 0
velocity             → 255（或外部给）
```

loader 内部把旧 20-bit index 展开成 48-bit 视图；A 的 coefficient ROM 和 index ROM 可以**一个字节都不改**。等 B/C 稳定后，再决定是否生成统一 A index/control（coefficient 仍不变）。

---

## 8. 表与 ROM 布局

### 8.1 文件

| 文件 | 内容 | 说明 |
|---|---|---|
| `a_index.mem` | 1024×48 | A 统一 index；首版可由旧 20-bit 适配 |
| `a_ctrl.mem` | 250×256 | A 控制记录（或默认值，不存） |
| `modal_coeff.mem` | 5,483×72 | **保持不变** |
| `b_index.mem` | 1,280×48 | B index（5 乐器 ×128×2；按 2 的幂可补到 2,048） |
| `b_coeff.mem` | 3,849×72（3 forte）/ 7,624×72（5 全动态） | B core |
| `b_ctrl.mem` | 288×256 | B 控制（3 forte 时 123 条） |
| `c_index.mem` | 128×48 | C index（GM 别名指向同 offset） |
| `c_coeff.mem` | 288×72 | C core（6 piece × 48） |
| `c_seed.mem` | 288×64×V | C seed，V=1..4 变体（可选；运行时 LFSR 方案不需要） |
| `c_ctrl.mem` | 6×256 | C 控制 |
| `c_noise.mem` | 16×129×24（折叠）/ 16×257×24（未折叠） | 噪声 FIR 系数页 |
| `*_manifest.json` | 布局/来源/hash | 电脑端元数据，RTL 不解析 |

### 8.2 规模（估算）

| 表 | 位 | 说明 |
|---|---:|---|
| A index+ctrl+coeff | 49,152 + 64,000 + 394,776 = **507,928** | coeff 不变 |
| B，3 种 forte（123 key） | 61,440 + 31,488 + 277,128 = **370,056** | L0=L1（无 ext） |
| B，5 种全动态（288 key） | 61,440 + 73,728 + 548,928 = **684,096** | 覆盖上界 |
| C（index+ctrl+core+seed V=4+noise） | 6,144 + 1,536 + 20,736 + 73,728 + 24,768 = **126,912** | 6 piece × 48 |
| 合计，B 3 forte | **1,004,896 bit** | ≈55 块 18 kbit 原始；按 pROM 约 63% ≈87 |
| 合计，B 5 全 | **1,318,936 bit** | ≈72 原始；≈114 |

B 的 L0 与 L1 现在 ROM 相同：删掉 `c1/c2` 后，L1 只多表情层逻辑（sin/cos LUT、刷新引擎），不增加表。C 若采用运行时 LFSR 生成 seed，`c_seed.mem` 的 73,728 bit 也可以去掉。

加上现有工作缓存 221 kbit（N=48）以及 body 等，整机 BSRAM 粗估：B 3 forte 的 L0/L1 约 **110–140 / 340**；B 5 全动态约 **135–165 / 340**。这是**位级估算**，不是综合结果；必须用 Gowin 报告复核。B 文档按 3 种 forte 给的口径是 L0 +26–28、L1 +32–34 BSRAM（L1 已不含 ext 表）；本文把 C 和统一 control/index 一并算入，所以总量更高。

### 8.3 生成器

新增 `python/modal_sim/gen_class_rom.py`（或拆成 `gen_a_rom.py`/`gen_b_rom.py`/`gen_c_rom.py`），职责：

1. 从 `FFT_results/params/` 只读加载 NPZ；
2. 按类生成 index/control/core/seed/noise（B 无 ext）；
3. 严格校验：n=1..N_MODES、offset 不重叠、key 唯一、layer 合法、seed 长度一致；
4. 输出 `.mem` + `manifest.json`（来源、hash、生成命令）；
5. **A 的 `modal_coeff.mem` 字节不变**；重复生成 byte-for-byte 一致。

### 8.4 A 的 G 表归一化

生成 A 表时，`G` 必须和播放端 `pulse_scale` 一致。现 `gen_coeff_table.py` 用 `ModalSynth.note_on(midi, vel)`（单位脉冲）生成 `G`；RTL 播放用 0.2。统一后建议：

- 要么把 `pulse_scale` 设为 1.0 并改 RTL 脉冲（会改变现网表输出，不可取）；
- 要么在生成器里把 `G` 乘 0.2（或把 `ModalSynth` 的脉冲幅度设为 0.2），让表与播放一致；
- 无论选哪种，**A 的 `modal_coeff.mem` 若要改，就必须重新跑全部 A 回归和实板对比**；首版建议不改表，只把 `pulse_scale=0.2` 写进 A control，保持现状。

---

## 9. C 类设计

### 9.1 模型

Python `drumkit.py` 的一次击打：

```text
hit(t) = Σ_k a_k · exp(-γ_k t) · sin(2π f_k t + φ_k)     // 模态
       + noise_fir(t) · exp(-γ_noise t) × noise_gain      // 噪声
```

- 模态部分本质是**二阶谐振器的自由响应**，与 A/B 同一条递推；差别只是初值不是 0。
- 噪声部分不是模态，必须单独 FIR。
- 每次击打的相位 `φ_k` 随机；所有模态同相会产生一个宽带尖峰而不是“击打”。

### 9.2 与统一格式的映射

| C 概念 | 统一字段 |
|---|---|
| piece（kick/snare/hat/tom/ride/crash） | `instrument`=kit id（默认 0），`note`=GM 音符 |
| 力度 | `velocity` 0..255；`layer`=0（忽略） |
| 模态 `f_k,γ_k` | core `a1=-2r cosθ`、`a2=r²`、`G=0`（或存 seed 幅度 `A`） |
| 模态 `a_k,φ_k` | seed 写状态槽 `{y2,y1}`（Q2.30，不走记录扩展） |
| `noise_gain/env_gamma/...` | C control payload |
| 噪声 FIR | `noise_filter_id` → `c_noise.mem` page |
| 输出长度 | `length_samples` + `tail_cnt` |
| 每 piece 归一化 | `piece_gain`（UQ3.13） |

**GM 映射建议**（C index 的 128 个 note 条目，别名指向同一 offset）：

| GM note | piece | 说明 |
|---:|---|---|
| 35/36 | kick | 35=acoustic bass drum，36=bass drum 1 |
| 38/40 | snare | 38=acoustic snare，40=electric snare |
| 42/44 | hat | 42=closed hi-hat，44=pedal hi-hat |
| 45/47/50 | tom | low-mid/high tom |
| 49/57 | crash | crash 1/2 |
| 51/59 | ride | ride 1/2 |

`layer` 忽略（`layer_ignore=1`）；`velocity` 连续缩放。以后要加力度层，再在 index 里加 layer 维。

### 9.3 系数与 seed

**core**（每模态）：

```text
r = exp(-γ/fs), θ = 2π f/fs
a1 = -2 r cos θ      → Q2.20
a2 = r²              → UQ0.24
G  = 0（或 = A，若 seed 走运行时生成）→ Q2.24
```

数据范围（`drums.npz`，48 kHz 基准）：`f=24.5..17,281 Hz`，`γ=0.39..82.28 s⁻¹`，`r=0.9983..0.99999`，`a1=-1.9998..1.274`（Q2.20 够），`a2=0.9966..0.99998`。量化后极点仍在单位圆内；需在生成器里逐条检查 `|a1| < 2`、`0 < a2 < 1`。

**seed**：

对 `y[n]=A r^n sin(θn+φ)`，在 RTL 的 `y1=y[n-1], y2=y[n-2]` 约定下：

```text
y1 = A r^{-1} sin(φ - θ)
y2 = A r^{-2} sin(φ - 2θ)
```

量化 Q2.30，饱和到 ±(2−2⁻³⁰)。因为 `r` 接近 1，`r^{-1}/r^{-2}` 不会放大到溢出；`A` 是 `drums.npz` 的 `a_k`（最大 0.983），seed 绝对值 <1.01。

**变体**：每个 piece 预生成 `V=4` 组随机相位 `φ`（48 模态）；`c_seed.mem` 地址 = `piece*V*N_MODES + variant*N_MODES + mode`，`N_MODES=48`。每次 hit `variant = (variant+1) % V`。如果 BSRAM 紧，先做 V=1，再扩到 4；但 V=1 时连续击打会完全相同。

**运行时生成（可选，L1）**：不存 seed 表，把幅度 `A` 放 G，相位由每次 hit 的 LFSR 生成，`r/θ` 从 `a2/a1` 反解，`sin/cos` 复用表情层的 LUT，算出的 `{y2,y1}` 仍由同一个 seed 写口写入。这样没有 V 限制，代价是 Python 参考链要先冻结同一套 LFSR/相位映射。

### 9.4 噪声

Python 每 piece 的噪声：

- 24 段 1/3 倍频程 `band_db`（100 Hz..16 kHz），257-tap `firwin2`，单位 RMS；
- 若 `gamma_lf/gamma_hf` 非 0，分 LF/HF 两段；`att_band_db` 有值时再加一条 attack 瞬态；
- 当前数据：6 个 LF filter + ride/crash 两个 attack filter = 8 条；系数最大 0.918，L1 范数最大 11.56。

硬件建议：

| 项 | L0 | L1 |
|---|---|---|
| tap 数 | 64 | 257（对称折叠 129） |
| filter/页 | 6（每 piece 1 条） | 8（6 LF + 2 attack） |
| MAC/采样（最坏） | 6×64=384 | 8×129=1032 |
| 系数存储 | 6×64×24=9.2 kbit | 8×129×24=24.8 kbit |
| 历史存储 | 6×64×24=9.2 kbit | 8×257×24=49.3 kbit |
| DSP | 1（384 拍=19%） | 1（1032 拍=50%）或 2（516 拍=25%） |
| 延迟 | 32 采样（0.67 ms） | 128 采样（2.67 ms） |

- 噪声样本用 24-bit LFSR 均匀分布 → Q1.22；为匹配 Python 高斯 RMS，LFSR 输出乘 `√3`（或冻结算术平均），并在 Python `FixedDrumSynth` 里用同一 LFSR/同一缩放，才能逐位对拍。
- 噪声累加器 64-bit（129 个 24×24 积的折叠和；按 L1 范数 11.56 与 Q1.22 上界留保护位）；`noise_gain`、`velocity`、`piece_gain` 在输出端乘。
- **对齐**：L0 的 64-tap 延迟 32 采样，建议把模态 seed 也延后 32 采样（或整条 C 路径统一延迟）；L1 的 257-tap 延迟 128 采样，同样处理。不要假设 FIR 零延迟。
- **共享 vs 每声部**：L0 每个 filter 一份历史，同 piece 的多个 hit 共享噪声流（省 RAM，但重叠 hit 相关）；L1 若听感需要，再给每个 C 声部复制历史（8×257×24≈49 kbit，约 3 BSRAM）。

### 9.5 生命周期、力度、增益

- **一次性**：note-on 后没有 note-off；`tail_cnt` 到 `length_samples` 或包络低于阈值后释放 voice。
- **choke**：hi-hat 建议 `choke_group=1`；新 hat 触发时把同组旧 voice 的 `tail_cnt` 缩短（例如 5 ms 淡出），不硬清状态（避免 click）。
- **满池**：C 声部固定 8 个；满池时抢“最旧/最安静/已 release”的 voice，软淡出；具体策略与 B 的 `_pick_victim` 对齐。
- **力度**：`voice_gain = piece_gain × vel_q >> 15`；`piece_gain` 已含 `_piece_norm×KIT_GAIN`。注意 `_piece_norm` 是对整条 hit（模态+噪声）的峰值归一化，硬件 seed 变体不同、PRNG 不同，峰值会有偏差；用 `KIT_GAIN`/master limiter 收尾，不能假设每击都精确 1.0。
- **长度**：`length_samples` 来自 `hit_length`（0.12..3.0 s），20-bit 计时器够。

### 9.6 C 的两级方案

| 级别 | 模态 | 噪声 | 装载 | 目标 |
|---|---|---|---|---|
| C-L0 | 72-bit core + `G=sign·a·sinθ` 冲激（无 seed） | 64-tap，每 piece 1 条 | 常驻 8 声部，装载只写 core | 最快出声，验证 bank/路由/噪声 |
| C-L1 | core + 48 个 seed 写状态槽，4 变体（或运行时 LFSR） | 257-tap 折叠，LF/HF/attack | 常驻 + 每击写 48 seed | 真正的随机相位/音色 |

C-L0 的相位固定，重复 hit 会“机关枪”；只用于打通链路。C-L1 才是目标。若时序/容量紧，可以先 C-L0 上板，再逐级替换 seed/噪声，不需要改统一格式（`version=2` 从 0 变 2，seed 始终走状态写口）。

### 9.7 C 资源估算

| 项 | L0 | L1 | 说明 |
|---|---:|---:|---|
| 工作缓存 N=48 | 0 | 0 | 与 A/B 共用，C 不再把 N 提到 64 |
| seed ROM V=1/4 | 0 | +1 / +4 BSRAM | 18/74 kbit（6 piece × 48） |
| 噪声系数+历史 | +2 BSRAM | +4–5 | 18/74 kbit |
| index/control/patch | +2–3 BSRAM | +2–3 | 稀疏 ctrl |
| DSP | +1 | +1–2 | 噪声独立；seed 可用共享 LUT |
| LUT/FF | +1–2 k | +1–2 k | 控制/包络/计数器 |

C 的增量粗估 **+5–12 BSRAM、+1–2 DSP、+1–2 k LUT/FF**（L1 偏上限）。B 的 L0/L1 约 +26–28 / +32–34 BSRAM，整机约 **110–140 / 340 BSRAM**（取决于 B 覆盖 3 forte 还是 5 全动态）；容量可行，但**时序和端口**才是门槛。

### 9.8 C 的验证

1. `FixedDrumSynth`（新）：整数 core+seed+包络+LFSR 噪声，逐位对 RTL；
2. 单模态 seed：首样本 `A sinφ`，前 3 拍与浮点公式一致（容差 1 LSB）；
3. 单 piece 48 模态：状态/voice_sum/sat 逐位；
4. 6 piece 全表：每 piece 至少 1 个变体，seed/phase/长度；
5. 噪声：1/3 倍频程、RMS、衰减斜率；LFSR 固定种子逐位；
6. 力度：0/64/128/192/255 的线性/舍入；
7. 满池/choke/重击/长尾/回收；
8. A/B 同时运行时 C 不影响它们；C 关闭时逐位不变；
9. 周期：8 C 声部 + 3 同时击打 + A/B 最坏；
10. 综合/P&R：资源、Fmax。

---

## 10. 混音、body 与限幅

```text
A_sum ──► body_filter（guitar）──┐
B_sum ───────────────────────────┼──► master gain/limiter ──► i16 ──► FIFO/I2S
C_sum（modal + noise）───────────┘
```

- **A 走 body**（现生产配置 `ENABLE_BODY=1`，`BODY_INSTRUMENT=0`）；**B/C 旁路**，由 index/control 的 `body_bypass` 决定，默认 B/C=1。
- 每类一个 16-bit 增益（UQ1.15），先乘后加；不要在类内部提前截断。
- 混音 64-bit Q2.30；饱和计数按类汇总（`sat_count_A/B/C`）。
- C 的 `piece_gain` 已经把 `_piece_norm×KIT_GAIN` 烘进去；master limiter 只做最终保护，不承担音色平衡。
- 16-bit 输出沿用 `sum_to_i16()` 的舍入/饱和；左右复制不变。

---

## 11. 容量与周期

### 11.1 声部/模态预算

```text
NUM_VOICES = 32
N_MODES    = 48
class caps : A=14, B=10, C=8          // 合计 32
M_ACTIVE_MAX = 14*48 + 10*48 + 8*48 = 672 + 480 + 384 = 1536
```

- `M_ACTIVE_MAX=1536` 与当前 32×48 相同，周期基线仍是 **1,506 周期**（实测）。
- 加 body ~74、3 个 C 装载 ~192（2 词/拍）→ **1,772 < 2,048**。
- 若某类想超 48 模态，直接拒绝（`N_MODES=48`），不再有 64 模态的全局预算。
- B 若需要 12 声部，可改成 A12/B12/C8 = 576+576+384=1536，仍同预算；具体 caps 是待冻结项。

### 11.2 为什么 N_MODES 保持 48

- C 截到 **48 模态**后听感验收通过（kick/snare/hat 均可用），不再需要把全局上限抬到 64。
- 证据见 [音色合成缺陷台账](音色合成缺陷台账.md) B-04 的 2026-10-19 补充测试：保留最强 48 模态后 4 小节 groove 的 RMS 比 0.9984、多数 1/3 倍频程差 0 dB；按 `build_kit(n_modes=48)` 重新提取 RMS 比 1.022，听感仍无差异。
- **硬件生成必须按“最强 48”选峰，不能按频率顺序截前 48**；否则 kick/hat/ride 的频谱重心会偏 200–300 Hz。
- 省下：工作缓存保持 221,184 bit（32×12 local×2×72），不增 4 BSRAM；`MW` 保持 6；每 lane local 保持 12。
- A/B 本来 n≤48，完全不受影响。以后若某个 piece 确实需要 >48，再单独评估，不全局抬 `N_MODES`。

### 11.3 装载预算

| 场景 | 拍 | 说明 |
|---|---:|---|
| A/B 1 音（burst 1 词/拍） | ~70 | 48 core + index/control |
| C 1 击（core+seed 2 词/拍） | ~64 | 48 core + 48 seed 并行 |
| C 1 击（1 词/拍） | ~112 | 串行 |
| C 常驻后每击（只写 seed） | ~24–48 | 推荐 L0 |
| 3 C 同时（2 词/拍） | ~192 | 可塞进 542 拍余量 |
| 8 C 同时（2 词/拍） | ~512 | 接近 542 拍余量，需要跨帧队列；不承诺单帧 |

**事件队列**：建议 16 深度 FIFO，保存 Event + 目标 voice + 到达采样号；loader 在帧间隙按 deadline 调度，超时置 `deadline_error`，不静默丢事件（沿用 `song_player` 的粘滞错误思路）。

---

## 12. 分阶段

### F0：冻结格式 + Python 工具（无 RTL）

1. 冻结本文 §4 的 Event/Index/Control/Core 布局、§5 力度语义、§6 激励语义；seed 只作为状态写口；
2. 新增 `python/modal_sim/class_format.py`：pack/unpack、key→index、velocity 量化；
3. 新增 `gen_class_rom.py`：A/B/C 表、manifest、A coeff hash 校验；
4. 新增 `fixed_point_b.py` / `fixed_point_c.py`：整数参考（B 的 NCO/AR；C 的 seed/LFSR）；
5. 纯 Python 回归：格式打包、边界、A coeff 不变、C seed 首样本。

**Exit gate**：同一份记录在 Python 打包/解包可逆；A 的旧表 hash 不变；C 单模态整数 vs 浮点 ≤1 LSB。

### F1：统一 loader + A 兼容（RTL）

1. 新 loader（burst 1 词/拍、index 48、control 256、seed 口）；
2. A 用旧 20-bit index 适配器，`pulse_scale=0.2`，`layer=forte`，`velocity=255`；
3. bank 增加 `seed` 写口（先不接 C，只留接口）；
4. A-only 与 v5 逐位对拍。

**Exit gate**：A-only 逐位一致；loader 周期 ≤70/音；无 X/幽灵 valid。

### F2：B-L0（静态持续音）

1. B index/control/core、NCO 整数计数、AR 包络、8 声部；
2. `FixedSustainSynth` 逐位对拍；
3. B 旁路 body；A+B 共存。

**Exit gate**：B 单声部/8 声部逐位；A 不受影响；每帧 ≤2,048。

### F3：C-L0（常驻鼓组）

1. N_MODES=48、8 个 C 声部常驻、`G=sign·a·sinθ` 冲激（或 seed 先做 V=1）；
2. 64-tap 噪声、6 piece、GM 映射、choke；
3. C 与 A/B 混音；C 关闭时 A/B 逐位不变。

**Exit gate**：6 piece 出声；噪声统计达标；每帧/装载周期达标。

### F4：B-L1 / C-L1

1. B 表情层：ratio、θ/r 反解、分数 NCO、a1 刷新（不存 c1/c2）；
2. C seed V=4（或运行时 LFSR）、257-tap 折叠噪声、LF/HF/attack、噪声对齐；
3. 资源/时序复测。

**Exit gate**：a1 刷新逐位/原子；C 相位/噪声达标；Fmax/资源不恶化到不可接受。

---

## 13. 验证矩阵

| ID | 测试 | 判据 |
|---|---|---|
| T-F01 | Event/Index/Control/Core pack/unpack | 全字段可逆；边界值；保留位为 0 |
| T-F02 | key 严格性 | 缺 key/缺 layer/n=0/offset 越界 → error，无 clear/cfg/seed |
| T-A01 | A-only vs v5 | 逐位一致（默认字段） |
| T-A02 | A 力度 0/64/128/192/255 | 脉冲/状态/和与整数参考逐位 |
| T-B01 | B 单声部 | NCO 周期、首脉冲、包络、状态/和逐位 |
| T-B02 | B 8 声部/满池/off/回收 | 逐位；A 不受影响 |
| T-B03 | B a1 刷新（L1） | 1,536 值逐位、每声部原子（ratio→cos 路径） |
| T-C01 | C seed 写口 | 首样本/前 3 拍与浮点 ≤1 LSB；state_valid 置位 |
| T-C02 | C 单模态/单 piece 48 模态 | 状态/voice_sum/sat 逐位 |
| T-C03 | C 6 piece/变体/力度 | 逐位；重复击打相位不同 |
| T-C04 | C 噪声 | LFSR 逐位；1/3 倍频程/RMS；延迟对齐 |
| T-C05 | C 满池/choke/长尾/回收 | 无爆音/无卡死；旧 voice 正确释放 |
| T-M01 | A+B+C 混音 | body 只作用于 A；B/C 旁路；无溢出/提前截断 |
| T-M02 | 关闭 B/C | A 逐位不变 |
| T-P01 | 最坏周期 | 1,536 模态 + 3 C 装载 + body ≤2,048 |
| T-P02 | 综合/P&R | 资源/Fmax 报告；三配置（A/B/C 单独与全开） |

---

## 14. 待冻结决策

| # | 项 | 选项 | 建议 | 影响 |
|---|---|---|---|---|
| 1 | `N_MODES` | 48 / 64 | **48** | C 截到 48 验收通过；工作缓存不增；MW=6 |
| 2 | 活跃模态预算 | 无 / **1536** | 1536 | 周期上限/分配器 |
| 3 | 声部 caps | 多种 | **A14/B10/C8** | 公平性/满池策略 |
| 4 | 力度层 | 1-bit dyn / **2-bit layer + velocity** | 后者 | 所有表/前端 |
| 5 | 缺 key 策略 | 回退 / **拒绝** | 拒绝 | 与 B 文档一致 |
| 6 | A 的 `pulse_scale` | 0.2 / 1.0 | **0.2（保 v5）** | 增益/参考链 |
| 7 | B 扩展 | 无 / c1c2 48-bit | **无；表情层重算 a1** | BSRAM/时序 |
| 8 | C 相位 | 固定 / sign / **seed 写口** | L0 sign，L1 seed（V=4 或运行时） | 听感/ROM |
| 9 | C 噪声 | 64-tap / **257 折叠** | L0 64，L1 257 | 资源/延迟 |
| 10 | C 装载 | 按需 / **常驻** | L0 常驻 | 实时性 |
| 11 | C 变体 V | 1 / **4** | 4（可退 1；运行时方案无限制） | seed ROM |
| 12 | 噪声对齐 | 零延迟 / **统一延迟** | 统一 32/128 采样 | 击打瞬态 |
| 13 | B 声部 | 8 / 10 / 12 | 10（联合 caps） | 复音/资源 |
| 14 | body 路由 | 全共享 / **A body，B/C bypass** | 后者 | 音色 |
| 15 | 采样率基准 | 48k / 48.828k | **48k（与 A 同基准）** | 音高/表 |
| 16 | master 限幅 | 固定增益 / **软限幅** | 先固定，后软限幅 | 削顶 |
| 17 | A index | 旧 20-bit 适配 / **统一 48-bit** | 先适配，后统一 | 兼容/回归 |

**最优先的 5 项**：1（N_MODES）、2（活跃模态预算）、4（力度语义）、8（C 相位）、10（C 装载）。这 5 项决定架构；其余可在实现中迭代。

---

## 15. 风险

| 风险 | 概率/影响 | 缓解 |
|---|---|---|
| 时序不收敛（现 +1 ps） | 高/高 | 每级真实 P&R；C 噪声独立 DSP；新 mux/扇出单独检查 |
| 装载带宽不足 | 中高/中 | burst 1–2 词/拍；C 常驻；事件队列跨帧 |
| C seed 写口/相位/增益错 | 中/高 | 整数参考逐位；首样本断言；state_valid 置位；与噪声延迟对齐 |
| 噪声延迟/PRNG 不匹配 | 中/中 | 统一 LFSR + 统一延迟；统计+逐位双验证 |
| B L1 a1 刷新竞争（ratio→cos） | 中/中 | 影子表 + 每声部 burst 原子提交；cos LUT 定点先冻结 |
| ROM 容量/端口 | 中/中 | 分表；稀疏 ctrl；A 表不重生成 |
| A 逐位回归被破坏 | 中/高 | 旧 index 适配；A-only 全回归；默认字段锁定 |
| caps 导致某类饿死 | 中/中 | 可配置 caps；满池软抢占；状态计数 |
| 与 ENG2 格式混淆 | 中/低 | 本文只覆盖 IIR；ENG2 走结果级适配，不共用 word |

---

## 附录 A：公式与数值

### A.1 递推与 seed

```text
y[n] = G·x[n] − a1·y1 − a2·y2
a1 = −2 r cos θ, a2 = r², r = exp(−γ/fs), θ = 2πf/fs
```

C 的自由响应 `y[n]=A r^n sin(θn+φ)`：

```text
y1 = A r^{-1} sin(φ−θ)
y2 = A r^{-2} sin(φ−2θ)
```

验证（Python，双精度）：kick 模式 0 `f=24.536 Hz, γ=3.773, A=0.0418, φ=0.7`：

```text
a1 = −2,096,976 (Q2.20)
a2 = 16,774,578 (UQ0.24)
y1 = 28,808,646 (Q2.30)
y2 = 28,700,183 (Q2.30)
```

前 3 拍与 `A r^n sin(θn+φ)` 的误差 <1e-15（浮点）；整数化后需 ≤1 LSB。

### A.2 B 的稳态增益

```text
A_peak(k) = max_j r^j |Im[ e^{iθ(j+1)} / (1 − R e^{iφ}) ]|
R = r^T, φ = θT
G_k = w_k / A_peak(k)
```

与 B 文档 §2.5 一致；48 kHz 基准，`T=round(fs/f0)`。

### A.3 C 的噪声

```text
noise[n] = Σ_tap h[tap] · lfsr[n−tap]
env[n]   = env[n−1] · exp(−γ_noise/fs)   // 或 step 形式
out     += noise[n] · env[n] · noise_gain · vel · piece_gain
```

## 附录 B：C 记录示例（kick，1 模态，示意）

```text
index: present=1, n_modes=48, mode_offset=0, ctrl_index=0, version=2, flags=noise_en
control: class=C, layer=0, instrument=0, ctrl_format=2,
         piece_gain=1.032 (raw _piece_norm), noise_gain=0.005,
         noise_env_gamma=1.027, noise_filter_id=0, length_samples≈...
core[0]: a1=0x... (Q2.20), a2=0x... (UQ0.24), G=0
seed[0][variant0]: y1=0x... , y2=0x...   （写状态槽，不是记录扩展）
seed[0][variant1]: ...
```

具体 hex 由 `gen_class_rom.py` 生成；本文不手写 `.mem`，避免与生成器不一致。

## 附录 C：与 ENG2 / 双引擎的关系

- 本文的 A/B/C 都属于 **ENG1 三系数 IIR**；`rtl/simsynth` 的 ENG2 是 7 字段 `(q,q̇)` 物理状态，**不共用** coefficient word、状态格式或 loader。
- 若以后要统一顶层，按[双引擎统一顶层架构](双引擎统一顶层架构.md)：ENG1/ENG2 各自本地 bank，结果在 Q2.30 对齐后混音；不要在本文的 index/control 里塞 ENG2 的 7 字段。
- 本文的 `class` 字段只描述 A/B/C，不描述“哪个引擎”。

---

**一句话总结**：A/B/C 统一到同一套 Event/Index/Control/Core 记录、同一套严格键和装载事务、同一套“layer 选表 + velocity 定幅度”的力度语义；B 的颤音/滑音由表情层给 `ratio` 重算 a1，C 用同一递推 + 每模态 seed（写状态槽）+ 独立噪声，最多 48 模态，靠 `M_ACTIVE_MAX=1536` 和常驻鼓组守住周期。格式可以统一，但 A 的 `pulse_scale`、B 的表情 `ratio`、C 的 seed/噪声必须各自成为显式语义，不能继续藏在实现约定里。
