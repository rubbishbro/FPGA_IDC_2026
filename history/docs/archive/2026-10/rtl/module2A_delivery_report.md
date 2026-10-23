# 模块 2A 交付与独立审查报告

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期：2026-10-04。

> **交付结论：2A 的功能、逐位一致性与周期门槛通过；七项审查问题已修复并独立复测关闭。Gowin 综合/布局布线与上板验证未执行，不能认定硬件时序已通过。最终验收由项目作者判定。**

## 1. 分工与范围

- 设计/测试规格、独立审查与本报告：父会话 GPT-6.1 Sol。
- RTL 与第一轮 cocotb：用户指定的 OpenCode Go / DeepSeek V4.1 Flash，模型 ID `opencode-go/deepseek-v4.1-flash`。
- 实现会话：`ses_efc5c87faffeAkN1anQu23XwfT`。
- 本次只交付单声部模块 2A；2B 系数 ROM 装载、2C 32 声部调度未实现。
- 规格文件：`rtl/module2A_design.md`，包含接口、数值契约、流水周期表、测试 T01–T14 与验收门槛。
- 保留已有未提交改动；不修改冻结清单、模块 1、整数模型或系数文件，不执行 git commit。

## 2. 独立基线检查（已完成）

### 2.1 当前模块 1

使用当前 FS=30 的 `resonator.sv`，Icarus 13.0 + cocotb 2.1.0，独立 build/test 目录 `/tmp/opencode/module2a-review/baseline-resonator/`。

结果：**7/7 PASS**。覆盖多组随机/边界系数、55 Hz 长尾、空拍、运行中重载、load/valid 冲突、负饱和、负半 LSB。随机测试实际触发 8763 次饱和；低频自由衰减 40007 个样本逐位相等。

此项只确认模块 1 和当前参考链可用，不代表 2A 已通过。

### 2.2 浮点→整数链与系数文件

实际对四个乐器分别运行：

```bash
python python/modal_sim/fixed_point_check.py -i guitar --seconds 1.0
python python/modal_sim/fixed_point_check.py -i piano --seconds 1.0
python python/modal_sim/fixed_point_check.py -i banjo --seconds 1.0
python python/modal_sim/fixed_point_check.py -i mandolin --seconds 1.0
```

四次退出码均为 0；每乐器选择五个音域探针，检查可用力度档。全表系数扫描：

| 乐器 | 模态数 | 最大频率误差/cent | 最大相对 gamma 误差 | 最大极点模 | 实根数 |
|---|---:|---:|---:|---:|---:|
| guitar | 1690 | 3.62 | 0.00114 | 0.999994606 | 0 |
| piano | 1223 | 21.59 | 0.00488 | 0.999997437 | 0 |
| banjo | 1775 | 1.11 | 0.00110 | 0.999992788 | 0 |
| mandolin | 795 | 0.45 | 0.00109 | 0.999988705 | 0 |

另以 `gen_coeff_table.build()` 生成内存中系数/索引，与现有 `.mem`、`coeffindex.json` 逐项对比：四种乐器、250 个表项、5483 条系数 **全部一致**；未重写文件。

独立补充全 250 个音/力度表项的短窗波形检查：每表项 2048 样本，关闭参考的噪声与声部回收，直接运行浮点/整数引擎。共 512000 个样本；所有表项 SNR >=30 dB。每乐器最差 SNR：guitar **37.82 dB**、piano **40.74 dB**、banjo **47.77 dB**、mandolin **51.04 dB**。这仍是参考链检查，不是 2A RTL 结果。

### 2.3 长尾背景检查

直接运行现有 `limit_cycle_check.behavioral('piano', 21, 1.0, max_s=30)`：Q2.30、free_thr=2e-4 下，实际回收时间 **20.5608125 秒音频时间**。

随后完整运行 `python python/modal_sim/limit_cycle_check.py`，退出码 0；全表解析门槛通过，最坏四个表项的实际回收分别为 MIDI21 forte **20.6 s**、MIDI21 piano **29.8 s**、MIDI23 forte **17.2 s**、MIDI24 piano **30.1 s**。

另计算每个音所有模态的常数固定点上界之和，最坏为 piano MIDI21 forte，约 `5.9150e-5`，低于 free_thr。该解析上界针对常数固定点，不是任意极限环或整个硬件声部回收功能的证明；2A 本身不实现声部回收。

基线日志：`/tmp/opencode/module2a-review/numeric-chain/`。

## 3. 2A 实现与架构审查

