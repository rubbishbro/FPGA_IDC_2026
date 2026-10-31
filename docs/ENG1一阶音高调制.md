# ENG1 一阶音高调制

更新：2026-10-30。对象是当前router的四种B类音色：长笛、小号、大提琴、小提琴。
Q2.24静态系数合同见[ENG1模型](ENG1_PY_MODEL.md)。本实现不含二阶项。

## 统一公式与控制

弯音和颤音合成同一个瞬时音分目标：

```
c_target = bend_cents + depth_cents * sin(phase)
c        = slew(c_target)
rho      = 2^(c/1200)
lambda   = rho - 1
a1       = a1_nominal + K * lambda
K        = 2*r*theta*sin(theta)
a2       = r²                         // 保持不变
```

K离线从实际存储的Q2.24极点计算。运行时每模态一次乘加，始终从不可变的标称a1出发，
不累加上一次的调制结果。上下界由离线的`floor(2*r*2^24)-1`生成，输出钳位在其正负值之间，
使有效模态保持复共轭极点与原a2半径；这不是任意时变递推的稳定性证明。

- MIDI Pitch Bend使用14bit值，8192为中心，首版固定±200 cents。
- MIDI CC1控制颤音深度，0关闭，127为±20 cents；按48k资源时基LFO为5.2Hz，音频每96采样更新一次。
- 音分使用Q8，合成目标限在±220 cents；每次控制更新最多移动2 cents。握手确认目标参数已提交，
  连续音高通过slew到达目标，确认不表示音高已经走到终点。
- 共享LFO相位按实际音频采样推进；两个物理MIDI来源各自保存bend、CC1及slew状态。
  音符按`midi_note_state.slot_source`选择所属来源的比例；清理一个来源不重置另一来源的控制。
- 指数映射使用整数音分ROM与Q8线性插值，正弦使用256点ROM；所有可变乘法复用同一条24×25乘法通路。

`pitch_linear.py`提供离线参数、ROM生成和独立整数参考；历史`vibrato_coeff.py`的二阶实验不作为生产实现。

## 原子更新与激励

`eng1_pitch.sv`在后台串行准备全部槽位的有效模态。写入非活动a1缓冲，只有整批准备完成、
且router尚未采集新一帧输入时，才能同时切换系数缓冲和逐槽lambda。eng1算术流水与采样吞吐不变。
两份a1缓冲共用现有系数读口，标称值与斜率复用原参数RAM；参数RAM读地址仲裁后仍为一个读口。

激励使用逐槽40bit Q24相位：每采样加rho，到达`period<<24`时减去该周期并发单采样冲激。
比较前的加法保留第41位进位，覆盖65535采样的最长周期向上弯音。修改rho保持相位，
起音/重触发才清相位；lambda=0时脉冲时刻与原整数周期一致。不新增激励乘法器。

新音符改变槽位来源时，先按已活动的来源比例重建对应系数，再准入重触发；普通释放和硬清除仍可退休，
不被该屏障阻塞。来源清理后，新起音等待该来源的标称系数恢复。部分准备、控制取消、
来源归属在准备中变化、换表及复位均不允许把半批结果发布为活动系数。

`midi_voice_top`内部消费B类的Bend/CC1，不再转发给外部控制端口。成功确认发生在系数/比例提交后；
取消/超时在提交前撤销。其它音色的`CONTROL_SUPPORTED`和外部控制握手保留原合同。
PAD压力映射和菜单控制不在本轮新增范围；引导模式的MIDI仍只控制提示，不改变PAD音高。

## 资源格式

每模态仍为64字节，16个big-endian 32bit word。旧参数半区用于一阶调制：

| word | 内容 |
|---:|---|
| 0 | G，signed26 Q2.24 |
| 1 | 初始a1，signed26 Q2.24 |
| 2 | a2，UQ0.24 |
| 3..7 | 0 |
| 8 | a1下界，Q2.24 |
| 9 | 不可变的标称a1，Q2.24 |
| 10 | a1上界，Q2.24 |
| 11..12 | 0 |
| 13 | K，signed25 Q3.22 |
| 14 | 0 |
| 15 | `0x50315431`，P1T1格式标记（含补零模态） |

`sustain_resources.py`与`gen_sustain_q24.py`共用参数生成函数，manifest标记`pitch_format=P1T1`。
旧Q2.24镜像可以按原音高播放，但缺少P1T1时拒绝调制，保留活动系数；MIDI顶层记录unsupported/error。
旧Q2.20镜像仍不能直接加载。默认板级资源准入范围未扩大；候选B类镜像中的钢琴/吉他区域仍为FF，
不能直接覆盖现有完整Flash。

```bash
# 在具备numpy/scipy的Python环境下运行
python rtl/router/tools/pitch_tables.py
python rtl/router/tools/sustain_resources.py --catalog --allow-retune \
  --out build/pitch_catalog --profile-out build/pitch_catalog/sustain_profiles_pkg.sv
python rtl/router/tools/sustain_resources.py --allow-retune --out build/pitch_resources
python sim/run_pitch.py
```

ROM生成和资源生成是离线操作；更换资源须同步核对manifest及配套配置目录。
验证、模块综合和当前板级边界统一见[工程验收](工程评审与验证.md#eng1-pitch-linear-2026-10-30)。
