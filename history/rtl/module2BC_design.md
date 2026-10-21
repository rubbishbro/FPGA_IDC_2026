# 模块2B/2C：系数装载与32声部计算——设计与测试规格

日期：2026-10-04。依据：`DECISIONS.md`及已验证的2A；本文件是实现方案，不擅自修改冻结清单。用户已明确：缺失音/力度档**拒绝报错，不替代，保留原声部**。

## 1. 范围与新增上板目标

- 2B：离线生成硬件索引/系数ROM，同步读取、按声部装载、状态初始化与load_done。
- 2C：32声部独立状态，四条共享计算lane，逐采样调度、声部和/总和输出。
- 自动歌曲：后续用ROM音符事件、短激励驱动实时合成，不播放预录PCM。声部槽由歌曲离线分配，不冒充阶段4自动声部分配。
- 音频目标经用户澄清：7pin模块是MAX98357A功放，需求是**FPGA→标准I2S→MAX98357A→2pin喇叭播放**，不是麦克风采集/监听。板载PT8211采用另一种LSBJ格式，不套用到MAX98357A。具体供电/接线与FPGA输出引脚仍需核实。
- 上板需要板级时钟、音频串行收发、CDC、输出增益/量化、可能的codec初始化。硬件未确认前不生成猜测引脚，不宣称已上板成功。
- 不实现阶段4回收/抢占、箱体、特征识别或麦克风录音；2B/2C不能替代整机音频验收。

## 2. 文件与实现边界

新建 `python/modal_sim/gen_hw_rom.py`、`rtl/core/coeff_loader.sv`、`rtl/core/poly_modal_lane.sv`、`rtl/core/modal_poly_bank.sv`、`rtl/core/modal_engine.sv`，对应测试现位于`sim/unit/core/`（系数装载与引擎）。保留原2A接口和文件，poly lane可以以2A为基础扩展，但不能实例化32套2A或128个乘法器。

生成产物放 `rtl/rom/`：合并系数 `modal_coeff.mem`（5483行×72bit）、稠密索引 `modal_index.mem`（1024行×20bit）、元数据 `modal_manifest.json`。原 `FFT_results/params/` 文件只读，不重写。

## 3. ROM与装载契约（2B）

乐器编号固定 `0=guitar,1=piano,2=banjo,3=mandolin`；输入 `load_dyn` 是**采样层/档位**而非原始力度，`0=piano,1=forte`；新增 `load_vel[7:0]` 是压力传感器的 8-bit 力度（0..255），只缩放冲激幅度，不参与索引。索引地址仍为 `{instrument[1:0],midi[6:0],dyn}`。索引word：`[19]=present,[18:13]=n_modes(6bit),[12:0]=合并系数起始offset`；空项为0。生成器严格校验key、MIDI0..127、原mem72bit、n=1..48、偏移合法、不重叠以及覆盖全部行；不因排序改动原表项语义。结果可重复生成并byte-for-byte一致。

`coeff_loader`参数NUM_VOICES=32,N_MODES=48, ROM文件名及COEFF_DEPTH=5483；ROM均同步读，initial/readmemh初始化，不在运行时解析JSON。ROM是只读，可读成一个72bit逻辑端口，不作物理BSRAM映射承诺。

接口：clk/rst_n；load_valid/ready、load_voice[VW]、load_instrument[2]、load_midi[7]、load_dyn[1]、load_vel[8]；busy、load_done、done_voice[VW]、loaded_n_modes[MW]；error_valid/error_code[2]（1=voice越界,2=缺表项,3=ROM元数据非法/超过结构N_MODES）；下游clear_valid/ready/voice；cfg_valid/ready/voice/mode/word。VW=max(1,clog2(NUM_VOICES)),MW=max(1,clog2(N_MODES+1))。

`load_vel` 在 load 握手时锁存；`vel_q=round(vel*32768/255)`（UQ1.15），对每个 72-bit word 只改 G：

```text
G' = clamp(round(G * vel_q / 32768), 26-bit signed)
a1' = a1, a2' = a2
```

`vel=255` 走旁路，逐位等于原 ROM word。把 G 乘 vel 与把 x 乘 vel 对线性递推等价，因此不用在 32 个 `x_vec` 通道上加乘法器；缺点是只在装载时生效，运行中 aftertouch 要改成 x 侧逐采样缩放。

