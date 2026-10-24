# MIDI 到核心引擎的数据映射调研

调研日期：2026-10-23。源码 HEAD：`4809eb1e`；基于当前工作树读取 RTL，不修改引擎。本文假设 MIDI 已解析成事件，不讨论 USB、UART、蓝牙及 MIDI 字节解析。

## 1. 结论

**可以转换，A 类已有可复用且经过本次实验验证的数据通路，不需要重写模态递推核。**

但要区分三件事：

1. **事件格式转换**：音符、力度、音色选择、时间、通道可以映射成内部控制数据。
2. **产生可用引擎作业**：还必须选声部、找到音色参数、装载系数，并产生逐样本激励和释放控制。单纯打包字段不够。
3. **保留任意 MIDI 的完整听感**：当前做不到；音色库、缺失音符、持续激励、表情控制和复音容量都有边界。MIDI 兼容也不等于 General MIDI 全音色兼容。

MIDI Note On / Program Change 本身不提供模态频率、阻尼或增益。应使用 **MIDI 选择本机音色参数**，不能只凭 MIDI 事件恢复任意原音源的音色。

推荐通路：

```text
已解析的 MIDI 事件
  → 通道状态 / 音色映射 / 声部分配 / 样本时间调度
  ├→ load_* → router_loader → cfg / clear / seed → shared_modal_ram
  ├→ 每声部激励发生器 → Q30 x[n]
  └→ 释放 / 踏板 / 回收策略 → off_*（或后续逐声部包络控制）
  → 现有 ABC / E2 核 → 后级
```

## 2. MIDI 字段如何转换

| 外部语义 | 转换目标 | 当前边界 |
|---|---|---|
| Note Number 0..127 | `load_note[6:0]` | 编号直接一致，不需要先转换为 Hz；查表时必须有对应音符 |
| Note On，velocity > 0 | 分配 voice 后发 `load_valid`，等待 `load_done`，再启动该声部激励 | 正式 top 用装载完成激活 voice；装载本身不会自动产生 A 类激励 |
| Velocity 1..127 | 项目已有 `vel8_from_midi(v) = v << 1`，赋给 `load_vel` | 最大 254，不是 255；不要无意混用其他归一化方式 |
| Program / Bank | 软件或 RTL 映射表 → `load_class`、`load_inst`、本机 patch 配置 | 不是直接截取 program 低两位 |
| MIDI channel | 转换层保存通道状态，并把 `(来源, channel, note, 按下实例)` 关联到 voice | channel 与 voice 是不同概念；一个通道可以占多个 voice |
| Note Off | 查找对应 voice，执行释放策略，最终发 `off_valid/off_voice` | 当前 `off_*` 是立即关闭计算，不是平滑释放 |
| Note On，velocity = 0 | 先归一化为 Note Off | 不应装载一个力度为零的新音符 |
| 事件时间 | 转换成目标音频样本时刻 | 引擎按 `start` 推进一个样本；不是收到事件就任意推进音频 |
| CC64 延音踏板 | 转换层按通道暂存 Note Off，踏板抬起后进入释放 | 能在核外实现基本语义，但平滑释放仍需控制接口 |
| CC7 / CC11、触后 | 通道/逐音增益或激励控制 | `load_vel` 只处理起音装载，不能代替演奏中的增益变化；A 类起音结束后只改 x 也不能控制已有尾音 |
| Pitch Bend | 转成调音目标，再更新模态系数及必要的激励频率 | 当前没有正式接通的状态保持式实时改系数路径；改变 `load_note` 或只改激励不等于连续弯音 |
| GM 鼓轨 | 按配置把第 10 通道的键号映射到 C 类鼓件 patch | 仅适用于 GM 语义；普通 MIDI 不规定第 10 通道必然是鼓。普通 one-shot 鼓也不应机械地在 Note Off 时截断尾音 |

GM 映射示例，program 使用 **0-based** 编号：

- 0 Acoustic Grand Piano → A 类 `load_inst=1`。
- 24 / 25 Acoustic Guitar → 可配置为本机 A 类 guitar，`load_inst=0`；不代表本机已经区分尼龙弦与钢弦。
- 105 Banjo → A 类 `load_inst=2`。
- 本机 Mandolin → A 类 `load_inst=3`，应显式配置；GM1 没有独立标准 mandolin program。

不支持的 program 应明确拒绝或回退到指定 patch，不能宣称还原原音色。

## 3. 核心实际需要的三层数据

### 3.1 装载事务：已有正式入口

`rtl/core/router_system_top.sv:43`：

