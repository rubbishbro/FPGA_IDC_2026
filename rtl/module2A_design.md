# 模块 2A：单声部四路时分复用模态阵列——设计与测试规格

日期：2026-10-04。状态：实现任务规格；最终验收由项目作者判定。

## 1. 范围与依据

以 `rtl/DECISIONS.md` 的当前冻结项为准：100 MHz 核心、48 kHz 音频、每声部最多 48 模态、四条计算 lane；系数 72 位，状态 Q2.30，单模态累加器 64 位。

本次只实现 **2A**，不修改模块 1、已有系数文件或冻结清单。2A/2B/2C 是阶段 2 的工程拆分，不改变原路线：

| 子模块 | 范围 | 本次 |
|---|---|---|
| 2A | 单声部、N 模态工作缓存、四 lane、共享乘法、状态更新、内部求和 | 实现与验证 |
| 2B | 乐器/MIDI/力度档索引 ROM、系数装载、缺失表项策略 | 仅说明边界 |
| 2C | 32 声部的存储地址扩展、活跃声部遍历、帧调度 | 仅说明边界 |

激励由 testbench 提供；不实现脉冲生成、声部分配、回收、抢占、箱体、最终音频量化或 I2S。2A 的 64 位输出是内部求和格式，不冻结 C7。

## 2. 文件与职责

| 文件 | 职责 |
|---|---|
| `rtl/core/modal_lane.sv` | 一条 lane：单端口缓存、流水共享乘法、量化、状态提交、部分和 |
| `rtl/core/modal_bank.sv` | 单声部 top：四 lane、配置路由、握手仲裁、完成汇合、求和 |
| `sim/test_modal_bank.py` | cocotb 回归与命令行 runner |
| `rtl/module2A_delivery_report.md` | 实际实现、审查、测试结果和硬件验证限制 |

禁止直接实例化 48 个 `resonator`。模块 1 的算术规则是依据，不复用其每模态三乘法器结构。

## 3. 数值契约

| 项 | 总位数 | 小数位 | 符号 |
|---|---:|---:|---|
| a1 | 22 | 20 | signed |
| a2 | 24 | 24 | unsigned |
| G | 26 | 24 | signed |
| x、y1、y2 | 32 | 30 | signed |
| 单模态 acc | 64 | 54（乘积标度） | signed |
| lane 和、声部和 | 64 | 30 | signed |

系数字布局与 `fixed_point.pack_word()` 相同：`[71:46]=G`、`[45:22]=a2`、`[21:0]=a1`。

每次有效采样对每条有效模态执行：

```text
P_G  = Gq * xq
P_a1 = (a1q << 4) * old_y1
P_a2 = a2q * old_y2
acc  = P_G - P_a1 - P_a2
raw  = (acc + 2^23) 算术右移 24
ynew = clamp(raw, -2^31, 2^31-1)
state_next = (y1=ynew, y2=old_y1)
```

乘法器系数端统一成 signed 26 位：a1 先符号扩展再移 4 位，a2 先补零再扩展，G 直接使用。另一端 signed 32 位。显式保存 signed 58 位完整乘积，再符号扩展至 64 位。

**只能最终合并后舍入一次**，不可分别截断三个乘积。状态饱和按冻结规格执行，但内部声部和不做 32 位饱和、也不降到 24 小数位。

`SKIP_ZERO_INPUT=1` 时，xq=0 的 G 操作不执行乘法，注入精确为零的乘积 token；保留三槽调度，不宣称少用一个周期。`SKIP_ZERO_INPUT=0` 必须输出完全相同。这里只判断本帧的实际输入为零，不按 A/B/C 类硬编码。

## 4. 存储布局与初始化

四 lane 固定；全局模态 k 映射为 `lane=k%4`、`local=k/4`。

每条 lane 一块逻辑 72 位宽、**同步读、单访问端口**缓存。每模态两地址：

```text
mem[2*j]   = 72 位系数
mem[2*j+1] = {8'b0, y2[31:0], y1[31:0]}
```

单个时钟边沿最多一次缓存访问：配置写、系数读、状态读、状态写互斥。一个逻辑 72 位端口不等于一块物理 BSRAM；推断结果必须以后检查 Gowin 报告。

