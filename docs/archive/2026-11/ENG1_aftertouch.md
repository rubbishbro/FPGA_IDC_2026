# ENG1 aftertouch

`voice_router → mod_router → modulation1` 负责持续音色的逐声部 PAD 压力调音。
当前启用范围沿用 `is_sustain()`：长笛、小号、大提琴、小提琴。

- 零点沿用 `PAD_NOTE_ON_TH`，当前默认 102。
- 音偏：`max(0, pressure - PAD_NOTE_ON_TH) × 0.6` 音分。
- 默认力度 102 / 152 / 202 / 255 对应 0 / 30 / 60 / 91.8 音分。
- 内部音分为 Q8，四舍五入；255 对应 91.80078125 音分。
- 按住时随压力升降，最低为 0；松键尾音保持最后提交的音偏。
- 无额外 slew 或 LFO。2026-11-03起改为与mod0一致的逐声部start/busy/done作业，不再每96采样整表更新。
- 一次作业只锁存所选声部的压力、门控、来源和使能；作业期间的新压力留待后续更新。
- P1T1 基值不变；由音分换算 Q24 频率比，再计算并限幅 `a1_base + K × delta`。
- `MOD1_MODES_PER_JOB` 限制每声部更新的**前N个模态**，不是轮转分块；其余模态保留名义系数。当前暂定6；TODO：听感还需要验证。
- 直接写既有`ca_a12_a/b`；独立`pitch_a12_a/b`已删除。引擎不读取调制参数表，参数表无需拆分，基值/斜率始终不变。
- 当前帧该声部引擎完成后才能更新；以最近实测采样间隔检查剩余窗口，作业完成并发布该声部频率比后才进入下一采样快照。窗口不足时延后任务，不阻塞音频。
- 轮询加服务轮次标记保证大N时后面的声部不会饿死。现为持续乐器每组退休登记一次请求，包含MIDI禁用压力时的名义系数恢复。
- MIDI velocity 不作为持续压力；原 wheel/bend 请求明确返回 rejected，不产生音偏。
- PAD/MIDI 模式切换和声部归属变化通过提交屏障处理；清理中断半成品作业。

Flash P1T1 与 ratio 表格式不变。旧 sine/depth 表仍占据镜像原位置，但本模块不再存储或使用这些表。
本次不扩大音色范围，也不改变 ENG0 的 modulation0 映射。

验证：

```sh
python sim/run_aftertouch.py
python sim/run_aftertouch.py --model-python /path/to/python-with-numpy
```

第一条为无 vendor IP 的 Icarus 回归：全256个力度值、逐声部隔离、模态上限及高模态不写、正负斜率、上下界限幅、松键保持、压力锁存、格式错误、清理、模式切换与零模态。
第二条追加 40000 个时钟的 Python/RTL 对比，使用已部署 trumpet 的 P1T1 记录。
已执行Questa真实Flash/16声部小号/压力变化/维护重启回归和整数音频对拍，详见预算报告。未重新运行全部MIDI整板案例，未综合或布局布线。

预算实验：`python3 sim/run_mod1_budget.py --out build/mod1_budget_final --frames 320`。使用真实小提琴/小号系数预装载及生产router/engines/excitation；该扫描不含Flash传输时间，不代表物理Fmax。详见[逐声部调制预算](./mod1_逐声部调制预算_20261103.md)。

## 默认值与通道共用（2026-11-03）

当前上限暂设6，RTL各层和Python模型默认值已同步，TODO：听感还需要验证。有效模态数少于6时按实际数量更新，兼容N_MODES=4的轻量测试。上限6的独立回归为1041次作业/6240次系数检查；40000时钟Python/RTL对拍4102次写、683次提交一致。

mod_router现已统一基础作业握手和数据通道：

- 共用start/busy/done。独立pitch_busy不再穿出mod_router；上层在作业期间保持mod_slot，直到正常完成或撤销完成。
- 共用p_re/p_mode和原8字段参数数据总线。所选运算模块决定读使能和模态号，voice_router统一拼接{mod_slot,mod_p_mode}；不再有独立pitch_p_addr路径。
- 共用co_we/co_mode/co_wdata。mod0保留原5字段掩码，mod1只置co_we[1]并输出co_wdata.a12，其他字段不会被写入。voice_router共用loader优先、加载期间屏蔽、地址拼接和A/B bank分发逻辑。
- 没有增加通道寄存级，两个运算模块及其乘法器、状态机、定点计算保持独立；mod1每作业仍为6N+7拍。

mod1特有部分保持原状：sources_ready、cleanup、clear、wheel/bend拒绝应答、逐声部音偏和来源记录、COMMIT/ACK两阶段、pitch_commit均未合并或重定义。cleanup仍可报告撤销done而没有成功commit。pitch_bank保留兼容观测值0，不参与RAM选择。

新增tb_mod_router_channels验证ENG0/ENG1交替作业、参数读延迟、写掩码和算术、无调制乐器空操作、tag错误、cleanup与clear；7次完整作业通过。完整板级源码编译、numeric/reverb回归通过。

统一前后上限6的两种生产引擎预算逐项一致：小提琴601拍、小号779拍，均在1024拍内；每帧均完成16声部更新，单声部作业43拍。真实Flash小号/HALL/压力变化/维护重启640个输出通过，687帧整数音频对拍一致。证据在build/mod_channels_compile/results.json和build/mod_channels_verify/results.json。

重现：

```sh
python3 sim/run_board.py --test numeric --test reverb --test mod_channels --out build/mod_channels_compile
python3 sim/run_mod1_budget.py --out build/mod_channels_verify --caps 6 --frames 320 --real-flash --model-python /path/to/python-with-numpy
```

本次没有合并运算模块，未运行综合、布局布线或烧录。