这条 `26×17` 乘法在 `S_CFG` 当拍从 `coeff_rdata` 组合到 `cfg_word`，是新增的 ROM 输出→bank 写数据路径。综合/P&R 必须单独检查；若 setup 不够，加一级 `S_SCALE`（每词多 1 拍）或把缩放移到 bank 的 cfg 写端。

仅load握手锁存输入；busy时load_ready=0。先完整查表并校验范围，再clear指定声部，再按0..n-1输出系数；cfg/clear在ready前保持字段不变；最后cfg真正握手后才load_done。下游背压任意长不会丢词/重复提交。缺表项/非法元数据**不得clear或cfg**，不发load_done；错误脉冲后返回空闲。reset取消事务及所有有效token。reset途中部分装载不提供事务回滚：整机reset同时清loaded标志，因此该声部不可使用，必须重新装载。

无背压load延迟上界 `4*n+24`（最多216拍）；实际周期报告测量。拒绝错误上界16拍。

## 4. 存储与帧调度（2C）

每lane仅一个signed26×32乘法器、一个72bit同步单端口RAM。容量：`NUM_VOICES*LOCAL_MODES*2`，LOCAL_MODES=ceil(N_MODES/4)。地址：`2*(voice*LOCAL_MODES+local_mode)+coeff/state`；各lane均用相同声部槽，mode%4选lane。默认每lane768×72，总221184bit；状态位图每lane32×12。clear仅清指定声部的state_valid分片，coeff_loaded位图保留；cfg写保持历史状态。RAM不reset。

允许**逐声部运行并排空**，而不是本阶段强行做跨声部无缝流水：2A实测满载44拍，32声部即1408拍，仍有可量化调度余量。此方案必须实际测32×48最坏帧（不是用1152理论下界替代测量）。全帧门槛**1800拍**，低于最短2083拍采样预算，保留至少283拍供事件/装载等；配置与计算不并发。大量装载事件不能无上限挤进每帧，歌曲需预装/事件背压规划，另测整机deadline。

`modal_poly_bank`接口：clk/rst_n；cfg_valid/ready/voice/mode/word，clear_valid/ready/voice，clear_done；sample_valid/ready、active_mask[NUM_VOICES]、n_modes_vec[NUM_VOICES*MW]、x_vec[NUM_VOICES*32]；busy；out_valid、mix_sum signed64(30frac)、sat_count总饱和计数SW=max(1,clog2(NUM_VOICES*N_MODES+1))；voice_valid/id/sum signed64；error_valid/code（1=配置/clear地址非法,2=有效声部n越界,3=有效声部所需系数未装载）；commit_valid[4]、commit_voice[4*VW]、commit_mode[4*MW]、commit_y1/y2[128]、commit_sat[4]。字段i按[i*宽度+:宽度]。

优先级reset>clear>cfg>sample。busy时三个ready为0；非法请求握手后error，无计算/写回副作用。帧接受时锁存全部active/count/x；**计算任何声部前检查整个帧合法性**，后一个声部非法也不得更新前面声部状态。输入不活跃的槽本帧不更新（历史冻结）；活跃n=0合法，输出零声部和。voice_valid每活跃声部一次，最后所有状态提交完成后out_valid一次；mask全0返回零混音。输出无背压。各lane done不能被上一声部的DONE电平误判。sum/saturation不在声部边界截断；64bit范围足够1536条int32相加。

**2026-10-20 扩展：C seed 写口（ENG1 重构第一步）**：新增 `seed_valid/seed_ready/seed_voice[VW]/seed_mode[MW]/seed_word[63:0]`。仅 `idle && !clear_valid && !cfg_valid` 时握手；写状态槽 `{8'b0, seed_word[63:32], seed_word[31:0]}`（RAM 奇地址），并置 `state_valid`；非法 `seed_voice/seed_mode` 报 error 1；`seed_valid` 期间 `sample_ready=0`，首帧前必须写完。与 cfg 共用单端口 RAM，不新增存储。`modal_engine` 目前把 `seed_valid` tie-off 为 0，等统一 loader 接入；A 路径逐位不变。

## 5. 集成接口

`modal_engine`集成loader与poly_bank，参数继承ROM、NUM_VOICES/N_MODES/SKIP_ZERO_INPUT。