不在 reset 中循环清 RAM；使用每 lane 的 `state_valid` 位图：reset/clear 清位图，读取无效状态时以 (0,0) 代替未初始化 RAM 内容；状态提交置位。top 的 `coeff_loaded` 位图在 reset 后为零，配置写成功才置位。没有装载全部有效系数的采样请求必须拒绝。

系数配置不隐式清状态：支持以后保持状态更新系数；新音初始化由明确的 clear 请求完成。clear 保留系数及装载位图，仅令所有逻辑状态为零。2A 中配置和 clear 只在空闲时接受。

## 5. top 接口契约

模块名 `modal_bank`。允许结构参数 `N_MODES=48`，范围 1..48；计算 lane 固定 4。计数/模态地址宽度 `MW=max(1,$clog2(N_MODES+1))`。

| 接口 | 方向/宽度 | 含义 |
|---|---|---|
| clk、rst_n | 输入，各 1 | 100 MHz；同步低有效复位 |
| cfg_valid、cfg_ready | 入/出，1 | 配置握手 |
| cfg_mode | 入，MW | 全局模态索引 |
| cfg_word | 入，72 | 系数字 |
| clear_valid、clear_ready | 入/出，1 | 逻辑状态清零握手 |
| clear_done | 出，1 | 清零完成单拍；不生成音频结果 |
| sample_valid、sample_ready | 入/出，1 | 一帧采样请求握手 |
| n_modes | 入，MW | 本帧处理 0..n_modes-1 |
| x_in | 入，signed 32 | 本帧共享激励，Q2.30 |
| busy | 出，1 | 正在处理/合并一帧 |
| out_valid | 出，1 | 声部和有效单拍 |
| y_sum | 出，signed 64 | 内部声部和，30 小数位 |
| sat_count | 出，6 | 本帧状态饱和的模态数量，0..48 |
| error_valid | 出，1 | 非法请求已接受并拒绝，单拍 |
| error_code | 出，2 | 1=配置索引越界；2=n_modes 越界；3=所需系数未装载 |
| commit_valid | 出，4 | 每 lane 状态写回单拍，验证可观测性 |
| commit_mode | 出，4*MW | lane i 字段 `[i*MW +: MW]`，全局模态编号 |
| commit_y1、commit_y2 | 出，各 128 | lane i 字段 `[i*32 +: 32]`，写回的新状态 |
| commit_sat | 出，4 | 对应写回的饱和标志 |

commit 总线是寄存器输出，不提供额外 RAM 读口；只有对应 valid 位为 1 时数据有效。不得以 testbench 写内部寄存器的方式替代正常接口验证。

优先级：reset > clear > cfg > sample。空闲时 `clear_ready=1`；`cfg_ready=!clear_valid`；`sample_ready=!clear_valid&&!cfg_valid`。busy 时三个 ready 均为 0。清零是位图操作，可在握手边沿完成并注册 clear_done。

非法 cfg/sample 请求握手后发 error，不更新 RAM、状态、声部和，不启动计算、不生成 out_valid。错误不是 backpressure；发送方在握手后撤请求。busy 时未握手的请求没有副作用。

sample 接受时锁存 x_in/n_modes，本帧计算不得继续读取外部变化中的输入。`n_modes=0` 合法：不访问模态、不提交状态，输出零和零 sat_count。修改 n_modes 不隐式清被跳过槽位的历史状态。

实现的 out_valid 与 sample_ready **不同拍**：输出有效时 top 仍处于 OUT 收尾阶段，下一边沿返回 IDLE 后 ready 才有效；发送方必须遵守 ready。不能仅依据 out_valid 发起不经过握手的新帧。

reset 清控制与输出寄存器、装载/状态位图，取消正在执行的帧和所有流水 token；不允许复位后冒出旧 out_valid/commit_valid。无效周期 out_valid、error_valid、commit_valid、clear_done 应为零；y_sum 可保留上一结果。

## 6. 流水调度与周期预算

每 lane 稳态 **II=3 模态**，共享乘法器能逐拍接收操作数；不得使用必须等一次乘法完成才接受下一次的 FSM。允许配置/存储流水有独立寄存器。

为单端口缓存分配三类槽：phase 0 读下一模态系数；phase 1 读其旧状态；phase 2 写回较早完成的模态。乘法三槽：G*x、a1*y1、a2*y2，与读取/写回重叠。

