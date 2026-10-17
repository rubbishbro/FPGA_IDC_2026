# FPGA Hardware Platform

> 作用：描述本项目的平台分工、跨板迁移边界和 Coding Agent 的硬件假设。  
> 赛题功能与评分要求见 `competition_reques_important.md`、`gowin_competition_notes.md`。  
> Tang Mega 138K Pro 的详细资源、接口和工具链信息见 `tang_mega_138k_pro_platform.md`。

## 1. 平台分工

项目采用两级 FPGA 平台：

- **主力 / 最终平台：Sipeed Tang Mega 138K Pro Dock**
- **前期验证平台：立创·逻辑派 FPGA-G1**

逻辑派只承担早期 RTL、仿真、时钟/复位、基础 GPIO 和音频链路验证；最终资源规划、器件 IP、引脚约束、板载外设和系统集成都以 **Tang Mega 138K Pro** 为准。

竞赛官方指南列出了 Sipeed Tang 系列 138K 平台，同时明确允许使用第三方、以高云 FPGA 为核心的开发板。因此，前期使用逻辑派验证、后期迁移至 Tang Mega 138K Pro 的开发方式与竞赛平台规则不冲突。

## 2. 主力平台：Tang Mega 138K Pro

最终工程目标器件为：

- FPGA：**GW5AST-LV138FPG676A**
- 封装：**FPG676**
- LUT4：**138240**
- FF：**138240**
- B-SRAM：**6120 Kbit**
- 18×18 Multiplier：**298**
- PLL：**12**
- 板载 DDR3：**1 GB**
- 调试接口：**JTAG + UART**

完整板卡资源和接口定义不在本文重复维护，统一以 `tang_mega_138k_pro_platform.md` 为准，避免两个文件产生不同版本的参数。

### 2.1 工程使用原则

音频核心优先使用 FPGA 逻辑、DSP 和片上 B-SRAM。波表、FIFO、短延迟线等在容量允许时优先使用片上存储；DDR3 只在录音缓存、长延迟效果或其他明确的大容量需求出现后再引入。

Tang Mega 138K Pro 带有 RISC-V AE350_SOC 硬核，但本项目默认**不使用它实现音频合成、混音、效果器或 FPGA 可视化核心逻辑**。这些路径应保持为 FPGA HDL 数据通路，避免因 CPU 依赖破坏赛题要求和跨平台结构。

### 2.2 工具链

Tang Mega 138K Pro 与普通 Tang Mega 138K 的器件和工具链要求不同。当前项目必须按 **Pro / FPG676** 平台配置工程，不允许直接复用普通 138K / PG484A 的 device、pin constraint 或 IP 配置。

具体 Gowin IDE、Programmer、License 和板卡资料要求统一见：

```text
tang_mega_138k_pro_platform.md
```

## 3. 前期验证平台：立创·逻辑派 FPGA-G1

逻辑派 FPGA-G1 用于快速验证，不作为最终资源基准。当前已确认的主要条件：

- FPGA：**Gowin GW2A-LV18 系列**
- 系统时钟：**50 MHz**
- 板载 DDR3：**256 MB**
- QSPI Flash：**W25Q64，64 Mbit / 8 MB**
- FPGA 扩展 IO：约 **65 路**
- 板载 micro HDMI
- 支持 Gowin 下载、固化、在线逻辑分析和串口
- 板载 **GD32F303 MCU**

逻辑派资料中已有 Gowin、ModelSim、Testbench、PLL、ROM/RAM、FIFO、UART、HDMI、DDR3 以及部分音频接口参考工程，适合作为前期 Bring-up 平台。

### 3.1 MCU 使用边界

板载 GD32F303 不进入音频核心数据通路。默认禁止使用 MCU 实现：

- 振荡器 / DDS；
- 波表合成；
- ADSR；
- 多声部混音；
- 音频效果器；
- FPGA 可视化核心算法。

如果 MCU 仅用于板级辅助、调试或与核心算法无关的临时功能，应与 FPGA 核心逻辑隔离，并在工程中明确标记。

## 4. 跨平台 RTL 边界

核心原则：

> **从 LogicPi G1 迁移到 Tang Mega 138K Pro 时，只允许修改 platform 层、器件 IP wrapper、约束和规模参数；算法 RTL 原则上不改。**

建议目录：

```text
rtl/
├── core/                              # DDS / wavetable / ADSR / voice / mixer / effects
├── interface/                         # I2S / UART / SPI 等协议逻辑
└── platform/
    ├── logicpi_g1/                    # LogicPi top / PLL / board IO
    └── tang_mega_138k_pro/            # 138K Pro top / PLL / board IO / device wrappers

constraints/
├── logicpi_g1.cst
└── tang_mega_138k_pro.cst

sim/
└── ...                                # 尽量板卡无关的 testbench
```

必须遵守：