```text
load_class   2 bit：0=A，1=B，2=C，3=E2
load_inst    2 bit：当前 loader 的类内音色编号
load_note    7 bit
load_vel     8 bit
load_dyn     1 bit：A 类的 piano/forte 层选择
load_voice   clog2(NUM_SLOTS) bit
load_note_id 12 bit
load_valid / load_ready → load_done / load_error
```

类内编号不要与 `router_frontend` 的 `rcfg_instrument[3:0]` 混淆。后者的 load 输出目前未连接正式 loader，不能作为完整 MIDI 装载入口。

**A 类力度支持更正：** `index_loader20.sv:151–184` 已按 `load_vel` 缩放每个模态的 G。虽然 `pure_engine_abc` 的 x_vel/env_gain 固定 unity，仍然有装载时的力度响应。不能把 unity 接线解释为 A 类完全没有力度支持。

现有 Python 参考模型以归一化力度 0.55 区分 piano/forte。转换层可据此采用 MIDI velocity ≥70 选 forte 的初始策略，但这不是正式 top 自动执行的功能；仍需显式生成 `load_dyn`，并处理缺失层。

### 3.2 模态系数：由 patch 提供，不来自 MIDI

A 类的 index 地址：

```text
index_addr = (load_inst << 8) | (load_note << 1) | load_dyn
```

ROM core72：

```text
[71:46] G   signed 26 bit，24 fractional bits
[45:22] a2  unsigned 24 bit，24 fractional bits
[21:0]  a1  signed 22 bit，20 fractional bits
```

`router_loader` 自动转成 288-bit、9×32 RAM 记录：

```text
field0 = sign_extend(G_scaled)
field1 = sign_extend(a1)          // RAM 中不预先 <<4，核读出后才移位
field2 = zero_extend(a2)
field3 = y1 = 0
field4 = y2 = 0
field5..8 = 0
```

B/C 同用 ABC 记录布局。64-bit index 按 `{class, instrument, note}` 寻址，按 `velocity[7:6]` 选择四档系数；它不是 A 类的连续 G 缩放路径，档内连续力度不能视为已完成。C 还可装载种子状态。

E2 使用七个系数 `a11/a12/a21/a22/gq/gv/wo` 和两个状态 `q/qdot`，同样必须有对应 patch 数据；MIDI 事件可以选择 E2 patch，但不能自动把 A 类参数解释成 E2 系数。

### 3.3 逐样本激励和声部生命周期

ABC 路径的输入 x 是 **signed 32-bit、30 fractional bits**：

```text
x_q30 = saturate_int32(round(x_normalized * 2^30))
1.0 → 0x40000000
```

E2 不应直接套用此格式：`rtl/simsynth/modal_step_pkg.sv` 声明 `XF=28`，其物理激励与系数生成应配套。正式 top 共用压力覆盖信号不代表两种核的物理激励定标已经统一。

- A：起音后产生有限力脉冲，随后 x=0，让模态状态继续衰减。既有系数生成与参考模型按短 raised-cosine 力脉冲配套；单样本脉冲可以验证核可工作，但不能直接视为同样的音色。
- B：必须产生持续、带周期/包络等参数的激励。仅置 active 不会自动持续吹奏或拉奏。
- C：需要相位/seed、必要的噪声和激励策略，不能仅把鼓键号改成 class=2。
- 力度已在 G 中缩放时，x 不要无意再乘同一力度，避免响应被重复缩放。

正式 `router_system_top` 已开放逐槽 `a_x` 和 `e2_x`。B/C 的 x 在该 top 中除 slot0 压力覆盖外被置零；下层 `shared_engines_top` 虽有 `b_x/c_x`，仍需向上开放或接入激励发生器。

## 4. 当前资源表能覆盖多少 MIDI 音符

本次实际读取 `rtl/rom/modal_manifest.json` 与 `modal_index.mem`，共 **250 个音符×力度层条目、5483 个模态系数**：

| A 类 patch | 类内编号 | 不同音符数 | 最小..最大编号 | 层条目数 | 注意事项 |
|---|---:|---:|---|---:|---|
| guitar | 0 | 38 | 40..84 | 71 | 音域内也有缺音；C4=60 只有 forte |
| piano | 1 | 38 | 21..108 | 66 | 是稀疏音高，不是覆盖 88 键；60 只有 piano，61 无条目 |
| banjo | 2 | 41 | 48..88 | 74 | 音高连续，但部分音符缺一个力度层 |
| mandolin | 3 | 39 | 55..93 | 39 | 音高连续，全部只有 piano 层 |