外部load口同loader；sample_valid/ready、active_mask、x_vec；busy；load_done/done_voice/loaded_n_modes；out_valid/mix_sum/sat_count、voice_valid/id/sum、commit总线；error_valid/code[3]（1..3装载错；4=激活未成功装载的槽；5=内部bank错误）。工作n_modes在每次load_done时由engine存入对应槽，不由帧发送者伪造。只有成功装载标记的active声部允许帧。

装载与计算**互斥**；空闲同时load_valid/sample_valid时load优先，不能同时握手。loader握手的当拍起锁住sample，整个clear/cfg期间不允许帧；计算busy不接受装载。失败装载不改变已有engine元数据、状态、系数。全帧active未装载错误不能部分计算。engine reset取消计算和装载并清全部loaded标志。自动歌曲上层今后基于ready调度，不能盲发单拍事件。

**2026-10-20 E1：`class_loader.sv` 替换 `coeff_loader`（ENG1 重构第二步）**：`modal_engine` 内改为实例化 `rtl/core/class_loader.sv`；旧 `coeff_loader.sv` 保留，`core/coeff_loader` 直测仍覆盖它。新 loader 的 Event 端口由 engine 用旧 `(instrument,midi,dyn,vel)` 合成（`ev_class=0`、`ev_layer={1'b0,load_dyn}`），A 的 20-bit index 在模块内适配成 `present/n/offset`。Core 改为 **1 词/拍**：地址 `offset+cnt(+1)` 组合给出，同步 ROM 下一拍把数据送到 cfg；48 模态约 `n+6≈54` 拍（旧 216）。新增 `seed_*` 与 `commit_*` 端口，A 的 seed 恒 0；B/C 的 Control/Index/Seed ROM 与 class 选择下一步接。A-only 的 `core/engine` 逐位回归仍通过（e01–e07，含 e02 2048 帧长测；最坏 1508 周期）。

## 6. 测试规范

环境Icarus13/cocotb2.1，脚本命令行返回可信退出码，显式XML（无测试/失败/无法解析均非零）、always=True保证参数改变重编译，绝对build路径、-g2012/-Wall；仿真Timer/每事务有限超时。配置参数测试N=1/7/48、V=1/3/32、skip0/1，小结构不能静默把超限表项截成成功。

### 2B

1. 250有效key全部装载，对比原始mem对应区间、mode/voice、清状态一次且在写系数前、load_done晚于最后握手。
2. 全1024索引组合：缺项严格报错且无clear/cfg；有效和缺失请求交替。
3. 固定随机背压；阻塞时valid与所有字段稳定；忙时毒化load输入，重复load、reset在查表/clear/中段/最后写槽，无幽灵完成。
4. 生成器复现、5483词/250条、每key偏移与字段校验；坏JSON/越界/不合法动态/多余词拒绝，不改原文件。
5. 无背压最大延迟<=4*n+24，错误<=16拍；结构N小于表项n时拒绝，不截断。

### 2C与集成

1. 默认32声部全部装同一48模态真实音piano21forte；每声部不同x、按commit逐条对比状态与sat，声部和/总和逐位对比，持续至少100帧，**每帧<=1800拍**。
2. 活跃mask=0、单槽0/31、交错、全活跃；n=0/1/3/4/5/47/48（bank直接配置）；inactive历史冻结，返回active接续；唯一地址标记检测跨声部污染。
3. 多乐器多力度、多声部不同长度，至少2048采样窗口，与每声部FixedModalSynth(max_poly=1,free_thr=0)直接step对拍，不只复制递推公式。
4. 拒绝未装载active槽；错误位于后面槽时前面不能提交；load失败不改原槽，再采样验证旧状态接续；只重装某一槽清其历史，其他槽保留。
5. 帧中毒化全部输入，发cfg/clear/load冲突，无ready时无副作用；最早合法下一帧；clear/cfg/sample同拍优先级。
6. reset覆盖计算初始/中间/最后写回/输出、装载查表/背压/写最后词；整机重装后正常，无旧commit/out/load_done。
7. 参数矩阵、skip结果一致；正负饱和、半LSB、总sat>63防截断，混音正负且超int32不提前限幅。
8. 原2A完整回归保留通过。源代码/编译结构检查只有四个逻辑乘法器及四工作存储端口；物理资源和Fmax仍待Gowin。

## 7. 交付判定

