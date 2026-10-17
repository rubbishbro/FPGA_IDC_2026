---
title: Tang Mega 138K Pro Platform
keywords: FPGA, Tang Mega 138K Pro, GW5AST, Gowin
---

# Tang Mega 138K Pro 平台说明

> 本项目主力 FPGA 平台。  
> 本文只保留开发、资源规划、接口使用和工具链相关信息，不保留宣传性描述。

## 1. 平台定位

- 开发板：**Sipeed Tang Mega 138K Pro Dock**
- FPGA：**GW5AST-LV138FPG676A**
- 文档产品概述中的完整型号：**GW5AST-LV138FPG676AC1/I0**
- 工艺：**22 nm**
- 核心板尺寸：**50 mm × 70 mm**
- 核心板与底板：**BTB 连接器**
- 调试：**JTAG + UART**

该平台资源规模较大，并带有 DDR3、高速收发器、PCIe 硬核和 RISC-V AE350_SOC 硬核。项目开发时应优先根据实际模块需求使用资源，不应因为板卡存在某项硬件就默认引入对应依赖。

## 2. FPGA 核心资源

| 资源 | 数量 / 参数 |
| --- | ---: |
| LUT4 | 138240 |
| FF | 138240 |
| S-SRAM | 1080 Kbit |
| B-SRAM | 6120 Kbit |
| B-SRAM Block | 340 |
| 18×18 Multiplier | 298 |
| PLL | 12 |
| 全局时钟 | 16 |
| 高速时钟 | 24 |
| Transceiver | 8 |
| Transceiver 速率 | 270 Mbps ~ 12.5 Gbps |
| GPIO Bank | 6 |
| LVDS | 1.25 Gbps |
| DDR3 接口速率 | 1333 Mbps |
| ADC | 2 |
| 硬核处理器 | RISC-V AE350_SOC |

对于当前 FPGA 音频项目，优先关注 **LUT / FF / B-SRAM / Multiplier / PLL**。PCIe、SerDes、MIPI 和硬核 CPU 只有在明确需要时才应进入设计。

## 3. 片外存储

| 资源 | 参数 |
| --- | --- |
| DDR3 | **1 GB**，512 MB × 2 |
| Flash | **128 Mbit × 2** |

片上 B-SRAM 足够时，优先使用片上存储完成波表、FIFO、短延迟线等低延迟数据路径；DDR3 应作为大容量数据存储资源单独引入，不应成为基础模块的默认依赖。

## 4. 高速硬核与专用接口

| 功能 | 参数 |
| --- | --- |
| PCIe 硬核 | 1 个，支持 x1 / x2 / x4 / x8 PCIe 3.0 |
| MIPI D-PHY 硬核 | RX 2.5 Gbps，8 数据通道 + 2 时钟通道 |
| 高速收发器 | 8 路，270 Mbps ~ 12.5 Gbps |

底板提供：

- PCIe ×1 连接器：**4 lane @ 5 Gbps**
- SFP+ ×2
- 千兆以太网 ×1
- DVI RX ×2
- DVI TX ×2
- MIPI CSI ×2，4 Lane
- DVP Interface ×1
- RGB Interface ×1，支持 RGB888
- M.2 ×1

> DVI RX 与 DVI TX 存在资源互占，使用前必须结合原理图和约束文件确认。

## 5. 与音频项目直接相关的板载资源

| 接口 / 资源 | 数量 | 说明 |
| --- | ---: | --- |
| MIC ARRAY Interface | 1 | 支持 Sipeed 6+1 麦克风阵列 |
| 扬声器接口 | 1 | 板载音频输出路径 |
| 3.5 mm 耳机接口 | 1 | 音频输出 |
| PMOD | 3 | 外接 DAC、传感器或控制模块 |
| 40P 排针 | 1 | 通用扩展 |
| ADC | 2 | FPGA 芯片资源 |
| 按键 | 4 | 本地控制输入 |
| LED | 6 | 状态显示 |
| WS2812 | 1 | 与 aRGB 共用数据引脚 |
| aRGB | 1 | 与 WS2812 共用数据引脚 |
| SD 卡槽 | 1 | 大容量外部数据 |
| EEPROM | 1 | 参数 / 配置信息存储 |

对于电子乐器项目，优先利用 **PMOD / 40P / MIC ARRAY / 扬声器 / 3.5 mm / LED** 等接口。接口最终是否可直接使用，必须依据板卡原理图和全引脚约束确认，不能仅根据接口名称假设电气连接方式。

## 6. 时钟与辅助器件

