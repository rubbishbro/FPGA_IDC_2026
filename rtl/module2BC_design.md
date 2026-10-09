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

乐器编号固定 `0=guitar,1=piano,2=banjo,3=mandolin`；输入dyn是**档位**而非原始力度，`0=piano,1=forte`。索引地址 `{instrument[1:0],midi[6:0],dyn}`。索引word：`[19]=present,[18:13]=n_modes(6bit),[12:0]=合并系数起始offset`；空项为0。生成器严格校验key、MIDI0..127、原mem72bit、n=1..48、偏移合法、不重叠以及覆盖全部行；不因排序改动原表项语义。结果可重复生成并byte-for-byte一致。

`coeff_loader`参数NUM_VOICES=32,N_MODES=48, ROM文件名及COEFF_DEPTH=5483；ROM均同步读，initial/readmemh初始化，不在运行时解析JSON。ROM是只读，可读成一个72bit逻辑端口，不作物理BSRAM映射承诺。

接口：clk/rst_n；load_valid/ready、load_voice[VW]、load_instrument[2]、load_midi[7]、load_dyn[1]；busy、load_done、done_voice[VW]、loaded_n_modes[MW]；error_valid/error_code[2]（1=voice越界,2=缺表项,3=ROM元数据非法/超过结构N_MODES）；下游clear_valid/ready/voice；cfg_valid/ready/voice/mode/word。VW=max(1,clog2(NUM_VOICES)),MW=max(1,clog2(N_MODES+1))。

仅load握手锁存输入；busy时load_ready=0。先完整查表并校验范围，再clear指定声部，再按0..n-1输出系数；cfg/clear在ready前保持字段不变；最后cfg真正握手后才load_done。下游背压任意长不会丢词/重复提交。缺表项/非法元数据**不得clear或cfg**，不发load_done；错误脉冲后返回空闲。reset取消事务及所有有效token。reset途中部分装载不提供事务回滚：整机reset同时清loaded标志，因此该声部不可使用，必须重新装载。

无背压load延迟上界 `4*n+24`（最多216拍）；实际周期报告测量。拒绝错误上界16拍。

## 4. 存储与帧调度（2C）

每lane仅一个signed26×32乘法器、一个72bit同步单端口RAM。容量：`NUM_VOICES*LOCAL_MODES*2`，LOCAL_MODES=ceil(N_MODES/4)。地址：`2*(voice*LOCAL_MODES+local_mode)+coeff/state`；各lane均用相同声部槽，mode%4选lane。默认每lane768×72，总221184bit；状态位图每lane32×12。clear仅清指定声部的state_valid分片，coeff_loaded位图保留；cfg写保持历史状态。RAM不reset。

允许**逐声部运行并排空**，而不是本阶段强行做跨声部无缝流水：2A实测满载44拍，32声部即1408拍，仍有可量化调度余量。此方案必须实际测32×48最坏帧（不是用1152理论下界替代测量）。全帧门槛**1800拍**，低于最短2083拍采样预算，保留至少283拍供事件/装载等；配置与计算不并发。大量装载事件不能无上限挤进每帧，歌曲需预装/事件背压规划，另测整机deadline。

`modal_poly_bank`接口：clk/rst_n；cfg_valid/ready/voice/mode/word，clear_valid/ready/voice，clear_done；sample_valid/ready、active_mask[NUM_VOICES]、n_modes_vec[NUM_VOICES*MW]、x_vec[NUM_VOICES*32]；busy；out_valid、mix_sum signed64(30frac)、sat_count总饱和计数SW=max(1,clog2(NUM_VOICES*N_MODES+1))；voice_valid/id/sum signed64；error_valid/code（1=配置/clear地址非法,2=有效声部n越界,3=有效声部所需系数未装载）；commit_valid[4]、commit_voice[4*VW]、commit_mode[4*MW]、commit_y1/y2[128]、commit_sat[4]。字段i按[i*宽度+:宽度]。

优先级reset>clear>cfg>sample。busy时三个ready为0；非法请求握手后error，无计算/写回副作用。帧接受时锁存全部active/count/x；**计算任何声部前检查整个帧合法性**，后一个声部非法也不得更新前面声部状态。输入不活跃的槽本帧不更新（历史冻结）；活跃n=0合法，输出零声部和。voice_valid每活跃声部一次，最后所有状态提交完成后out_valid一次；mask全0返回零混音。输出无背压。各lane done不能被上一声部的DONE电平误判。sum/saturation不在声部边界截断；64bit范围足够1536条int32相加。

## 5. 集成接口

`modal_engine`集成loader与poly_bank，参数继承ROM、NUM_VOICES/N_MODES/SKIP_ZERO_INPUT。

外部load口同loader；sample_valid/ready、active_mask、x_vec；busy；load_done/done_voice/loaded_n_modes；out_valid/mix_sum/sat_count、voice_valid/id/sum、commit总线；error_valid/code[3]（1..3装载错；4=激活未成功装载的槽；5=内部bank错误）。工作n_modes在每次load_done时由engine存入对应槽，不由帧发送者伪造。只有成功装载标记的active声部允许帧。

装载与计算**互斥**；空闲同时load_valid/sample_valid时load优先，不能同时握手。loader握手的当拍起锁住sample，整个clear/cfg期间不允许帧；计算busy不接受装载。失败装载不改变已有engine元数据、状态、系数。全帧active未装载错误不能部分计算。engine reset取消计算和装载并清全部loaded标志。自动歌曲上层今后基于ready调度，不能盲发单拍事件。

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