实现者创建 `rtl/core/modal_lane.sv`、`rtl/core/modal_bank.sv`、`sim/test_modal_bank.py`。父会话另写 `sim/test_modal_bank_independent_review.py`，不复用实现者的驱动/收集辅助代码，也不写 RTL 内部状态。

首版源代码符合主要计算结构：四 lane、每 lane 一个 signed 26×32 `*`、58 位注册乘积和 64 位累加器；一个共址同步读/写缓存，不复位 RAM；state_valid 位图清状态；每模态三槽连续运行。量化只在合并三项后执行，状态 Q2.30、部分和与总和保持 64 位/30 小数位。

lane_done 是保持到下次 start 的电平，不是单拍，因此不同 lane 的完成时间可以汇合。最后一次 RAM 写回时 lane 才进入 DONE。top 分别等待 DONE、注册总和、返回空闲；out_valid 时还有 OUT 收尾阶段，下一帧握手需等待 sample_ready，不能假设 out_valid 与 ready 同拍。

最终每 lane 分配 `LOCAL_MODES=ceil(N_MODES/4)` 个槽。N_MODES=48 时，每 lane 为 **24×72 位缓存 +12 位 state_valid**；四路缓存总计 6912 bit（包含状态 padding），而不是首版的 27648 bit。top 的 coeff_loaded 仍为全局48位。

独立检查 Icarus 编译产物：四份 `.array "mem",23 0,71 0`，四个普通 `%mul` 运算点。这是逻辑结构确认，不是物理 DSP/BSRAM 映射报告。

### 实际流水周期表

t=0 是第一条系数字同步读的边沿；一条 lane 的乘法寄存器延迟为一拍。ID/操作有效性由固定 ph/mi 调度恢复，而非使用额外 tag FIFO；改变乘法器延迟时必须重新设计这些依赖。

| t | 缓存端口 | 乘法器输入 | 累加/结果 |
|---:|---|---|---|
| 0 | 读 coeff0 | 无有效操作 | 启动 |
| 1 | 读 state0 | G0*x | 捕获 a1/a2 系数 |
| 2 | 默认地址读，数据不用 | a1_0*y1_0 | acc=G0*x；捕获 old_y1/y2 |
| 3 | 读 coeff1 | a2_0*y2_0 | acc-=a1_0*y1_0 |
| 4 | 读 state1 | G1*x | acc-=a2_0*y2_0 |
| 5 | 默认地址读，数据不用 | a1_1*y1_1 | 量化0并保存 pending0；acc=G1*x |
| 6 | 读 coeff2 | a2_1*y2_1 | acc-=a1_1*y1_1 |
| 7 | 读 state2 | G2*x | acc-=a2_1*y2_1 |
| 8 | 写 state0，read-first 返回值不用 | a1_2*y1_2 | 提交0；量化1并保存 pending1 |
| 11 | 写 state1 | a1_3*y1_3（若存在） | 提交1 |

后续每三拍提交一条模态。部分和在量化完成时累加；外部结果等待最后一次写回后才生成，因此不会把“计算完成”误当作“状态已提交”。写回与下一结果生成同边沿时用旧 pending 写 RAM，再用新结果更新 pending。零输入旁路显式令 G 槽乘积寄存器为零，不改变三槽周期。

最终有效帧延迟：n=0 为2拍；n>0 为 `3*ceil(n/4)+8`，满48模态 **44拍**，低于52拍门槛。out_valid 后有一个 OUT 收尾周期；实际下一次接受请求需遵守 ready，不能用44作为无条件请求间隔。

## 4. 2A 实际测试结果

### 4.1 首版独立补测（已执行，修复后需再跑）

```bash
python sim/test_modal_bank_independent_review.py \
  --build-dir /tmp/opencode/module2a-review/independent-default
```

参数 N_MODES=48、SKIP_ZERO_INPUT=1；**3/3 PASS**，XML 已显式检查，命令退出码 0。

| 补测 | 结果 |
|---|---|
| 0..48 升序/降序计数、帧中毒化输入、保持状态更新系数 | 98 帧、2352 个逐模态提交，全相等 |
| 在帧接受后每一个 offset 0..44 复位 | 45 个位置，无旧帧幽灵输出/提交；每次复位后重装验证 |
| 四乐器全部 `.mem`/索引表项，对拍 FixedModalSynth | 250 表项×32 采样 =8000 帧，175456 个状态提交，全相等 |
| 最大有效帧延迟 | 44 周期，门槛 52 |