- 板上有 **MS5351 ×2**
- 用途：为 SerDes 提供 RefClk
- 输出通过底板串口控制
- PWM 风扇接口 ×1
- 电源输入：**12 V DC**
- 自定义 USB ×1，但**不能用于给板卡供电**
- USB JTAG & UART ×1，可烧录 FPGA 并提供串口功能

PLL 和外部时钟源应通过 platform / clock wrapper 管理，不应让具体板级时钟直接渗入算法 RTL。

## 7. 工具链要求

### Gowin IDE

**Tang Mega 138K Pro 当前不支持教育版。**

要求：

- 使用 **Gowin 商业版 IDE**
- 版本：**V1.9.9 或更新**
- 需要有效 License

官方文档特别标注：

> **V1.9.10.02 Programmer 存在严重问题，无法正常下载本产品。**

因此项目环境配置中应记录实际使用的 IDE / Programmer 版本，不要默认升级到 V1.9.10.02。

### License

License 可：

1. 向高云官网申请；
2. 使用 Sipeed 提供的在线 Float License 服务。

Sipeed 文档给出的在线 License：

```text
---Server 01---
ip: 106.55.34.119
port: 10559
```

IDE 中选择 `Float Lic` 使用。

## 8. 开发时的板级边界

为了避免主工程与具体板卡强耦合，建议将以下内容视为 **Tang Mega 138K Pro platform layer**：

```text
platform/tang_mega_138k_pro/
├── top.sv                  # 板级顶层与物理 IO
├── clock_reset.sv          # PLL / 时钟 / 复位
├── board_io.sv             # LED / KEY / PMOD / audio 等板级封装
├── memory_wrapper.sv       # DDR3 / B-SRAM / ROM 等器件相关封装
└── tang_mega_138k_pro.cst  # 引脚与 IO 约束
```

核心算法 RTL 不应直接依赖：

- FPG676A 物理 Pin；
- 具体 Bank；
- 板级 PLL 配置；
- DDR3 控制器实例名；
- AE350_SOC；
- JTAG / UART 下载逻辑；
- 板载外设的固定地址或实例名。

如果必须使用 Gowin IP，应通过 wrapper 隔离，避免器件 IP 实例扩散到整个工程。

## 9. 开发前必须查阅的硬件资料

按开发价值排序：

1. **全引脚约束**：建立 `.cst` 和检查 IO Bank。
2. **板卡原理图**：确认外设、电气连接、复用关系。
3. **板卡规格书**：确认供电、接口和工作条件。
4. **芯片手册**：确认 GW5AST 资源、时钟、RAM、DSP 和专用硬核。
5. **内部走线长度**：高速接口需要时使用。
6. PCB BOM / 机械尺寸 / 3D 模型：硬件集成或外壳设计时使用。

官方资料：

- [板卡规格书](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/01_Specification)
- [板卡原理图](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/02_Schematic)
- [PCB BOM](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/03_Designator_drawing)
- [板卡尺寸图](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/04_Mechanical_drawing)
- [板卡 3D 模型](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/05_3D_file)
- [部分芯片手册](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/07_Datasheet)
- [内部走线长度](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/08_Pinout_Length_table)
- [全引脚约束](https://dl.sipeed.com/shareURL/TANG/Mega_138K_Pro/09_Misc)

## 10. Coding Agent 使用约束

Coding Agent 在生成 Tang Mega 138K Pro 相关代码时：

- 默认目标 FPGA 为 `GW5AST-LV138FPG676A`；
- 不得把 Tang Mega 138K 非 Pro 的 PG484A 约束或器件配置套用到本平台；
- 板级 Pin、IO Standard、时钟和复用关系必须从原理图 / 官方约束文件获取，不允许猜测；
- 不得因为板载 AE350_SOC 存在，就默认用 CPU 替代 FPGA RTL；
- 不得默认 DDR3 已经初始化或可直接访问；
- 使用 Gowin IP 前必须确认其目标器件为 GW5AST-138K；
- 修改时钟、DDR3、PCIe、SerDes、MIPI 等专用硬核配置时，应把器件相关逻辑限制在 platform / wrapper 层；
- 每次实现完成后至少检查综合、布局布线和时序报告，避免只通过 RTL 仿真判断可用性。

---

## 来源说明

本文由 Sipeed `Tang Mega 138K Pro Dock` 平台资料整理而来，只进行了信息重排、开发相关信息筛选和 Markdown 格式优化。硬件规格、工具版本、接口数量及 License 信息均以原始平台文档为依据。