DS V4.1 Flash实现；父会话独立审查/复测并写`docs/archive/2026-10/rtl/module2BC_delivery_report.md`。分清实现者报告、独立执行、功能周期门槛与尚未执行的板级验收。自动播放和麦克风链路另有验收记录，不能仅依据2B/2C完成而声称上板已打通。

## 8. 数据格式冻结（2026-10-20，B/C 统一）

> 本节覆盖前文“20-bit index / layer / 64 模态”的旧描述；A 的 20-bit index 只作为兼容适配器保留。

- **宽度**：Event 64 / Key 13 / Index 64 / Control 256 / Core 72 / Seed 64。
- **Key**：`{class, instrument, note}`，**没有 layer**。`velocity` 是唯一力度字段（8-bit）。
- **Index 64**：`present/n_modes[6:0]/n_vel[2:0]/mode_offset[15:0]/ctrl_index[11:0]/version[1:0]/has_control/has_seed/class[1:0]/flags[5:0]`。
- **力度带**：`n_vel=4` 先冻结；`vel8 = midi*2`，`band = vel8[7:6]`；`core_addr = mode_offset + band*n_modes + mode`。
- **模态**：`N_MODES=48` 对所有类；`M_ACTIVE_MAX=1536`；不再有 64 模态。
- **A 的 dyn**：存在 Event 的 `reserved_lo[0]`，只由 A 适配器使用；B/C 必须写 0。
- **C**：`version=2`、`has_seed=1`、`n_vel=1`；seed ROM V=4，地址 `piece*192 + variant*48 + mode`。
- **源文件**：`rtl/core/class_format_pkg.sv` 与 `python/modal_sim/class_format.py` 位序必须一致；对拍入口 `sim/unit/core/test_class_format.py`（T-F01）。
- **ratio 的 Q**：16-bit **UQ1.15**（1.0 = `0x8000`，范围 <2）；要 >2 用 UQ2.14。旧文档写的 “UQ1.16 / 16-bit” 是笔误（1+16=17 bit）。
- **B loader**：`rtl/core/class_loader64.sv`（64-bit index、4 带、Control 256、C seed）；A 仍用 `class_loader.sv` 的 20-bit 适配。
- **class 选择**：`class_loader_mux.sv`；`modal_engine` 新增 `USE_BC`、`load_class[1:0]`、`load_note_id[11:0]`、`commit_ctrl[255:0]`；`USE_BC=0` 时 A 行为不变。
- **B θ ROM**：`python/modal_sim/gen_b_theta.py` 从 72-bit core 反算 `θ=acos(-a1/(2r))`，输出 UQ2.14 `b_theta.mem`（与 core 同布局，只读）；loader 只写 per-voice `theta_base`（32×16 FF），**不写 θ RAM**；`test_b_theta.py` 4/4；demo 见 `rtl/rom/demo/`。
- **B a1 刷新**：`rtl/core/b_a1_refresh.sv`；`rtl/core/b_a1_engine.sv`（θ ROM + theta_base + bank 系数读 + a1 shadow 写）+ `poly_modal_lane` 的 a1 shadow/coeff 读口 + `modal_poly_bank` 的 a1_we/coeff_rd 路由；`s=sqrt(4a2−a1²)`（Q2.24→Q1.12），`δθ=(ratio−1)·θ`（θ UQ2.14，ratio UQ1.15），`a1'=a1+s·δθ−a1·δθ²/2`；先覆盖颤音/±50c，大滑音以后换直接 cos。
- **B Control 字段（Round 9 冻结）**：`period_T[15:0]`、`attack_step[39:16]`、`release_step[63:40]`、`base_inc[95:64]`（UQ0.32，避免除法器）、`noise_gain[135:120]`；`class_vec` 每声部 2-bit（0=A/1=B/2=C）；`x = impulse ? env*vel>>17 : 0`。
- **B 多声部 x**：`rtl/core/b_x_pool.sv`（Control 解析 + N×`b_voice_ctrl` + class 门控）；`test_b_x_pool` 2/2 通过。
- **顶层 x mux**：`modal_engine.ctrl_flat` -> `eng1_voice_top` 的 `b_x_pool`；`class=0` 用外部 x、`class=1` 用 B x、`class=2` 用 0；`synth_top` 透传 `b_class_vec/b_vel_vec/b_start_mask/b_gate_mask/b_ratio`。