- `rtl/core/` 不出现物理 Pin 名称；
- `rtl/core/` 不直接依赖某块板的输入晶振频率；
- PLL、复位极性和板级时钟只在 `platform/*` 处理；
- Gowin primitive / IP 必须通过 wrapper 隔离；
- 波表 RAM、FIFO、乘法器优先使用可综合推断写法；
- I2S、SPI、UART 协议逻辑可以共享，但 Pin mapping 留在板级 top / `.cst`；
- 不允许通过 MCU / PC 软件先计算核心音频结果，再回传给 FPGA 作为输出。

## 5. 参数化与资源伸缩

GW2A-LV18 与 GW5AST-138K 的资源规模差异很大，因此前期验证只要求证明架构正确，不要求在逻辑派上达到最终通道规模。

核心规模必须参数化，例如：

```systemverilog
parameter int NUM_VOICES  = 4;   // 验证平台先小规模，主力平台再扩展
parameter int PHASE_BITS  = 32;  // DDS 相位累加器位宽
parameter int SAMPLE_BITS = 24;  // 内部音频位宽
parameter int TABLE_BITS  = 10;  // 波表地址位宽
```

推荐推进顺序：

```text
LogicPi G1:
1 voice
→ 4 voices
→ ADSR
→ mixer
→ I2S
→ 基础板级输入

Tang Mega 138K Pro:
复用同一套 core RTL
→ 扩展复音规模
→ 优化 DSP / B-SRAM 使用
→ 加入效果器
→ 加入最终交互
→ 加入 FPGA 可视化
```

扩容后若资源或时序失败，应先检查综合和布局布线报告中的 LUT、FF、B-SRAM、Multiplier/DSP 和 critical path，再决定流水线、资源复用或位宽调整，不要直接重写算法功能。

## 6. 存储与乘法资源策略

默认资源优先级：

1. 小型常量：ROM / distributed RAM；
2. 波表、FIFO、短延迟：B-SRAM；
3. 乘法密集路径：优先映射至 FPGA multiplier / DSP；
4. 明确超过片上容量后，再引入 DDR3。

这样可以使 LogicPi → Tang Mega 138K Pro 的迁移主要表现为**资源规模扩大**，而不是基础数据流重构。

器件相关资源通过统一 wrapper 使用，例如：

```text
audio_mul
wave_rom
audio_fifo
platform_pll
external_memory
```

上层模块不得直接依赖具体 GW2A / GW5AST IP 实例名。

## 7. 仿真与板级验证

所有核心模块必须先通过仿真，再接实板。最低覆盖：

- reset 后状态确定；
- DDS 频率控制字与输出频率关系；
- ADSR 状态转换；
- note on / note off；
- voice enable / allocation；
- 多声部求和；
- 缩放 / 饱和处理；
- I2S `BCLK / LRCLK / SD` 时序；
- `NUM_VOICES` 改变后核心行为保持一致。

同一套 core testbench 应能用于两个平台。迁移到 Tang Mega 138K Pro 后，如果功能仿真结果发生变化，应优先检查：

```text
platform wrapper
clock / reset
device IP wrapper
参数配置
```

而不是先修改核心算法。

## 8. 迁移完成判据

前期：

```text
LogicPi G1
    ↓
RTL + Testbench
    ↓
基础 GPIO / I2S / 时钟验证
    ↓
固定 core 接口
```

主力平台：

```text
同一套 rtl/core
    ↓
Tang Mega 138K Pro platform layer
    ↓
FPG676 约束 + Gowin device IP
    ↓
扩大复音 / DSP / B-SRAM 使用规模
    ↓
最终交互 / 效果器 / 可视化
```

满足以下条件，才认为迁移结构合理：

> 核心算法无需因更换开发板而修改逻辑；板卡差异只体现在参数、platform wrapper、device IP wrapper 和约束文件。

## 9. Coding Agent 的硬件假设

除非任务明确指定前期验证板，否则 Coding Agent 应默认：

```text
primary_board = Tang Mega 138K Pro Dock
primary_fpga  = GW5AST-LV138FPG676A
package       = FPG676

validation_board = LogicPi FPGA-G1
validation_fpga  = GW2A-LV18 series
```

Agent 不得：

- 把普通 Tang Mega 138K / PG484A 当成最终目标；
- 猜测 FPG676 引脚或 IO Standard；
- 默认 DDR3 已初始化；
- 默认 AE350_SOC 可用于核心算法；
- 把 LogicPi 上的器件 IP 配置原样复制到 GW5AST；
- 为了验证方便而把板卡差异写入 `rtl/core/`。

## 10. 来源优先级

1. `tang_mega_138k_pro_platform.md`：主力平台详细硬件与工具链说明。
2. 高云竞赛官方选题指南：确认竞赛支持的技术平台和自备高云 FPGA 板卡规则。
3. Sipeed Tang Mega 138K Pro 官方硬件资料：原理图、规格书、约束、芯片资料。
4. 立创逻辑派官方资料：前期验证平台的接口、时钟和例程。
5. `gowin_q&a.md`：仅作补充线索，不覆盖官方赛题和硬件文档。
