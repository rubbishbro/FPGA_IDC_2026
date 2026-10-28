# eng1 演奏前端：现状与设计

更新：2026-10-29。周期激励/ADSR已实施，当前状态见第11节；前文行为测量属于实施前基线。本文统一维护持续音色的前端合同；整数算术模型归[ENG1 Python模型](ENG1_PY_MODEL.md)，执行证据归[工程验证](工程评审与验证.md#global-docs-2026-10-29)。

<a id="current-behavior"></a>

## 当前行为基线

### 已连接的部分

voice_router.sv 中 u_exc（253行）、u_env（260行）已接同一个 smp_tick、门控、力度、retrigger 和 slot_clear。激励经 x_q 进入两 bank 引擎，结果经 Q1.31 包络乘法再混音。前一轮的算术/吞吐/I2S回归验证了这些通路；不能据此称持续音色行为已实现。

### 实测缺口

用生产 exc_router/env_router/parts 和独立 Questa TB，按样本使能推进4800个持音样本（按48k折算100ms；仿真加速使能间隔，不模拟本轮实时预算），四种eng1音色的结果完全相同：

| 音色 | 持音4800样本中的非零激励 | 第1000样本后非零激励 | 按住包络 | MIDI松键后 | PAD松键后 |
|---|---:|---:|---|---|---|
| 长笛/小号/小提琴/大提琴（分别运行） | 各32样本 | 各0 | 0x7fffffff | emap立即0、dead=1 | emap仍0x7fffffff、dead=0 |

这是占位行为的复现，不是持续演奏验收通过。临时TB/runner/日志位于 /tmp/fpga-eng1-review-20261029，不加入正式回归的PASS计数。

1. **持续激励缺失**：exc_router.sv:38–67只有钢琴/吉他专用分支；其余使用32样本上升、GAP=0、N=0。不能保持B类音色的周期驱动。引擎可能靠状态衰减继续出声，但没有持续注入。
2. **每槽周期缺失**：exc_router只有全局 pw_len/gap_len，没有每槽音高/period输入。和弦里各槽不能共用一个period。Python build_b_table明确用T=round(SR/f0)校准模态频率与G，周期必须与同一音高的系数一致。
3. **不能只把N改7**：当前 excitation_gen.sv:151–156每次重发都会taper(tgt)，并有斜坡和指数尾巴；B类参考需要固定幅度、单样本、周期性的冲激。只改参数仍不符合系数标定的输入形状。
4. **正常包络未选择**：env_router.sv:34–42只为钢琴启用ADSR，其余走常数；79–87行使MIDI NoteOff立即静音并声明dead，而PAD松键不声明dead。这与B类起音/保持/释放及释放结束后再清状态的目标不符。这项是普通音符生命周期，不属于已经决定暂缓的panic音频队列flush。
5. **真实音色回归尚缺**：tb_router_midi_eng1使用force的合成ABC系数；tb_i2s_synthesis使用ABC_COEFF合成Flash表。它们证明计算、路由与传输，不证明真实长笛等音色的持续输出、音高及包络。正式后端RESOURCE_MASK仍默认只开放钢琴，不能仅因枚举存在就开放其它音色。

### 可复用依据与定标

python/modal_sim/eng1_bc.py 的BSynth已实现：各槽独立period/phase；gate期间固定幅度周期冲激；NoteOff停止新冲激但保留谐振状态，包络release结束才清状态。router_eng1.py:325–374输出drive_period、attack_s、release_s及ABC系数；FFT_results/params有四种乐器的sustain.npz。

本轮能实际生成这四种乐器的MIDI69参考表，period均109，活动模态分别32/36/36/36，证明已有可用的离线模型入口。Python参数选择允许借用最近音高/力度，这不是硬件资源合法性证明，正式打包仍需明确音高及来源。正式32音范围尚未冻结，不能把测试音域当资源承诺。

旧BSynth采用Q30与SHIFT22；当前router输出/激励按Q24解释，等价单位幅度应使用SHIFT16。不能直接复制SHIFT22，再按Q24转PCM；也不能把velocity既乘入激励又重复乘入包络。沿用当前velocity映射一次进入激励，包络负责音量随时间变化。



## 1. 首版范围

首版为长笛、小号、小提琴、大提琴接通逐槽周期冲激和ADSR。钢琴/吉他的现有激励及包络策略保持。eng1算术口和五级流水不改，存储64模态、计算前48模态的合同保留；不足48的B表补零到64。鼓的seed/timer/choke、阶跃音色、菜单音量、panic音频队列flush不加入此次实施。

不新增生产RTL模块，在既有router、excitation、envelope内修改。新增类型/常量函数和离线生成文件不构成新控制层。需要的资源是小量逐槽配置/计数状态，不存整段激励波形。

## 2. 从演奏输入到声音

```text
PAD fmap --门限/起音/力度--┐
                         ├-> performance_input_mux -> gate/trigger/clear/level
MIDI gate/velocity ------┘                         ├-> excitation -> x[slot]
                                                  └-> envelope   -> E[slot]
资源身份(音色,slot MIDI) -> 同源配置 -> period/A/R          |
                              ABC RAM -> eng1(x) -> 乘E -> 混音/腔体/混响/PCM
I2S帧节拍 ---------------------> 同步至core后统一推进上述采样状态
```

fmap是测得的压力，不能直接当成已经生成的周期音频。沿用现有PAD门限和MIDI gate/retrigger语义，不从MIDI velocity推断键是否按住，也不把压力差分默认解释为击键速度。

## 3. 激励形状合同

| 模式 | 输入序列/行为 | 首版选择 |
|---|---|---|
| LEGACY_STRIKE | 现有斜坡/尾部/锤击配置 | 钢琴、吉他保持原选择 |
| IMPULSE_TRAIN | 每T个采样一个固定幅度冲激，按住期间持续 | 四种eng1持续音色 |
| PULSE2（候选） | 触发后A,A,0,0…，不是一正一负 | 本次不启用；未来有对应资源再实现/验证 |
| STEP（候选） | gate期间x=A，gate结束后x=0 | 本次不启用；不能拿B类冲激串标定表直接替代 |

不按A/B/C字母机械分配形状，也不把鼓的seed初始化当作STEP。本次只增必需的IMPULSE_TRAIN分支，不为未使用的候选增加状态机。

IMPULSE_TRAIN逐槽状态：16bit倒计时phase，可复用excitation_gen中按槽计数器。合法周期2..65535；无效配置在资源准入时拒绝，防御路径保持零输入，不能默认为440Hz。

每个音频采样的优先级：

1. slot_clear或资源切换清理：x=0，phase=0。
2. gate=0：x=0，phase=0；不再发新冲激。
3. onset或retrigger：x=A，phase=T-1。
4. phase=0：x=A，phase=T-1。
5. 其它：x=0，phase=phase-1。

onset由采样边界上的gate上升沿得到；retrigger沿用已有显式输入。同音重复起音只重置本槽的相位、包络和模态状态，不能清其它槽。每T个音频帧发一个冲激，不是每T个系统时钟或模态作业。

新分支不使用taper，不加入旧锤击的斜坡或指数尾巴。phase在gate期间与音高配置保持稳定，普通力度变化不重置相位。

## 4. 力度与数值

沿用performance_input_mux的8bit level：PAD来自压力；MIDI由7bit velocity映射，1->2、64->129、127->255。MIDI力度随本次NoteOn保存；PAD在每次发冲激时使用当前采样的压力幅度，允许持续音随压力变化。松键由gate控制，而不是等待压力数值自己归零。

每次冲激：x_int=level<<16，以Q24解释，255对应约0.996。这不是运行时除法；保留signed32位接口。旧Python B模型SHIFT22属于Q30，新的参考/测试按Q24生成，不能直接比较两套不同二进制点的整数。

B类ADSR只给时间轮廓，不再次乘velocity或PAD压力，避免力度平方。PAD变化先按现有8bit分辨率逐冲激采样；首版不附加动态音色调制或新平滑器，之后可根据听测决定。

## 5. 包络与槽生命周期

四种持续音色选择ADSR，复用现有envelope_ADSR状态机。增加可选逐槽A_STEP/R_STEP参数；钢琴仍用旧全局常量，不改变其状态机节拍。B类公共D_STEP=1048576，S_LEVEL=0x1fffffff，与BSynth的ENV_ONE//4一致。

A/R由同一音符的参考表派生：

- attack=max(table.attack_s,0.003s)，A_STEP=max(1,floor(ENV_ONE/(attack*resource_fs)))。
- release=max(table.release_s,0.020s)，R_STEP=max(1,floor(ENV_ONE/(release*resource_fs)))。
- ENV_ONE=0x7fffffff。未提供元数据时不静默套其它音高；生成器需要显式规定并在manifest记录回退策略。

这里release表示满刻度对应的下降斜率，沿用BSynth合同；从1/4 sustain电平释放，实际到零时间约为该满刻度时间的1/4，不能在UI中把这个参数直接称为每次松键的固定释放时长。若以后要求固定时长release，另行修改算法和参考，首版不引入运行时除法。

起音当帧E=0，下一采样开始上升，明确沿用RTL时序；旧Python参考需对齐此事件和采样边界后再做逐样本比较，不能直接声称两者原样逐点相同。

| 事件 | 激励 | 包络 | 引擎历史/槽 |
|---|---|---|---|
| NoteOn/onset | 第一个冲激，重置相位 | 重启attack | 清旧历史后计算当前输入 |
| 按住/CC64保持gate | 按槽周期持续 | attack/decay/sustain | 保留历史 |
| 普通NoteOff/CC123导致gate释放 | 停止新冲激 | 进入release | 释放期间保留历史，不交给另一归属 |
| release完成 | x=0 | E=0，dead置位 | 跑一次清状态帧，确认后槽可复用 |
| CC120/hard_clear/维护 | x=0，相位清0 | 当帧清0 | 按现有操作退休协议确认清理 |

同一归属的重复NoteOn仍可按既定语义打断release重新起音；另一归属要等释放清理完成。panic的音频FIFO撤销仍按之前决定暂缓。

### dead与真正idle的区别

现有voice_idle来自env_dead，启用release后需要在voice_router补一个逐槽清理待办位，复用/扩展已有dead_pend/dead_f：dead只表示包络归零；只有该槽的引擎清零作业已真实退休，才对外报告voice_idle。不能在env_dead一置位时就允许另一归属抢槽。

清理帧若有新的本槽retrigger，按新的起音优先级处理，不能把新音符当成旧release的空闲完成。此合同需用并发On/Off/重触发测试验证，不新增第二份MIDI生命周期表。

## 6. 逐槽配置及资源来源

建议在router_pkg内定义：

```systemverilog
typedef struct packed {
    logic [15:0] period;
    logic [31:0] a_step;
    logic [31:0] r_step;
} sustain_cfg_t;
```

每槽80bit，16槽一份共1280bit（160B逻辑参数容量）；若同时保存pending和active两份，共320B，不含已有MIDI音高映射与计数器。实际寄存器/ROM映射以综合结果为准，不声称一定不占BSRAM。

离线生成器一次生成：

- 按现有64byte记录和64模态存储深度打包的ABC系数：a11=G、a12=a1、a21=a2；其余字段按B类合同填零。
- 配套的play配置常量文件和manifest：同一个(音色,MIDI)的period、A/R、资源采样率、来源记录、有效标志和系数校验信息。

配置常量从同一次build_b_table结果导出，不独立手填第二张音高表。16槽对应当前装载半区，32音仍通过loader切两组16；可在同一音高的MIDI/PAD演奏之间共用配置。

首版配置常量随RTL构建，使用生成的函数/ROM查找，不修改Flash记录、loader读协议或擅自占用参数半区；更换资源需要同时更新配套构建产物。若未来需要独立升级Flash而不更新配置常量，则必须升级为loader读回元数据/校验身份的资源协议，不属于本次最小接入。

Python的最近音高回退不能自动视为合法硬件资源。生成时要显式允许并记录重定音来源，或拒绝缺少的音高；正式32音范围仍由资源清单冻结。首版RESOURCE_MASK只有在实际资源与对应配置都齐全后才开放音色。

## 7. 接口与提交边界

- midi_voice_top：把已经使用的slot MIDI映射送入voice_router。NOTE_BANKS=1时从first_midi_note和bank生成；NOTE_BANKS=0时沿用slot_note_map。
- pad_voice_top：增加同源slot MIDI映射输入/资源配置参数，不能假定slot0永远等于MIDI0。默认映射必须与使用的资源manifest一致。
- voice_router：新增slot MIDI映射口，在真正接受inst/reload换表事务时，锁存候选音高映射并查找pending sustain_cfg；活动配置供exc/env使用，外部输入变化不能直接穿透。
- exc_router/excitation_gen：增加B模式选择与逐槽period输入。
- env_router/envelope_ADSR：增加B选择与可选逐槽A/R输入；旧全局参数分支保留。
- eng1、系数RAM地址布局、Flash记录格式与读协议不改。

换表事务：

```text
旧帧排空/维护清理
  -> 接受目标(音色、bank、slot MIDI映射)
  -> 生成并检查pending配置
  -> 现有loader加载对应ABC表
  -> 成功边界一起启用：系数有效身份 + active配置 + 归零的激励/包络状态
  -> 第一帧初始化/清理退休
  -> 后端确认成功、准入新音符
```

pending无效或Flash加载失败，均保持静音、通过现有失败结果路径结束，不提交成功身份，不自动无限重试。需将配置失败并入既有load_err/load_complete语义，保证上层不会永远等一个未启动的loader。

普通挂起换音色仍遵循已有ready规则：若继续演奏旧表，就继续用旧active周期/A/R，直到真正接受换表。事务中途外部bank/map再次变化不能修改已锁存目标；新请求按现有队列/重试规则处理。

## 8. 采样与帧一致性

所有相位、激励和包络只在统一音频采样使能推进一次。配置查找和逐槽准备可以使用帧间系统时钟，不得在一个采样内推进64次相位。

采样边界先决定本帧gate/trigger/clear和激励/包络next值；router在随后系统时钟锁存同一帧x/E快照供全部A/B槽作业使用。不要用新帧的x搭旧帧的E，也不要在帧尾用变化后的E覆盖前面声部。包络状态lvl与emap现有的一帧关系须在实施时统一成上述明确合同，钢琴旧行为保持兼容分支。

采样率必须来自资源manifest：周期按resource_fs生成；I2S实际Fs必须与它匹配。12.5MHz/256虽没有生产消费漂移，但播放48k资源仍有速度/音高偏差，不能把它算作精确48k音高验收。

## 9. 实施与验收顺序

1. 固定上述逐槽参数和采样合同，生成两种不同音高的真实B表及配置，建立独立整数参考。
2. 修改现有激励模块，单测单样本冲激、精确间隔、跨槽独立、力度和重触发。
3. 接ADSR和清理退休后的idle，单测attack/sustain/release、PAD松键、延音及清除并发。
4. 将音高映射/配置纳入换表事务，覆盖持音挂起换色、32音换组、缺表/坏表/中途输入变化和恢复。
5. 16槽、64存储/48计算、真实B表、I2S时基下持音至少1秒并比较PCM；再跑已有MIDI/UI/loader/音频回归。定常音高比较使用表的实际drive频率resource_fs/T，另报告与理论MIDI频率的整数周期偏差。
6. 通过后进入外部子系统完整联调；键盘分支修复另行迁移并回归。

## 10. 当前工作区差异

本轮设计核对时发现，midi_voice_top/pad_voice_top当前缺少上轮已测试快照中的AUDIO_ENABLE/audio_clk/I2S出口；voice_router的外部sample_tick口和音频模块文件仍在。两个顶层及相关测试有新的工作区改动。设计实施前先核对并发改动和上轮测试快照，再确定恢复/合并方式；本次文档审查未覆盖这些RTL修改。29日重新运行sim/run_audio.py：256组eng1算术对拍和PCM/I2S单测通过；首个系统矩阵因缺AUDIO_ENABLE参数在展开时失败。旧24项结果仅属于当时快照。

## 11. 2026-10-29 实施状态

本方案的RTL及回归入口已实现；以下更新覆盖前面的“草案/尚未实施”和第10节接线缺失基线。旧测量留作修复前证据。

- 在原excitation_gen内增加B类冲激串分支，复用逐槽cnt，四种音色经exc_router选择；固定单样本冲激，无锤击taper。PAD在发冲激时采样当前力度，MIDI沿用保存的velocity。
- 同一envelope_ADSR实例增加可选逐槽A/R及当帧B输出；钢琴仍保留旧输出延迟及全局参数。B类D_STEP=1048576、S_LEVEL=0x1fffffff。持续音色译码与原有参数同步寄存，避免音色比较串入包络算术。x与E一起锁存成帧快照，全部A/B声部使用同一帧。
- voice_router增加S_CFG，按槽查找并锁存pending配置，避免16份并行查表。每槽依次寄存音高、查表结果、校验提交，三拍完成；16槽共48拍准备（100MHz下0.48μs）。接受换表时同时锁存slot MIDI映射和Flash字节偏移；配置非法有独立、有界的失败完成，不启动loader、不假提交；成功加载才更新active配置。
- voice_idle改为包络归零、门控解除且实际清零帧退休后才置位。新的起音会取消本槽旧空闲确认；无新增MIDI归属表。
- MIDI顶层增加slot_map_q/target_slot_map，旧16音自定义映射随配置事务锁存，避免候选音高先泄漏到音符分配；NOTE_BANKS=1仍由first MIDI和bank产生映射。PAD顶层新增同源slot_note_map输入，默认旧16音映射仅用于兼容。
- 两个现有顶层恢复AUDIO_ENABLE/audio_clk/I2S分支，音频模式下使用I2S主时基。默认AUDIO_ENABLE=0保留旧独立仿真入口。panic FIFO flush仍暂缓，原忙时panic问题M14本轮未扩展。

### 参数与镜像生成

新增生产资源为类型、生成的package/manifest及离线脚本，没有新增生产RTL模块。sustain_cfg_t另包含一个valid位，实际每槽81bit；pending+active的16槽参数共2592bit（324B逻辑容量），不计已有映射/计数器。具体物理映射以综合为准。

生成器：rtl/router/tools/sustain_resources.py，依赖现有numpy/scipy参考模型。已入库sustain_profiles_pkg.sv与sustain_profiles.json为四种音色MIDI0..127的配置目录，包含来源音高、力度、retuned标志、参数来源文件hash和各音符系数hash；目录存在不表示Flash已安装对应资源，也不改变默认RESOURCE_MASK只开放钢琴。

配置目录显式允许从邻近采样重定音，512条中349条有重定音标记；其余为同音高采样来源。实际演奏仍受当前装载音组限制，不承诺128音可同时访问。正式32音域仍未冻结。测试候选48..79是生成的32音资源，不能把它写成赛题或产品正式音域。

```bash
# 生成一组候选32音的四种B音色镜像和manifest；不会改仓库中的钢琴/吉他镜像。
# Python环境需numpy/scipy，示例路径为本机已安装环境。
/home/rubbishbro/micromamba/envs/torch312/bin/python rtl/router/tools/sustain_resources.py \
  --first-midi 48 --notes 32 --allow-retune --out build/sustain/resources
```

每乐器区域131072B，B四种音色放在inst2..5；前两个区域为FF占位，不能直接把这个候选文件覆盖含钢琴/吉他的正式整片镜像。部署时必须将有效乐器区域与当前钢琴/吉他资源合并，并保持32音区域步长一致。当前16音钢琴/吉他镜像不能直接拼到32音区域里。修改镜像资源需同步更新生成配置和manifest；没有运行时Flash hash认证。

不带--allow-retune时，缺少原音高采样会明确失败。包含此选项时生成器记录来源并为目标音高重新生成极点及G，不仅修改标签。48kHz资源需匹配实际48kHz音频时钟；12.5MHz调试参考仍只能用于时基/传输检查。

### 验证入口

- sim/run_sustain.py：四种音色各48000样本前端独立参考、资源事务、真实B表16槽逐帧递推与包络比较、I2S独立线端解码；生成测试镜像到私有build目录，不覆写默认资源。
- sim/run_audio.py：既有流水、PCM、两类顶层与时钟矩阵。
- sim/run_router_midi.py：既有MIDI、配置及失败恢复。
- sim/run_flash_ref.py：公开vendor模型的钢琴/吉他64存储/空片与音乐冒烟；不再靠预灌RAM。
- sim/synth/sustain_build.tcl：Gowin仅综合探针，可用QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software启动无界面工具；不是板级顶层或PnR证明。

实施的日期化结果统一写入工程评审与验证，本文不重复全局PASS计数。