下面是可实现的基线，t=0 为第一条系数的同步读边沿，RAM read_data 在该边沿后有效，使用者下一边沿采样：

| t | 缓存操作 | 乘法寄存器输入 | 其他 |
|---:|---|---|---|
| 0 | 读 coeff0 | 无 | |
| 1 | 读 state0 | 无 | 捕获 coeff0 |
| 2 | 无写回 | 无 | 捕获 state0，构造运算上下文0 |
| 3 | 读 coeff1 | G0*x | |
| 4 | 读 state1 | a1_0*y1_0 | 捕获 coeff1；消费 G0 乘积 |
| 5 | 无写回 | a2_0*y2_0 | 构造上下文1；消费 a1_0 乘积 |
| 6 | 读 coeff2 | G1*x | 消费 a2_0，舍入饱和并注册待写结果0 |
| 7 | 读 state2 | a1_1*y1_1 | |
| 8 | 写 state0 | a2_1*y2_1 | 提交0，累加部分和及饱和计数 |
| 9 | 读 coeff3 | G2*x | 注册待写结果1 |
| 11 | 写 state1 | a2_2*y2_2 | 提交1 |

上下文更新与旧上下文最后一次乘法同边沿时，必须使用旧寄存器值。乘积附带 valid、操作类型、local/global mode ID 与 old_y1；最后一个乘积完成时，old_y1 不能误取后续模态的寄存器。

待写结果以 phase 2 消费，生产间隔和消费间隔都是三拍；一个 pending 槽可满足基线，不得覆盖尚未提交结果。最后一次提交后才报告 lane_done。空 lane 不发 token，由 top 的完成位图记录完成；不能要求四路 done 脉冲同拍。

top 可以两级寄存器加法树合并四路 64 位部分和；直到输出寄存器完成才解除 busy。允许不同于上述具体延迟的流水，但必须保持同步单端口存储、四乘法器结构和 II=3，并在交付报告中写明实际周期表。

仿真验收上界：从 sample 握手边沿到 out_valid，`cycles <= 3*ceil(n_modes/4)+16`，含 n_modes=0。满 48 模态上界 **52 周期**。这是 2A 的周期数门槛，不是 100 MHz 硬件时序证明。

2C 的理想稳态工作量为 `3*ceil(1536/4)=1152` 周期。不能简单把 2A 的整帧开销重复 32 次后仍宣称满足；2C 要设计跨声部连续流水、配置访问仲裁并重新测最坏总周期。

## 7. 与后续模块的衔接

2B 使用 cfg 握手装入系数，clear 显式初始化状态；查表元数据需离线转换为硬件 ROM，不解析 JSON。缺失音/力度档策略尚未冻结，2A 不推断。

2C 扩展缓存地址和上下文 voice_id；复用本 lane 算术/调度思想，但不能直接用忙等调用 32 次 top 代替吞吐论证。声部 active/n_modes/x 由外部提供，自动分配和回收仍属于阶段 4。

Gowin DSP 映射、B-SRAM 推断、器件适配和 Fmax 必须另做综合/布局布线。源代码四个 `*` 实例代表四个逻辑宽乘法器，不代表四个 18×18 物理 DSP。

## 8. 测试规格与可判定门槛

环境：`torch312` 中 Icarus Verilog 13.0、cocotb 2.1.0；每 SV 文件有 timescale。runner 须显式选择 SystemVerilog，失败返回非零，设置仿真超时，不产生无限等待。

测试必须同时对比 **每条 commit 的状态/饱和标志** 和 **最终整数声部和/计数**，不能只看总和（相反错误可能抵消）。使用 Python 任意精度整数检查边界；常量和字解包导入当前 `fixed_point.py`。真实音用 `FixedModalSynth(max_poly=1, free_thr=0)` 的 step 直接对拍，避免仅复制公式形成共同错误；2A 不负责声部回收。