此测试会检测重复提交、提交 lane 标签、最终输出是否晚于全部写回。它在第一版复测时先暴露了父会话驱动在首次同步复位前读取 X 的问题，以及驱动假定 out_valid 同拍 busy=0 的问题；两者均修正为按 reset/ready 契约驱动，不是 RTL 算术缺陷。

### 4.2 修复后的最终独立复测

父会话实际重跑以下命令，对每次结果再次解析 XML；日志与 XML 保存在对应 build-dir：

```bash
python sim/test_modal_bank.py --skip-zero-input 0 \
  --build-dir /tmp/opencode/module2a-review/final-implementer-regression/full_skip0
python sim/test_modal_bank.py --skip-zero-input 1 \
  --build-dir /tmp/opencode/module2a-review/final-implementer-regression/full_skip1
python sim/test_modal_bank.py --matrix \
  --build-dir /tmp/opencode/module2a-review/final-implementer-regression/matrix
```

| 测试 | 通过情况 | 备注 |
|---|---|---|
| 实现者完整 T01–T14，N=48、skip=0 | **14/14 PASS** | 4乐器各2048采样、200满载帧等 |
| 实现者完整 T01–T14，N=48、skip=1 | **14/14 PASS** | 真实模型直接对拍 |
| 实现者 T13 参数矩阵 | **6/6 PASS** | N=1/7/48 × skip=0/1，输出摘要逐对一致 |
| 父会话独立4项测试×6配置 | **24/24 PASS，无跳过** | 每配置包含全250表项前缀/完整模态集 |
| 全结构尺寸编译 | **96/96 成功** | N=1..48 × skip=0/1；无越界/截断 warning |
| 故意断言失败、空 testcase 过滤器 | **均返回退出码1** | 实际失败路径验证，不是正常 PASS 用例 |
| 相对 build-dir 与同目录切换结构/旁路参数 | **通过** | 1s0→7s1→48s0→48s1→1s1，5次真实重编译/T13通过 |
| `git diff --check` | 退出码0 | 已有用户修改保留 |

父会话独立矩阵命令模板：

```bash
python sim/test_modal_bank_independent_review.py --n-modes 48 --skip-zero-input 1 \
  --build-dir /tmp/opencode/module2a-review/final-independent/N48_s1
```

对 N=1、7、48 及 skip=0、1 六组合分别执行，汇总为 `/tmp/opencode/module2a-review/final-independent/summary.json`。独立矩阵中：

| N | 升降计数帧数/配置 | reset offset 范围 | 全250表项帧数/配置 | 表项状态提交数/配置 | 最大延迟 |
|---:|---:|---|---:|---:|---:|
| 1 | 4 | 0..11 | 8000 | 8000 | 11 |
| 7 | 16 | 0..14 | 8000 | 53664 | 14 |
| 48 | 98 | 0..44 | 8000 | 175456 | 44 |

N=48 的每一配置都检查完整5483条模态系数；小N检查表项前缀，不把它称作完整48模态测试。每配置另外执行确定性非零反馈、cfg保状态、clear保系数、clear/cfg/sample优先级、错误1/2/3与副作用检查；N=1、7时不可表示的非法n_modes值不强行编码。

编译唯一保留的提示为 Icarus `always_comb` 常量选择的敏感列表限制；它会扩大敏感列表，不是数组/位选择越界。默认交付 runner 也进行 -g2012/-Wall 预检查，拒绝其他 warning/error。实现者的小N完整套件里部分重型测试会提前返回；本报告没有用这些返回替代小N实测，矩阵覆盖以独立四项测试为准。

随后还关闭了 R6/R7 的测试入口问题，并对**最终版本**再次执行两个 N=48 的完整14项套件，均14/14通过；执行相对路径 `--matrix --build-dir sim/build/modal_bank_final_relative_matrix`，六组合全部通过。最终CLI日志/XML为 `/tmp/opencode/module2a-review/final-cli-verified/`；相对矩阵产物在指定的 `sim/build/` 下。

父会话另外用同一相对目录 `sim/build/modal_bank_final_reuse` 连续执行 T13，参数依次 `(1,0),(7,1),(48,0),(48,1),(1,1)`：五次XML均1/1通过，没有 `Skipping compilation`，真实结构随参数切换。日志为 `/tmp/opencode/module2a-review/final-cache-and-path-probe/reuse.log`。独立测试入口从最初即使用 always=True，因此其24项矩阵不受R7缓存缺陷影响。