不能仅按 min/max 判定支持。建议：

1. 先找目标音符与目标层。
2. 缺层但同音存在另一层时，允许显式回退，并保留连续力度缩放。
3. 两层都缺时，默认报“不支持音符”；不要直接拿最近音的 ROM 系数冒充目标音高。
4. 若要补全音域，离线从已有 patch 参数转调并重新生成 a1/a2/G。`python/modal_sim/params.py:195` 已能按目标 MIDI 重算模态频率，但 `gen_coeff_table.py` 目前只枚举原始 `patch.midis`，并未自动导出缺音。
5. 扩表还须检查容量：当前 A offset 仅 13 bit、8192 个可寻址系数；不能认为增加任意数量音符只需增加 `.mem` 行数。

当前工作树未见正式 top 默认引用的 `b_coeff.mem/b_index.mem/b_ctrl.mem/c_seed.mem` 及 E2 默认 ROM。B 有 flute69 demo，仿真目录有小型 fixture；这些不等于完整 B/C/E2 乐器资源库。

### 4.1 补充复核：`sythsound` 模型具有连续音高生成能力

上表统计的是已导出的 A 类硬件 ROM，**不是所有模型可生成音高的上限**。此前未同时核对这条模型路径，不能据此断言钢琴只能生成稀疏音高。

- `sythsound/sim_piano.py:218` 的 `piano_generator()` 明确支持 **MIDI 40..80，共 41 个连续音高**。
- `piano_f0()` 对五个 octave stretch 锚点做分段线性插值，得到拉伸调律后的基频；41 项 `INHARMONICITY_1024X`、41 项 `GAMMA_KEY` 和击弦位置函数进一步补全各音高的模态参数。不是仅凭一个 f0 就得到完整音色。
- 每音使用两个轻微失谐的 bank，总模态数按音域为 80、70 或 44，不能未经验证直接压成旧 A 路径的 48 模态。
- 该模型用 q/qdot 精确状态更新；`rtl/simsynth/modal_step_pkg.sv` 明确将它列为 E2 数学来源，应沿 E2 的系数布局、定标与激励链导出，不能直接替换旧 A core72 表。
- `sythsound/sim_guitar.py:171` 的生成器同样声明支持 MIDI 40..80；应与提取参数驱动的 A 类 guitar 区分。

因此，32 键位可以从钢琴已有模型的连续 41 音中截取，例如 **48..79**；这时可用 `midi = 48 + bank*16 + key`，不必依赖旧 ROM 的稀疏键位。具体选段尚未冻结，模型参数仍需导出、量化并验证后才能当作板端资源。

本次对钢琴 40..80 全部 41 个音高运行了构建、48 kHz reset、64 样本脉冲响应，系数及输出均有限；这不是长时或定点验收。另发现 MIDI 80 存在不低于 24 kHz 的模态，硬件导出时需要处理 Nyquist 限制；示例选段 48..79 未出现该问题。

## 5. 为什么已有 Event64 还不能直接当成完整适配器

`rtl/core/class_format_pkg.sv` 与 `python/modal_sim/class_format.py` 已有一致的 Event64 pack/unpack，含 class、instrument、note、gate、velocity、note_id、event_type、timestamp。

不过：

- 正式 top 接收离散 `load_*` 端口，不直接消费一个 Event64 word。
- Event64 没有 MIDI channel 或 voice 字段，转换层需要额外保存它们。
- A 的 dyn 必须另外提供；不能随意复用已保留的位而改变格式契约。
- loader 虽锁存 gate/event_type，但不会据此自动执行 Note Off。正式 `router_loader` 也将二者固定为起音装载值。
- 正式 A loader 的 note_id 被固定为 0；B/C 的 note_id 参与 seed 变体选择，不能代替通道/重叠同音的完整身份表。
- timestamp 没有正式调度消费者，单位和回绕策略也尚未冻结。建议转换层使用独立、明确单位的样本时钟，而非直接相信该字段已可调度。

建议保留一个未打包的语义层：

```text
{sample_time, source, channel, type, note, velocity, program, ...}
    → 通道状态和 voice 表
    → 装载事务 / 每声部激励 / 释放操作
```

voice 表应记录来源、通道、音符、按下实例、patch 快照、gate、踏板状态与生命周期；明确同音重复按下、抢占、过期 Note Off、装载失败的处理策略。

## 6. 时序约束：不能只看字段位宽