| ID | 测试 | 明确判据 |
|---|---|---|
| T01 | reset、配置前状态、空闲 X 检查 | 所有控制/有效输出可解析；零帧成功；未装载非零帧报 code3 |
| T02 | 模态数 0,1,2,3,4,5,7,12,47,48 | 每帧只提交 0..n-1，每条一次；状态、和、计数逐位相等；周期不超门槛 |
| T03 | 多组随机完整系数和有符号激励，固定种子 | 正/负 a1、a2 最高位、负 G、边界 x；不能只随机一组系数 |
| T04 | 正/负半 LSB、正/负状态饱和 | 有定向向量实际触发；结果和 sat_count 精确 |
| T05 | 四路不同系数、唯一模式标记 | 不串模态、不串上下文，不漏写/重复写 |
| T06 | 原始 72 位 .mem 真实音 | guitar/piano/banjo/mandolin 至少各一音；直接 FixedModalSynth 对拍状态/和；包括 piano MIDI21 forte |
| T07 | 修改帧中 x/n_modes/cfg 输入，发 busy 冲突 | 当前帧不受影响；ready=0，无配置副作用，无额外帧 |
| T08 | 不同空拍间隔、下一帧最早握手 | 同一输入序列得到同一状态/结果；状态只能在有效提交时更新 |
| T09 | clear 与配置保持、运行后重装系数 | clear 后状态等于零起步，系数不丢；cfg 写本身不清状态 |
| T10 | 改小再改大 n_modes | 被跳过槽位历史保持，重新参与时接续正确 |
| T11 | busy 中 reset，含流水排空/末尾阶段 | 旧帧完全取消，后续没有幽灵提交或输出；重装后正常 |
| T12 | clear/cfg/sample 同拍；非法 cfg/n_modes | 优先级、ready、error_code 精确；非法请求无副作用 |
| T13 | SKIP_ZERO_INPUT=0/1；结构 N_MODES=1,7,48 | 各配置单独编译；零输入/非零输入结果一致；参数下地址不越界 |
| T14 | 满 48 模态持续帧 | 每帧 <=52 周期；实际最大值记录；无 deadline 违例 |

基础真实音回归建议每音至少 2048 样本；低音长尾为可选慢测试，至少检查单模态 MIDI21 的已知固定点范围在 Q2.30 下低于 2e-4，不能宣称这证明了整个声部必定回收。长音频/全表行为沿用 `limit_cycle_check.py`，属于数值链检查而非 2A 的回收功能。

父会话独立补测入口为 `sim/test_modal_bank_independent_review.py`，不复用实现者的驱动和 commit 收集函数。包含全模态计数升降扫描、每一流水 offset 的 reset、确定性非零反馈/优先级/错误副作用，以及原始 `.mem` **全部250表项各32采样**直接对拍 FixedModalSynth。小结构参数检查每个表项的前缀；N_MODES=48 检查完整模态集。最终测试统计见交付报告。

运行入口示例（实际参数以脚本 --help 为准）：

```bash
export PATH="$HOME/micromamba/envs/torch312/bin:$PATH"
python sim/test_modal_bank.py
python sim/test_modal_bank.py --n-modes 7 --skip-zero-input 0
python sim/test_modal_bank.py --matrix
python sim/test_modal_bank_independent_review.py
```

默认 build、XML、日志输出到 `sim/build/modal_bank/` 或显式 --build-dir；不要覆盖已有 `sim/results.xml`，不要修改已有系数文件。构建与测试产物不加入版本控制。

CLI 必须将 build-dir/结果/digest 路径规范为绝对路径，保证相对目录参数可用。Icarus runner 的增量构建只检查源文件mtime，不检查结构参数；交付入口使用 `always=True`，避免复用同一目录切换 N_MODES/SKIP_ZERO_INPUT 时仿真旧二进制。结果XML必须显式检查：缺失、无法解析、无用例或含失败均返回非零。

## 9. 审查与交付

实现模型按用户指定为 **OpenCode Go / DeepSeek V4.1 Flash**，准确 ID `opencode-go/deepseek-v4.1-flash`。父会话独立审查源代码和测试，重跑回归，发现缺陷后反馈修复或明确记录未关闭项。

交付报告区分：实现者测试、独立复测、源代码架构检查、尚未执行的 Gowin 硬件验证。只有实际执行过的命令和取得的结果才能列为通过。没有综合/布局布线报告时，结论只能是功能与周期验证通过/失败，不能是已经满足 DSP/BSRAM/Fmax。