## 5. 审查发现与修复闭环

| 编号 | 级别 | 首版问题 | 状态 |
|---|---|---|---|
| R1 | P1，验证可信度 | runner.test 返回 XML 后 main 直接返回 0，直接 CLI 的 cocotb 失败不保证非零退出 | **关闭**：DS增加XML门槛、移除旧结果；父会话实际失败/空测试均退出1 |
| R2 | P2，RTL 可移植性 | pend_local[ADDRW-1:0] 默认取到变量范围外，Icarus 注入 X，左移后碰巧截掉 | **关闭**：DS改为先构造宽地址再截取；96配置编译无此警告 |
| R3 | P2，资源 | 每 lane 分配 N_MODES 条而实际只需 ceil(N_MODES/4) 条，缓存/位图过度分配 | **关闭**：缓存/位图缩至1/4；独立产物及矩阵确认 |
| R4 | P2，规格符合性 | 零输入“旁路”仅将操作数设零，乘法寄存器仍无条件执行乘法表达式 | **关闭**：显式零乘积旁路，0/1参数数值与周期一致 |
| R5 | P2，测试覆盖 | dict.update 吞掉重复提交；cfg 保状态向量反馈为零；多轮 reset 后未重装导致后续没真正启动 | **关闭**：正式收集器及向量修正；独立逐offset/确定性反馈补测通过 |
| R6 | P2，CLI路径 | 相对build-dir的XML被cocotb按sim目录解析，仿真成功后找不到结果文件 | **关闭**：DS统一expanduser/绝对路径；父会话相对矩阵和路径复用验证通过 |
| R7 | P1，参数测试可信度 | Icarus增量构建只检查源文件mtime，同一目录换N/skip会沿用旧参数二进制 | **关闭**：DS增加always=True；同目录五组合重建并逐项通过 |

R1 已单独实际复现：以当前 cocotb runner 运行临时 intentional_failure 用例，XML 为 (1 test,1 failure)，runner.test 仍正常返回，外层 Python 进程退出 0。原因可见工具包 runner.py 的 663–677 行：只有 pytest 环境才自动检查 XML。临时 probe 在 `/tmp/opencode/module2a-review/runner-probe/`，不改变正式 RTL/测试向量。

修复后用同一临时失败用例调用最终 `_build_and_run()`，外层进程退出1；不存在的 testcase 过滤器同样退出1。日志在 `/tmp/opencode/module2a-review/final-failure-gates/`。

R6 实际复现：相对目录运行 T13 的XML为1/1 PASS，但旧runner按错误路径读取后报 missing XML。R7 实际复现：同目录先N=1成功，再请求N=7时旧runner跳过编译，运行的仍是N=1，在配置mode1时失败。两项修复只修改测试入口，不改变RTL或数值规则；最终复测关闭。

## 6. 硬件验证边界

本机没有主平台 Gowin 工具链，尚未执行综合、布局布线、B-SRAM/DSP 映射确认或 100 MHz 时序收敛。

四个逻辑宽乘法器不等于四个物理 18×18 DSP；RTL 同步 RAM 写法也不自动保证最终 B-SRAM 映射。本报告不得把仿真的 10 ns 时钟视为硬件 Fmax 证明。

## 7. 最终结论

**建议接受为模块2A的功能/周期交付**：默认单声部48模态下，四路共享算力、单端口同步工作缓存和整数规则通过独立复测；满载帧44周期满足52周期门槛，七项审查发现均已关闭。当前没有未关闭的功能/周期阻塞项，但这不是形式化正确性证明。

交付文件：

| 文件 | 作者/职责 |
|---|---|
| `rtl/module2A_design.md` | 父会话；设计、接口与测试规格 |
| `rtl/core/modal_lane.sv` | DS；单lane实现及审查修复 |
| `rtl/core/modal_bank.sv` | DS；四lane单声部top及审查修复 |
| `sim/test_modal_bank.py` | DS；正式回归、参数矩阵、可靠失败退出 |
| `sim/test_modal_bank_independent_review.py` | 父会话；独立补测 |
| `rtl/module2A_delivery_report.md` | 父会话；本报告 |
| `rtl/README.md` | 父会话仅追加模块2A文档链接，保留原内容 |

**未交付：2B、2C，以及Gowin综合/布局布线与实板验证。** 作者确认2A后，可进入2B系数ROM/索引装载；2C仍需单独设计32声部状态地址与采样帧预算，不能把本报告当作32声部已经实现的依据。