1. 先全局串行化装载事务，不只检查某一类 loader 的 ready；当前顶层 `class_r` 为全局元数据。
2. 装载、clear、seed 与计算必须仲裁。`shared_modal_ram.sv:135` 中装载类写入优先于状态写回，即使地址不同，同 lane 同周期冲突也可能丢掉计算写回。`load_ready` 不代表已获得计算 RAM 的安全写入窗口。
3. 在安全边界完成装载，再激活/激励，不能让计算看到半装载记录。
4. Note Off 不要与装载完成同时直通：当前 top 共用 `note_voice`，off_valid 会选择 off_voice，而 allocator 中 note_on 又优先；需要排队避免冲突。
5. MIDI 同一时刻的和弦可以顺序准备后在同一样本边界起音，但须计入装载与计算预算，不能因顺序处理而平白跨多个音频样本。
6. 当前 16 个槽是共享 voice 预算，不是 16 个 MIDI 通道各有 16 复音；ABC 与 E2 仍互斥。

## 7. 本次实际验证

使用本机 Icarus Verilog，临时实验文件保存在 `/tmp/opencode/midi_research/`，未改变生产 RTL，也未将实验混入正式回归。

### 7.1 真实 A ROM 的装载验证

`tb_midi_a_loader.sv`：

- 遍历全部 250 个 present 条目。
- 分别使用 MIDI 力度 1、50、100、127，按 ×2 转换成 2、100、200、254。
- 共 **1000 次装载、21,932 个系数逐字检查 PASS**，核对 G 缩放、未变的 a1/a2、mode 序号及装载数量。
- 吉他 60 的缺失 piano 层、钢琴 61 的缺失音符均返回 missing-entry 错误。

另以 Python 检查了 250 个 manifest/index 条目一致，以及全部 127 个非零 MIDI 力度的 Event64 打包解包，PASS。

### 7.2 正式顶层 + 真实 A ROM + 计算核 + 后级

`tb_midi_a_core.sv`：

- 吉他 C4=60、forte，实际查到 27 个模态；两个槽分别用 MIDI velocity 50/100，转换为 100/200。B/C/E2 的未使用 ROM 使用既有测试 fixture。
- 只装载、x=0 时两个声部均静音，证实“有 Note On 装载”不等于“已有激励”。
- 加同样的 Q30 激励后，两个声部均有输出，首个非零声部结果比为 **1.999988**。
- 共运行 34 个样本、68 个逐声部结果；撤掉激励后又检查了 32 个非零尾音样本。
- 对 slot0 发 Note Off 后，active mask 为 `2'b10`，slot1 保持活动。

**边界：** 这是数据映射与小规模数值冒烟，不是听感验收、长时稳定性、平滑 release、完整 B/C/E2、满 16 复音实时性或板级测试。

## 8. 最小可行范围

优先实现一个协议无关的 **MIDI 语义适配层 + A 类激励/生命周期前端**：

1. 指定一个或少数本机 patch，不要求完整 GM 音色库。
2. 明确支持音符清单；先做缺层回退，再离线补缺音。
3. 接 Note On/Off、velocity=0、基本 program 映射和声部分配。
4. A 类 pulse、逐声部释放/回收和采样边界调度。
5. 延音踏板、通道音量与表情随后接入；连续弯音和 B/C 音色资源作为独立后续工作。

**最终判断：阻碍不是 MIDI 与核心“格式不兼容”，而是缺少把演奏事件转换为完整引擎作业的控制/激励前端，以及足够完整的 patch 数据。**

## 参考

- [MIDI Association：MIDI Messages](https://midi.org/about-midi-part-3midi-messages)：音符、力度、通道控制与 program 的语义。
- [MIDI Association：General MIDI Level 1](https://midi.org/general-midi-level-1)：GM 与普通 MIDI 的区别，program 编号不携带具体音色声学参数。
- [Microsoft：Standard MIDI Patch Assignments](https://learn.microsoft.com/en-us/windows/win32/multimedia/standard-midi-patch-assignments)：0-based GM program 对照。
- [MIDI Association 论坛：Zero velocity note on](https://midi.org/community/midi-specifications/zero-velocity-note-on)：velocity=0 的 Note On 等价 Note Off。
- 项目源码：`rtl/core/router_system_top.sv`、`router_loader.sv`、`index_loader20.sv`、`index_loader64.sv`、`class_format_pkg.sv`、`modal_record_pkg.sv`、`shared_modal_ram.sv`；参数生成见 `python/modal_sim/params.py`、`gen_coeff_table.py`、`gen_hw_rom.py`。
