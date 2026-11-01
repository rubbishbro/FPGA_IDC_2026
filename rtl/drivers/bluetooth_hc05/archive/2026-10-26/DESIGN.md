# HC-05 蓝牙串口链路驱动设计（Android 专用）

> 日期：2026-10-26  
> 状态：**设计基线，供评审。没有 RTL、没有上板、没有 Android App 代码。**  
> 范围：HC-05 透明串口物理层、双链路分帧／仲裁、回复通路，以及它与共享 MIDI／Config 解析器的接口。  
> 不包含：MIDI 语义解析、fmap 映射、演奏／指导业务、音色与 DSP 参数、Android UI。  
> 相关文档：[协议 v1](../../../analyzer/PROTOCOL_V1.md)、[MIDI 解析合同](../../../analyzer/README.md#midi)、[帧测试向量](../../../analyzer/frame_vectors.json)、[上位机可行性分析](../../../../../docs/上位机.md)。

本文把 HC-05 当成一根**可靠的、无消息边界的透明字节管道**，而不是“蓝牙协议栈”。真正要设计的是：

1. 如何从 HC-05 的 UART 上可靠地恢复字节；
2. 如何在不复制业务解析器的前提下，让有线串口和 Android 蓝牙**并行**工作；
3. 如何把两条链路的“完整帧”安全地交给同一套 MIDI／Config 解析器；
4. 断线、溢出、坏帧时，如何不挂音、不串状态、不伪造 ACK。

---

## 0. 结论摘要

- **HC-05 不解析协议。** 它只做 Classic Bluetooth SPP ↔ UART 透明转换。帧格式、CRC、类型、序号全部由 FPGA 负责。
- **两条链路是同一套 RTL 的两个实例，不是两套分叉实现。** 有线链路和 HC-05 链路在“UART + L1 + 分帧器 + L2”这一层完全相同，只在波特率、`STATE` 引脚和电气参数上不同。
- **分帧必须按链路独立。** 两条链路异步到达，绝不能让两路字节流先混合再分帧；否则 SLIP 边界和 CRC 都会互相污染。
- **仲裁只在“完整帧”粒度做。** 每链路一个完整帧 FIFO，仲裁器一次只把一帧的 payload 字节流交给共享解析器。帧内字节不交错。
- **共享解析器必须每帧复位局部状态。** 协议 v1 已经要求 MIDI 包内自包含；双链路把这条要求从“建议”变成“正确性前提”。
- **推荐 230400 8N1**；115200 用于 bring-up，460800 只在实测稳定后使用。9600 吞吐不够，不建议。
- **推荐 16× 过采样 + 相位累加器（NCO）+ 每个起始位重置相位**。这已经覆盖 HC-05 晶振误差；不建议默认启用完整 PLL。若确实需要跟踪，做**一阶、限幅、可旁路**的数字锁相，而不是二阶模拟式 PLL。
- **“两级缓冲区”落在每链路：L1 字节弹性 FIFO + L2 完整帧 FIFO。** 分帧器内部还有一个 40 字节帧装配缓存，它是事务缓存，不算第三级弹性缓冲。
- **建议容量：L1 = 1024 B，L2 = 8 帧，TX FIFO = 256 B。** 在 115200 下可吸收约 98–146 ms 的下游停顿；在 230400 下约 49–73 ms。资源占用不到 BSRAM 的 0.5%。
- **配置回复按来源回送，去重键用 `{src, seq}`，不能只用 `seq`。** 否则两条链路可能互相重放对方的 ACK。
- **HC-05 只支持 Classic SPP；Android 支持 SPP，iOS 不开放 SPP。** 所以“只面向 Android”不是偷懒，而是 HC-05 的协议事实。若将来要 iOS，需要换 BLE 模组和 GATT 层，分帧器可以复用。

---

## 1. 需求边界

### 1.1 这个“驱动”负责什么

```text
HC-05 的 UART 引脚 / 有线串口的 UART 引脚
        ↓
UART 收发（8N1、过采样、错误检测）
        ↓
每链路 L1 字节 FIFO
        ↓
每链路 SLIP 分帧器（长度、类型、版本、CRC 校验）
        ↓
每链路 L2 完整帧 FIFO
        ↓
完整帧仲裁器（round-robin + source tag）
        ↓
共享 MIDI / Config 解析器
        ↓
MIDI→fmap 适配 / 配置提交
```

本驱动交付到“**已验证的完整帧 + 来源标签 + 回复通路**”为止。

### 1.2 这个“驱动”不负责什么

| 不做 | 原因 |
|---|---|
| 在 FPGA 里实现 HC-05 的 AT 指令 | AT 模式需要 KEY 引脚、固定波特率和模块未连接状态；一次性用 USB-TTL 配好即可。见 §3.3。 |
| 解析 MIDI 音符、CC、弯音 | 这是共享 `midi_analyzer` 的职责，不能塞进 UART／分帧器。 |
| 把 MIDI 事件映射成 fmap、分配 voice | 这是 MIDI→fmap 适配器的职责。 |
| 决定“演奏模式”还是“指导模式” | 这是应用／配置层状态；驱动只传帧。见 §8.7。 |
| 处理 Android UI、配对界面、曲谱 | App 侧职责。 |
| 音频回传、固件下载、BLE | 不在首版范围。 |

### 1.3 关键术语

| 术语 | 含义 |
|---|---|
| **链路（link）** | 一条物理 UART 收发路径。本文有两条：`0 = wired`、`1 = bt`。 |
| **L1** | 每链路一个字节弹性 FIFO，位于 UART 与分帧器之间。 |
| **分帧器（framer）** | 做 SLIP 解码、长度／类型／版本检查、CRC 校验，只发布完整帧。 |
| **L2** | 每链路一个完整帧 FIFO，位于分帧器与仲裁器之间。 |
| **仲裁器（arbiter）** | 从两条 L2 中选一帧，按字节流交给共享解析器；带 `src` 标签。 |
| **共享解析器** | `midi_analyzer` + `config_analyzer`，两条链路共用。 |
| **适配器** | MIDI event → fmap／voice／控制寄存器；不属于本驱动。 |

### 1.4 对“只面向 Android”的确认

HC-05 是 **Bluetooth Classic 2.0/2.1 + EDR**，使用 **SPP（Serial Port Profile）**。Android 通过 RFCOMM 暴露 `BluetoothSocket`，可以使用标准 SPP UUID 连接。

- Android：支持。
- iOS：**不开放 SPP**，只开放 BLE／MFi；HC-05 不能直接被 iOS App 使用。
- BLE 模组（HM-10、JDY-08、nRF52 等）：是 GATT，不是 SPP，不能直接套用本文的“打开 socket 写字节”模型。

所以“只面向 Android”是正确的范围限定。若未来要 iOS，保留本文的分帧器／仲裁器，替换 PHY 和会话层即可；但那是另一份驱动设计。

---

## 2. 系统拓扑

### 2.1 双链路并行

```text
┌─────────────────────┐              ┌──────────────────────┐
│ WebGL / Chromium    │              │ Android App          │
│ Web Serial          │              │ Classic BT SPP       │
└─────────┬───────────┘              └──────────┬───────────┘
          │ USB-CDC                           │ RFCOMM
┌─────────▼───────────┐              ┌──────────▼───────────┐
│ BL616 USB-UART 桥   │              │ HC-05（透明模式）    │
└─────────┬───────────┘              └──────────┬───────────┘
          │ UART 0（有线）                     │ UART 1（蓝牙）
┌─────────▼───────────┐              ┌──────────▼───────────┐
│ uart_rx / uart_tx 0 │              │ uart_rx / uart_tx 1  │
│ L1 byte FIFO 0      │              │ L1 byte FIFO 1       │
│ SLIP framer 0       │              │ SLIP framer 1        │
│ L2 frame FIFO 0     │              │ L2 frame FIFO 1      │
└─────────┬───────────┘              └──────────┬───────────┘
          └──────────────────┬──────────────────┘
                             ▼
                  ┌─────────────────────┐
                  │ frame arbiter       │
                  │ round-robin + src   │
                  └─────────┬───────────┘
                            ▼
                  ┌─────────────────────┐
                  │ shared MIDI/Config  │
                  │ parser              │
                  └──────┬────────┬─────┘
                         │        │
              ┌──────────▼──┐  ┌──▼──────────────┐
              │ MIDI→fmap   │  │ reply formatter  │
              │ adapter     │  │ → TX 0 / TX 1    │
              └─────────────┘  └──────────────────┘
```


关键点：

- 两条链路**同时接收**，各自独立过 L1、分帧器、L2。
- 仲裁器只在两边都有“完整且已校验”的帧时才做选择。
- 共享解析器只看到一帧的 payload 字节流，不会看到两条链路的字节交错。
- 回复（CONFIG ACK）按 `src` 回到原链路，不会从另一条链路冒出来。
- “演奏／指导模式”在共享解析器之后，驱动不感知。

### 2.2 为什么不能“先混合字节，再分帧”

假设把两路 UART 字节直接 OR／MUX 进一个分帧器：

- 两路帧的 `C0` 可能相邻，SLIP 解码器会把 A 的帧尾当成 B 的帧头；
- 帧内字节交错会破坏 `LEN`、`CRC`；
- 一个链路的坏帧会污染另一个链路的同步状态；
- 无法给帧打上正确的来源标签。

所以“**两套独立分帧接收器**”不是可选项，是正确性要求。两条链路可以共享同一个 RTL 模块，但必须是两个实例、两套状态、两套缓存。

### 2.3 为什么仲裁在“完整帧”粒度

- 帧内字节必须连续交给解析器；否则解析器需要知道“这一字节属于哪一帧”，等于把仲裁复杂度下推到解析器。
- 完整帧已经通过 CRC，仲裁器不需要理解内容。
- 一帧最大 40 字节 body，按 1 字节/拍交给解析器只需 32 拍（payload 最大 32 B），仲裁开销可以忽略。
- 帧级 round-robin 不会因为某条链路帧大而长期饿死另一条：大帧的“慢”发生在 UART 线上，不发生在仲裁器里；仲裁器服务一帧只要几十拍。

### 2.4 两条链路的差异

| 项目 | 有线（BL616 USB-UART） | HC-05 |
|---|---|---|
| 物理层 | USB-CDC / VCP | Classic Bluetooth SPP |
| 典型波特率 | 2.5 / 4 Mbaud（可行性文档建议） | 115200 / 230400 / 460800 |
| 流控 | 无硬件流控 | 无硬件流控 |
| 断线检测 | 有限；可能只有 break／USB 拔出 | `STATE` 引脚可用 |
| 典型延迟 | 约 1–4 ms（含 USB/驱动） | 约 20–100 ms（Android 调度 + SPP） |
| 分片方式 | USB 批量传输 + 驱动缓冲 | SPP 字节流，任意分片／合并 |
| 主机 | Web Serial（Chromium） | Android App |
| 时钟 | BL616 晶振 | HC-05 晶振 |

**同一套 `uart_rx` / `framer` / `arbiter` 可以覆盖两者**，但参数不同：

- `BAUD`、`OVERSAMPLE` 每链路独立；
- `HAS_STATE` 只对 HC-05 为 1；
- 有线链路在 >2 Mbaud 时建议把过采样从 16× 降到 8×，否则 100 MHz 下每 tick 只有 1.56 个时钟（4 Mbaud），3 样本多数表决没有余量。见 §4.8。

---

## 3. HC-05 硬件与 Android 约束

### 3.1 接线

HC-05 的 UART 是 **3.3V 逻辑**（裸模块；带底板的模块要看电平转换）。接线必须交叉：

| HC-05 引脚 | 方向 | 接到 FPGA | 说明 |
|---|---|---|---|
| `TXD` | HC-05 输出 | FPGA `UART_RX` | HC-05 发，FPGA 收 |
| `RXD` | HC-05 输入 | FPGA `UART_TX` | FPGA 发，HC-05 收 |
| `GND` | 电源地 | FPGA `GND` | **必须共地** |
| `VCC` | 电源 | 5V 或 3.3V（按底板） | 不要从 FPGA IO 取电 |
| `STATE` | HC-05 输出 | FPGA GPIO（可选） | 连接状态指示；见 §3.6 |
| `EN/KEY` | 输入 | 下拉或悬空（数据模式） | 拉高进入 AT 模式；数据模式不要拉高 |

电气注意：

- 裸 HC-05 的 `RXD` 不耐 5V；如果 FPGA bank 是 5V，必须加电平转换或分压。
- `TXD` 串 220Ω 左右限流；`RXD` 也可串 220Ω 保护。
- 模块峰值电流约 40–50 mA，电源加 10 µF + 100 nF 去耦；不要用 FPGA 的 3.3V 弱上电。
- 天线区域远离 FPGA 高速走线和金属；UART 走线尽量短。
- 如果使用 PMOD，先确认该 PMOD 的 `VCCIO` 是 3.3V；不要凭接口名字假设。引脚分配留给 platform 层 `.cst`，核心 RTL 不出现物理引脚名。

### 3.2 HC-05 不是 BLE

再强调一次，因为这是最常见的集成错误：

- HC-05 = **Classic Bluetooth SPP**，Android 用 `BluetoothSocket` + RFCOMM。
- 不能用 `BluetoothGatt`、`BluetoothLeScanner`、GATT characteristic 去连接 HC-05。
- HC-05 的 SPP UUID 是标准串口 UUID：`00001101-0000-1000-8000-00805F9B34FB`。
- HC-05 同一时刻只支持**一个** SPP 连接。本文的“并行”是“**一条有线 + 一条蓝牙**”，不是“两台手机同时连一个 HC-05”。

### 3.3 一次性 AT 配置

FPGA 不实现 AT 指令。建议用 USB-TTL 适配器在第一次使用时配置 HC-05：

| 目的 | 典型命令 | 备注 |
|---|---|---|
| 进入 AT 模式 | `KEY/EN` 拉高，38400 8N1 | 不同固件可能是 9600；以模块手册为准 |
| 查版本 | `AT+VERSION?` | 确认固件与 AT 语法 |
| 设数据波特率 | `AT+UART=230400,0,0` | 8N1，无流控；先试 115200 更稳 |
| 设名称 | `AT+NAME=FPGA_SYNTH` | 便于 Android 识别 |
| 设 PIN | `AT+PSWD=1234` | 常见默认 1234／0000 |
| 设从机 | `AT+ROLE=0` | 手机作为主机连它 |
| 连接模式 | `AT+CMODE=1` | 允许任意地址；配对后使用 |
| 复位 | `AT+RESET` | 使配置生效 |

注意：

- AT 模式与数据模式是两套波特率；改完 `AT+UART` 后，数据模式用新波特率，AT 模式可能仍是 38400。
- 克隆模块的 AT 命令集可能不同，必须以模块手册为准。
- 不要把 `EN/KEY` 长期拉高；否则模块停在 AT 模式，数据不通。
- 如果模块已焊死在板上，留出 `TXD/RXD/GND/KEY` 测试点，方便返工。

### 3.4 波特率选择

HC-05 的 UART 是瓶颈，不是蓝牙空口。按 8N1（10 bit/byte）计算：

| 波特率 | 字节率 | 单条 Note On 帧（13 B） | 每秒 Note On 帧 | 评价 |
|---:|---:|---:|---:|---|
| 9600 | 960 B/s | 13.5 ms | 约 73 | 太慢，不建议 |
| 115200 | 11.52 kB/s | 1.13 ms | 约 886 | bring-up 默认 |
| 230400 | 23.04 kB/s | 0.56 ms | 约 1772 | **推荐** |
| 460800 | 46.08 kB/s | 0.28 ms | 约 3544 | 实测稳定后使用 |
| 921600 | 92.16 kB/s | 0.14 ms | 约 7088 | 模块/线材/克隆差异大，慎用 |
| 1382400 | 138.24 kB/s | 0.09 ms | 约 10633 | HC-05 上限附近，不建议首版 |

建议：

- **首版 230400 8N1**；bring-up 先用 115200，确认 CRC 错误计数为 0 后再升。
- 高密度乐句不要“一音符一帧”。协议允许一帧放多条 MIDI 消息（payload 最多 32 B）。10 条 3 字节 Note On 放一帧，payload 30 B，wire 约 40 B，在 115200 下约 3.5 ms 发 10 个音，折算 2880 音/秒，比逐音符帧高得多。
- 低延迟场景（单音、快速触键）仍然逐音符小帧发送；批量只用于密集段落。
- 波特率必须实测。用逻辑分析仪发 `0x55` 测位宽，或让 App 连续发已知帧，统计 FPGA 的 `uart_frame_err`。不要假设模块标签就是实际值。

### 3.5 Android App 侧行为

App 不是一个“串口终端”，它必须实现与 FPGA 相同的 SLIP + CRC 编解码。建议：

```kotlin
val uuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
val socket = device.createRfcommSocketToServiceRecord(uuid)
socket.connect()

val input = socket.inputStream
val output = socket.outputStream

// 单写线程：禁止多个线程同时 write，避免帧字节交错
writerThread {
    output.write(frameBytes)   // 一整个 SLIP 帧
    output.flush()
}

// 单读线程：SPP 是字节流，不保证一次 read 等于一帧
readerThread {
    val buf = ByteArray(4096)
    while (true) {
        val n = input.read(buf)
        framer.feed(buf, 0, n) // 流式喂给 SLIP 解码器
    }
}
```

Android 注意点：

- **权限**：Android 12+ 需要 `BLUETOOTH_CONNECT`（连接）和 `BLUETOOTH_SCAN`（发现）；Android 6–11 发现设备还需要位置权限。
- **配对**：首次在系统设置里配对，或在 App 里 `createBond()`；HC-05 PIN 通常是 `1234` 或 `0000`。
- **线程**：`connect()`、`read()`、`write()` 都可能阻塞，不能放主线程。用专用读写线程或 `Dispatchers.IO`。
- **不要用 `available()` 判断一帧**：它只表示当前缓冲有多少字节，SPP 可能把一帧拆成多次 `read`，也可能把多帧合并成一次 `read`。
- **不要用 `BufferedOutputStream` 后不 flush**：会人为增加延迟。每个完整帧写完 `flush()`。
- **重连**：`IOException` 后关闭 socket，指数退避重连；重连成功后先发 `CC123` / `CC120` 清音，再发正常演奏。
- **单连接**：HC-05 只允许一个 SPP 连接；另一个手机连不上是正常现象，不是驱动 bug。
- **延迟**：Android SPP 的调度延迟通常 20–100 ms，不适合做“≤10 ms”指标；赛题的 ≤10 ms 是本机压力垫路径，不是蓝牙路径。见 §11.4。

### 3.6 `STATE` 引脚与断线

HC-05 的 `STATE` 通常在连接成功后为高，断开为低（极性以模块手册为准；若为低有效，在 `link_status` 里反相）。建议接：

- 2 级同步 + 20 ms 去抖；
- **下降沿**：认为蓝牙会话断开，flush 该链路的 L1/分帧器/TX FIFO；L2 按 §7.7 的 `flush_pending` 处理，置 `link_fault[BT]`；
- **上升沿**：清故障，分帧器回 `HUNT`，等待新帧；
- **不要用 `STATE` 门控接收**：有些模块在上报 `STATE` 前后还有缓冲字节；门控会丢帧。`STATE` 只用于“断线清理”，不用于“数据有效”。

如果模块没有引出 `STATE`：

- `HAS_STATE=0`，`link_up` 恒为 1；
- 设备无法可靠知道蓝牙断开；
- App 必须在断开前主动发 `CC123` / `CC120`，并在重连后再次清音；
- 这是有意的取舍，不能假装“空闲超时”等于断线。协议明确说空闲链路不等于断线，也不能用空闲判断长音是否该停。

### 3.7 有线链路的断线

有线链路没有 `STATE`。可用的线索：

- UART break（RX 持续低 > 10 bit）；
- USB 拔出导致的上位机不再发送；
- 主机主动发的 `CC123` / `CC120`。

**不要**用“N 秒没收到字节”来判断断线并清音：长音、慢速控制、暂停都可能是正常的。首版建议：

- 检测到 break → `link_fault[WIRED]`；
- 检测不到拔出时，依赖主机在关闭串口前发 `CC123`/`CC120`；
- 把“有线断线检测”列为开放项，后续可加心跳（例如主机周期发 Active Sensing `FE` 或私有 PING），但不能在 v1 假装已有。

工程注意：

- 板载 BL616 USB-UART 与烧录可能互斥；烧录前关闭 Web Serial 端口，烧录后再打开。
- 有线链路也要实测波特率。历史记录里 BL616 固件出现过“实际波特率是设定值 4 倍”的问题；不要只信配置值。
- Web Serial 的 `baudRate` 必须与 FPGA `BAUD` 参数一致；如果主机用 3 Mbaud、FPGA 按 2.5 Mbaud 收，必然全是 framing error。

---

## 4. 物理层：UART 与数字时钟恢复

### 4.1 基本格式

- 8 数据位，无校验，1 停止位（8N1）；
- LSB first；
- 空闲高电平；
- 起始位低，停止位高；
- 每位宽度 `T_bit = 1 / BAUD`。

HC-05 的 UART 时钟来自模块晶振，FPGA 用本地 `clk_sys` 过采样。两者异步，不能直接拿 `clk_sys` 当波特率时钟。

### 4.2 16× 过采样与 NCO

推荐结构：

```text
clk_sys ──> 相位累加器（NCO）──> tick（16×BAUD）──> 位采样 FSM
                ▲
                │
        起始沿：相位清零
```

NCO 每个 `clk_sys` 累加一个增量：

```text
INC = round(2^W × OVERSAMPLE × BAUD / CLK_HZ)
phase_acc <= phase_acc + INC
tick      = phase_acc 溢出（最高位进位）
```

`W = 24` 时，频率分辨率是 `CLK_HZ / 2^24`，在 100 MHz 下约 5.96 Hz，远小于波特率误差要求。`INC` 四舍五入带来的长期频偏可以忽略。

**为什么用 NCO 而不是整数分频：**

- 115200、230400 等不是 100 MHz 的整数分频；整数分频会有累积相位误差。
- NCO 的平均频率精确到 `1/2^W`，而且 tick 抖动最多一个 `clk_sys` 周期（100 MHz 下 10 ns），对 115200 的 8.68 µs 位宽只有 0.115%。
- 参数化后同一套 RTL 可以跑 9600–1382400。

### 4.3 起始沿相位重置与采样点

UART 是**每字节重新同步**的。推荐：

1. 空闲时等待 `uart_rx` 下降沿；
2. 检测到下降沿，`phase_acc = 0`；
3. 等 0.5 位（8 个 16× tick），采样起始位；若为高，判为假起始，放弃；
4. 再等 1.0 位（16 tick），采样 `bit0`；
5. 每 1.0 位采样下一数据位，共 8 位；
6. 再等 1.0 位，采样停止位；为高则字节有效，为低则 framing error。

也就是从起始沿算起，采样点在第 0.5、1.5、…、8.5、9.5 位。用 16× tick 表示：tick 8、24、40、…、136、152。

**这不是 PLL，而是前馈相位重置。** 它每个字节都把相位拉回起始沿，因此字节内不会累积上一字节的误差。

### 4.4 三样本多数表决与毛刺

可选（推荐默认开）：

- 在每个采样点附近取 3 个连续 tick（例如 7/8/9、23/24/25、…）；
- 三取二作为该位值；
- 起始位也用三取二，降低毛刺误触发。

代价是每 bit 需要 3 个采样寄存器，逻辑很小。对短距离 UART 线，单点采样通常也够；多数表决是免费的噪声余量。

不要做“无限深度数字滤波”：UART 的起始沿就是最好的同步点，过度滤波会引入固定延迟，反而降低采样余量。

### 4.5 关于“PLL 振荡器”的判断

用户初步方案里提到 PLL。这里给出明确建议：

**首版不要做完整 PLL，做 NCO + 每字节起始沿重置即可。**

理由：

- UART 帧只有 10 bit，起始沿每字节都有；前馈重置比反馈环更直接、更稳定。
- 完整 PLL 需要相位检测器、环路滤波器、锁定/失锁状态机；数据跳变不是干净时钟，容易把数据模式当成相位误差。
- HC-05 用晶振，波特率误差通常远小于 1%。16× 过采样的理论容差约 ±5%（见下），不需要跟踪。
- 如果模块实际波特率偏 5% 以上，PLL 也救不了 10 bit 帧的停止位；正确做法是重新配置或换模块。

**理论容差：**

停止位采样点在第 9.5 位。若波特率相对误差为 ε，采样点漂移 `9.5ε` 位。要求小于 0.5 位：

```text
ε < 0.5 / 9.5 ≈ 5.26%
```

三样本多数表决占掉约 1/16 位，实用容差约 4.6%；再留噪声余量，建议工作在 **±3%** 以内。HC-05 晶振误差远小于此。

**如果一定要跟踪**，做一阶 DPLL：

- 相位检测：用停止位/下一个起始沿的相位残差；
- 环路滤波：一阶漏积分，增益很小；
- 调整：每字节只允许 `INC ± 1 LSB`，总修正限幅 ±0.5%；
- 空闲时冻结，不跟踪噪声；
- 提供 `PLL_EN=0` 旁路，默认关闭。

这样既保留了“PLL”这个概念，又不会把首版拖进锁定/失锁、数据相关抖动的坑。**不要把“PLL”当成必须实现的功能点；它解决的是长帧连续时钟恢复，而 UART 每字节都有起始沿。**

### 4.6 错误检测

| 错误 | 检测 | 处理 |
|---|---|---|
| 假起始 | 起始位中点采样为高 | 放弃本次，回空闲，等待下一个下降沿 |
| Framing error | 停止位采样为低 | 丢弃该字节，脉冲 `uart_frame_err`；分帧器丢弃当前半帧 |
| Break | RX 持续低 > 10 位 | 脉冲 `uart_break`；flush 当前帧，置链路故障 |
| 噪声毛刺 | 3 样本多数表决 | 过滤；不单独计数 |
| 过采样溢出 | `tick` 快于 FSM 处理 | 参数错误；用足够高的 `clk_sys` 或降低 `OVERSAMPLE` |

Framing error 意味着字节边界已经不可信。**不要把这个字节继续喂给分帧器**；应通知分帧器“当前帧作废”，然后从下一个 `C0` 重新同步。否则一个坏字节可能被当成 `C0` 或 `DB`，造成更隐蔽的错误。

### 4.7 时钟域与复位

- 所有链路逻辑放在 `clk_sys`（建议 100 MHz；LogicPi 上 50 MHz 也可）。
- `uart_rx` 是异步输入，先做 2 级同步，再进入过采样 FSM。
- 不需要单独的 UART 时钟域；过采样本身完成了异步恢复。
- `rst_n` 异步置位、同步释放。
- 链路 `flush` 与全局复位分开：`flush` 只清该链路的 L1/分帧器/TX FIFO；L2 按 `flush_pending` 延迟清（见 §7.7），不重置共享解析器。

### 4.8 波特率与过采样参数表

下表按 `CLK_HZ = 100 MHz`、`OVERSAMPLE = 16`、`W = 24` 计算。50 MHz 时 `INC` 翻倍，tick 频率不变。

| BAUD | 位宽 | 16× tick 周期 | `INC`（100 MHz） | 100 MHz 下每 tick 时钟数 | 备注 |
|---:|---:|---:|---:|---:|---|
| 9600 | 104.17 µs | 6.51 µs | 25,770 | 651 | 太慢 |
| 115200 | 8.68 µs | 542.5 ns | 309,238 | 54.25 | bring-up |
| 230400 | 4.34 µs | 271.3 ns | 618,475 | 27.13 | 推荐 |
| 460800 | 2.17 µs | 135.6 ns | 1,236,951 | 13.56 | 实测后使用 |
| 921600 | 1.085 µs | 67.8 ns | 2,473,901 | 6.78 | 慎用 |
| 1382400 | 723.4 ns | 45.2 ns | 3,710,852 | 4.52 | 接近上限 |

50 MHz 下，1382400 只剩 2.26 时钟/tick，3 样本多数表决余量很小；如果系统时钟是 50 MHz，建议：

- HC-05 不超过 460800（6.78 时钟/tick），或
- 对 >1 Mbaud 使用 `OVERSAMPLE=8`，或
- 提高链路时钟。

有线链路如果跑 2.5/4 Mbaud：

- 100 MHz + 16×：4 Mbaud 只有 1.56 时钟/tick，**不够**做 3 样本；
- 100 MHz + 8×：4 Mbaud 有 3.125 时钟/tick，可用；
- 50 MHz + 8×：4 Mbaud 只有 1.56 时钟/tick，**不够**；需要 100 MHz 或降低有线波特率。

因此 `OVERSAMPLE` 必须是每链路参数，不能全局写死 16。

---

## 5. 两级缓冲区

### 5.1 为什么需要两级

单看“UART → 分帧器 → 解析器”，似乎一个 FIFO 就够。但双链路 + 共享解析器带来了两种不同性质的停顿：

1. **字节级停顿**：分帧器在 CRC 校验、写 L2、等 L2 空位时会暂停读字节；UART 不会暂停发送。
2. **帧级停顿**：共享解析器在提交配置、事件 FIFO 满、处理另一条链路时会暂停接收新帧；分帧器不能把已经收了一半的帧丢掉。

所以需要：

- **L1 字节 FIFO**：吸收字节级停顿，隔离 UART 与分帧器。
- **L2 完整帧 FIFO**：吸收帧级停顿，隔离分帧器与共享解析器。

分帧器内部还有一个 **40 字节帧装配缓存**，它只负责“CRC 通过前不发布”，不是弹性缓冲。它不跨帧保存，也不参与仲裁。

### 5.2 L1：每链路字节弹性 FIFO

- 写：`uart_rx` 每收到一个有效字节写一次；`full` 时置 `overflow`。
- 读：分帧器按自己的节奏读；`empty` 时停。
- 深度：**1024 B**（建议）。
- 作用：
  - 分帧器做 40 字节 CRC 校验时，UART 可以继续收；
  - L2 满时，分帧器暂停，L1 继续吸收；
  - Android SPP 的突发（一次 `read` 返回多帧）不会直接冲到分帧器。
- 溢出：**硬故障**。L1 满意味着已经丢字节，当前帧不可信；flush 该链路，置 `link_fault`，由适配器清该来源的音。不要“覆盖最旧字节”继续跑。

### 5.3 帧装配缓存

- 40 B（`MAX_PAYLOAD=32` + 6 B header + 2 B CRC）。
- 分帧器边收边写；CRC 和长度全部通过后，才写入 L2。
- 任何长度错、CRC 错、非法转义、超时，都只清这个缓存，**不产生下游副作用**。
- 这是“先验证、后发布”的关键；不能边收边把 payload 交给解析器。

### 5.4 L2：每链路完整帧 FIFO

- 每槽保存：`body[40]`（header + payload + CRC）、`len`（payload 长度）、`type`、`seq`、`src`。
- 仲裁器读槽时从 `body[6]` 开始，只把 payload 流给共享解析器；header/CRC 不再下传。
- 深度：**8 帧**（建议）。
- 写：分帧器在 CHECK 通过后写；写之前必须在帧开始时确认有空槽（见 §6.3 的 `FIRST` 状态）。
- 读：仲裁器按帧读取，流式输出 payload。
- 作用：
  - 共享解析器处理一条链路时，另一条链路可以继续攒完整帧；
  - 配置提交屏障期间，两条链路都可以继续收帧（直到 L2/L1 满）；
  - 故障隔离：一条链路的 L2 满/坏不会直接破坏另一条。
- 为什么每链路一个 L2，而不是一个共享的大 L2：
  - 共享 L2 需要两个写口仲裁，且一条链路可能填满整个 FIFO，破坏公平性；
  - 每链路固定 8 帧，天然公平；
  - 故障时只 flush 该链路，不影响另一条；
  - 仲裁器只需在两个 L2 的读口之间选择，逻辑简单。

### 5.5 背压链

```text
共享解析器 frame_ready=0
        ↓
仲裁器停止取下一字节 / 不取新帧
        ↓
L2 满
        ↓
分帧器在“新帧第一个字节”处停住（不再读 L1）
        ↓
L1 满
        ↓
UART 字节被丢弃 → overflow → link_fault
```

这条链是**有损直到 L1 溢出**：只要 L1/L2 没满，数据不丢；一旦 L1 满，就是硬故障，必须清音并让主机重同步。不能假装“丢一帧没关系”——丢的可能正好是 Note Off。

### 5.6 容量计算

设：

- `L1 = 1024 B`
- `L2 = 8 帧`
- 8N1：每字节 10 bit
- 帧的线上字节数（含首尾 `C0` 和转义）为 `W_frame`

从“下游开始停顿”到“L1 溢出”的时间：

```text
T_absorb ≈ (L2_frames × W_frame + L1) × 10 / BAUD
```

按 115200 / 230400 / 460800 计算：

| 场景 | 每帧线上字节 | L2 填满字节 | + L1 | 总字节 | 115200 | 230400 | 460800 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 典型 Note On（3 B payload） | 13 | 104 | 1024 | 1128 | 97.9 ms | 49.0 ms | 24.5 ms |
| 配置 EQ（10 B payload） | 20 | 160 | 1024 | 1184 | 102.8 ms | 51.4 ms | 25.7 ms |
| 最大 MIDI（32 B payload，无转义） | 42 | 336 | 1024 | 1360 | 118.1 ms | 59.0 ms | 29.5 ms |
| 最大 MIDI（32 B payload，最坏全转义） | 82 | 656 | 1024 | 1680 | 145.8 ms | 72.9 ms | 36.5 ms |

如果停顿开始时 L2 已经满，只剩 L1 的 1024 B：

| BAUD | 仅 L1 吸收 |
|---:|---:|
| 115200 | 88.9 ms |
| 230400 | 44.4 ms |
| 460800 | 22.2 ms |

结论：

- 115200 下约 **89–146 ms** 的停顿余量；230400 下约 **44–73 ms**。
- 配置提交屏障应远小于这个时间（见 §7.5）。如果提交要等所有音符衰减完，可能几秒，那就不是缓冲能救的；必须把 commit 限制在“事件 FIFO 排空 + 寄存器更新”。
- Android SPP 的突发可能超过这个量；App 必须控制发送节奏，不能一次性灌入几 MB。

### 5.7 溢出策略

| 情况 | 策略 |
|---|---|
| L1 满 | 丢弃新字节，`overflow` sticky，flush 该链路，`link_fault` |
| L2 满 | 分帧器在下一帧第一个字节前停住，反压 L1；不丢当前完整帧 |
| 分帧器 CHECK 期间 L1 将满 | 提高 `clk_sys` 或加深 L1；40 字节 CRC 只占几十拍，正常不会 |
| TX FIFO 满 | 反压解析器的 `reply_ready`；不丢 ACK |

**不要**在 L2 满时丢掉最旧的帧来腾位置：会破坏该链路的帧顺序，可能丢 Note Off。

### 5.8 资源估算

每链路（按建议容量）：

| 存储 | 容量 | bit |
|---|---:|---:|
| L1 | 1024 × 8 | 8,192 |
| L2 | 8 × 40 × 8 | 2,560 |
| 帧装配缓存 | 40 × 8 | 320 |
| TX FIFO | 256 × 8 | 2,048 |
| 合计 | | 约 13.1 kbit |

两条链路约 26 kbit，占 Tang Mega 138K 的 6120 kbit BSRAM 不到 **0.5%**。逻辑（UART + 分帧 + 仲裁 + CRC + 计数器）估计每链路 1–1.5k LUT/FF，两条 2–3k，占 138k 的 2% 左右。实际以综合报告为准。

建议用同步读的 `reg [7:0] mem [0:1023]` 推断 BSRAM；不要用 1024 个独立寄存器。L2 可以用扁平数组 `mem[8*40]`，地址 `slot*40+offset`，综合器容易推断 BSRAM。

---

## 6. 分帧器 FSM（每链路一份）

### 6.1 协议回顾

帧格式（SLIP 解码后的 body）：

```text
offset 0: VERSION = 01
offset 1: TYPE    = 01 MIDI / 02 CONFIG（设备接收方向）
offset 2: SEQ     u16 LE
offset 4: LEN     u16 LE，只计 payload
offset 6: PAYLOAD LEN 字节
offset 6+LEN: CRC16 u16 LE，覆盖 VERSION..PAYLOAD
```

线上：

```text
C0 | SLIP_ESCAPE(body) | C0
C0 -> DB DC
DB -> DB DD
```

约束：

- `body_len = LEN + 8`；
- MIDI：`1 <= LEN <= 32`；
- CONFIG：`1 <= LEN <= 16`，且还要匹配具体命令；
- `VERSION=1`；
- 设备接收方向不接受 `TYPE=80`（REPLY 是设备发出的）；
- 长度必须精确，不补齐；
- 只发布 CRC 通过、长度匹配、类型/版本合法的帧。

### 6.2 状态图

```text
HUNT  --C0-->  FIRST
FIRST --C0-->  FIRST                 // 空帧，忽略
FIRST --非C0 且 L2 有空槽-->  BODY
FIRST --L2 满-->  保持（s_ready=0）  // 反压 L1
BODY  --C0-->  CHECK
BODY  --DB-->  ESC
BODY  --超长 / 长度不符-->  DISCARD
ESC   --C0 或 DB-->  BODY            // 解码后追加
ESC   --其他-->  DISCARD             // 非法转义
CHECK --长度/版本/类型/CRC 通过-->  写 L2，回 FIRST
CHECK --任一项失败-->  FIRST          // 丢弃，C0 已是下一帧的边界
DISCARD --C0-->  FIRST
```

### 6.3 状态说明

| 状态 | 行为 | 下一步 |
|---|---|---|
| `HUNT` | 忽略一切，直到 `C0`；清空长度/转义/缓存 | `FIRST` |
| `FIRST` | 等待新帧第一个非 `C0` 字节；若 L2 无空槽则**不消费**（反压） | `BODY` |
| `BODY` | 普通字节追加；`DB` 进 `ESC`；`C0` 进 `CHECK`；超长进 `DISCARD` | `ESC` / `CHECK` / `DISCARD` |
| `ESC` | 下一字节 `C0`/`DB` 解码后追加；其他 → `DISCARD` | `BODY` / `DISCARD` |
| `CHECK` | 校验长度、版本、类型、CRC；通过则写 L2 | `FIRST` |
| `DISCARD` | 丢弃到下一个 `C0`，然后从 `FIRST` 重新开始 | `FIRST` |

**共享 `C0` 的处理：**

- 协议允许 `C0 frame1 C0 frame2 C0`，中间的 `C0` 同时是 frame1 的尾和 frame2 的头。
- 因此 `CHECK` 结束后进入 `FIRST`，而不是 `HUNT`；`FIRST` 看到下一个非 `C0` 字节就开始新帧。
- 连续多个 `C0` 是空帧，`FIRST` 直接忽略。
- 帧前的垃圾字节只在第一个 `C0` 之前被 `HUNT` 忽略；同步后，帧间垃圾会被当成“候选帧”收下，最终 CRC 失败并在 `C0` 处丢弃。由于共享 `C0`，紧接着的合法帧仍能被解析，不会因为垃圾而丢帧。

**为什么 `FIRST` 要检查 L2 空槽：**

- 如果 L2 满，不能在 `BODY` 中途才发现没地方写；那样要么丢当前帧，要么覆盖旧帧。
- 在帧开始时确认“至少一个空槽”，这一帧就预留了位置；即使中途 L2 仍满（不会有其他写者），也能写完。
- 没有空槽时，`s_ready=0`，分帧器不消费 L1；L1 继续吸收；如果 L1 满，就是硬故障。

### 6.4 早期长度/类型检查

不要等收满 40 字节才检查 `LEN`。在 header 6 字节到齐时：

1. 读 `VERSION`、`TYPE`、`LEN`；
2. `VERSION != 1` → `DISCARD`；
3. `TYPE` 不是 1/2 → `DISCARD`；
4. `LEN == 0`、`LEN > 32`、或 `TYPE=CONFIG && LEN > 16` → `DISCARD`；
5. 如果 `body_len > LEN + 8` → `DISCARD`（长度对不上，早停）。

这样即使主机发了一个声称 `LEN=65535` 的坏帧，也不会写爆 40 字节缓存；直接丢弃到下一个 `C0`。

### 6.5 CRC 校验

CRC-16/CCITT-FALSE：

```text
poly   = 0x1021
init   = 0xFFFF
refin  = false
refout = false
xorout = 0x0000
check("123456789") = 0x29B1
```

`CHECK` 状态：

1. 对 `body[0 .. body_len-3]` 计算 CRC；
2. 与 `body[body_len-2]`（低字节）、`body[body_len-1]`（高字节）比较；
3. 相等才发布。

实现建议：

- 字节并行 CRC 更新（8 级 XOR）每拍处理 1 字节，40 字节只要 40 拍；
- 位串行实现需要 320 拍（40×8），在 100 MHz 下 3.2 µs，115200 下也够，但在 1.38 Mbaud 下占到一个字节时间的 44%，余量小；
- 推荐字节并行，逻辑约 100–200 LUT。

CRC 只覆盖解码后的字节；`C0`/`DB` 转义字节不参与。不要对线上转义后的字节算 CRC。

### 6.6 超时

- 参数 `TIMEOUT_MS = 1000`（默认，和协议草案一致）。
- 只在“已经进入非空帧、等待下一字节”时计时：
  - `BODY` / `ESC` 且 `body_len > 0`；
  - `s_valid == 0`（L1 空）；
  - 不在 `CHECK`、`DISCARD`、`FIRST` 的 L2 反压期间计时。
- 每收到一个字节清零。
- 超时：清空当前帧，计数 `timeout`，回 `HUNT`，置 `link_fault`。
- **空闲链路不计时**：没有半帧时，1 小时没字节也不是断线。
- **下游反压不计时**：分帧器在 `FIRST` 等 L2 空槽，不是链路问题；计时会误判。

### 6.7 输出接口

分帧器对 L2 写入完整帧；仲裁器从 L2 读。对共享解析器的最终字节流接口：

```systemverilog
// 帧级元数据（在整个 payload 流期间保持稳定）
logic        frame_valid;   // 至少有一个完整帧可发
logic        frame_ready;   // 解析器可接收当前字节
logic [7:0]  frame_data;    // payload 字节
logic        frame_first;   // payload[0]
logic        frame_last;    // payload[len-1]
logic [5:0]  frame_len;     // 1..32
logic [1:0]  frame_type;    // 1=MIDI, 2=CONFIG
logic [15:0] frame_seq;
logic        frame_src;     // 0=wired, 1=bt
```

约束：

- `frame_valid && frame_ready` 时交付一个字节；
- `frame_first` 与第一个 payload 字节同拍；
- `frame_last` 与最后一个 payload 字节同拍；
- 一帧开始后，`frame_src/type/seq/len` 不变；
- 解析器反压时，`frame_data` 和元数据保持稳定；
- 一帧的最后一个字节被接收后，仲裁器才能换帧；
- `frame_valid` 在帧之间可以拉低，也可以保持（取决于 L2 是否还有帧）；解析器用 `first` 识别新帧。

如果更愿意用“整帧 valid/ready”握手（一次交付 40 字节并行），也可以，但流式接口更省线、更容易接现有 `frame_analyzer` 的 `data/valid/ready/first/last` 约定。本文推荐流式。

### 6.8 伪代码

```text
on reset / flush:
    state = HUNT; body_len = 0; esc = 0; bad = 0

每拍:
  if state == HUNT:
      if s_valid && s_data == C0:
          reset_frame(); state = FIRST
      else:
          consume byte (ignore)

  else if state == FIRST:
      if !s_valid: hold
      else if s_data == C0: consume (empty frame)
      else if !l2_has_free_slot: hold (s_ready = 0)
      else:
          append(s_data); state = BODY

  else if state == BODY:
      if !s_valid:
          if partial_frame && timeout: flush_frame(); fault; state = HUNT
      else if s_data == C0:
          state = CHECK
      else if s_data == DB:
          state = ESC
      else:
          if body_len == MAX_BODY: state = DISCARD
          else:
              append(s_data)
              if body_len == 6: early_check_header()
              if body_len > LEN + 8: state = DISCARD

  else if state == ESC:
      if !s_valid: hold / timeout
      else if s_data == C0: append(C0); state = BODY
      else if s_data == DB: append(DB); state = BODY
      else: state = DISCARD

  else if state == CHECK:
      if validate_length_version_type() && crc_ok():
          write_l2(payload, len, type, seq)
      else:
          count_error()
      state = FIRST   // 共享 C0 允许下一帧直接开始

  else if state == DISCARD:
      if s_valid && s_data == C0:
          state = FIRST
      else:
          consume / ignore
```

注意：`CHECK` 期间 `s_ready=0`，L1 吸收；不要在 `CHECK` 里读新字节。

### 6.9 最低测试向量

复用 [`frame_vectors.json`](../../../analyzer/frame_vectors.json) 的六组：

- `note_on`：`C0 01 01 00 00 03 00 90 3C 64 B3 4E C0`
- `program_change_escape`：payload 里的 `C0` 被转义
- `reverb_hall`
- `eq_band0`
- `reverb_bathroom_header_escape`：header 里的 `C0`/`DB` 被转义
- `config_ack`：只用于 TX 回放，不应被 RX 当作合法主机帧

新增：

| 场景 | 期望 |
|---|---|
| `C0 C0` | 空帧，不发布 |
| `C0 frame1 C0 frame2 C0` | 两帧，共享中间 `C0` |
| 垃圾前缀 + `C0 frame` | 忽略垃圾，发布 frame |
| `C0 ... DB 00 ... C0` | 非法转义，丢弃，计数 |
| `C0 ...` 截断 | 超时后丢弃 |
| `LEN` 大于 32 | 早停，丢弃到 `C0` |
| `LEN+8` 与实际 body 不符 | 丢弃 |
| CRC 错 1 bit | 丢弃，不发布 |
| `VERSION=2` | 丢弃 |
| `TYPE=80`（主机发 REPLY） | 丢弃 |
| 一帧最大 32 B payload | 正常发布 |
| L2 满时再来一帧 | 反压，不丢当前帧 |
| 每条链路同时来帧 | 各自独立，不交错 |

---

## 7. 完整帧仲裁器

### 7.1 目标

- 两条链路各自有 L2；仲裁器一次只服务一帧。
- 保持每链路内部的帧顺序。
- 给共享解析器附带 `src`，让回复和适配器知道来源。
- 不因为一条链路的帧大而长期阻塞另一条。
- 配置提交期间提供全局顺序屏障。

### 7.2 结构

```text
L2_0 --(rd)--> ┌──────────────┐
               │ frame arbiter│ --> frame stream (src/type/seq/len/data/first/last)
L2_1 --(rd)--> └──────────────┘
                      ▲
                      │ frame_ready（来自共享解析器）
```

仲裁器内部：

- 2 选 1 的读端口 MUX；
- 每链路一个 `rd_slot` 指针；
- 1 bit round-robin 指针 `last_src`；
- 当前帧的 `src/type/seq/len/offset` 寄存器；
- 输出寄存器（`frame_data` 在反压时保持）。

### 7.3 FSM

| 状态 | 行为 | 下一步 |
|---|---|---|
| `IDLE` | 看两条 L2 是否有帧；按 RR 选一条 | `SEND` |
| `SEND` | 从选中 L2 读 payload[offset]，驱动 `frame_valid=1`；等 `frame_ready` | 接收一字节后 `offset++` |
| `SEND` | `offset == len` 且最后一字节被接收 | 弹出 L2，更新 RR，`IDLE` |
| `SEND` | 解析器 `frame_ready=0` | 保持当前字节和元数据 |

注意：

- 仲裁器只在 `frame_valid && frame_ready` 时推进 `offset`；
- `frame_data` 必须由寄存器驱动，不能在 `frame_ready=0` 时组合变化；
- 最后一字节握手完成后才能 `pop` L2；
- 如果当前帧来自链路 A，链路 A 的 L2 不能在同一帧内被再次读取；
- `last_src` 在帧完成后翻转，实现严格 RR。

### 7.4 公平性与顺序

- **链路内**：严格 FIFO。L2 是环形/线性队列，先入先出。
- **跨链路**：没有全局到达顺序。仲裁器授予顺序就是执行顺序；主机不能假设“我在 A 发的音符一定先于 B 发的音符”。
- **RR 不会饿死**：两条都有帧时交替；只有一条有帧时，另一条不占用。
- **大帧不会长期占用仲裁器**：仲裁器按字节流服务，最大 32 B payload，100 MHz 下 32 拍；大帧的“慢”在 UART 线上，不在仲裁器里。
- **配置屏障**：见 §7.5。

### 7.5 配置提交屏障

协议要求：

```text
CONFIG 解码/校验 → shadow → 等待此前 MIDI 操作完成 → commit → active → ACK
```

双链路下，必须保证：

- 在 CONFIG 帧之前已经被仲裁器授予的 MIDI 帧，先完成；
- 在 CONFIG commit 完成之前，不能被后续 MIDI 帧越过；
- 后续 MIDI 帧来自哪条链路都一样，因为 EQ/混响是全局的。

实现方式不需要在仲裁器里加复杂状态：

1. 共享解析器接收 CONFIG 帧，把 payload 复制到 shadow；
2. 解析器释放该帧（允许仲裁器弹 L2），但**把 `frame_ready` 拉低**，直到 commit 完成；
3. 仲裁器看到 `frame_ready=0`，不启动下一帧；
4. 两条链路的 L2/L1 继续吸收；
5. commit 完成、ACK 入队后，解析器重新拉高 `frame_ready`；
6. 仲裁器继续 RR。

这样，**所有在 CONFIG 之后到达仲裁器的帧都排在 commit 之后**；在 CONFIG 之前已经被授予的帧已经完成。全局顺序清晰。

注意：

- commit 的等待时间必须有限。只等“此前事件 FIFO 排空 + 消费者完成对应操作 + 寄存器更新”，**不要等所有音符衰减完**；否则 L2/L1 会溢出。
- 如果 commit 预计超过 §5.6 的吸收时间，应该：
  - 加深 L1/L2，或
  - 返回 `BUSY`（协议 result=04），让主机稍后重试，而不是长时间阻塞两条链路。
- 配置帧本身很小（最大 50 B 线上），不会因为传输时间造成长屏障。

### 7.6 回复路由

共享解析器产生 CONFIG ACK：

```text
reply_valid, reply_ready, reply_src, reply_seq, reply_cmd, reply_result
```

- `reply_src` 来自被处理的 CONFIG 帧的 `src`；
- `reply_formatter` 生成 REPLY 帧；
- 按 `reply_src` 写入 TX FIFO 0 或 1；
- 只有原链路能收到 ACK；
- 如果原链路已断开，丢弃回复但**保留配置结果缓存**，等重连后用相同 `{src, seq}` 重放。

不能把 ACK 广播到两条链路：WebGL 会收到不属于它的配置回复，且可能误认为是自己请求的结果。

### 7.7 故障隔离

- 链路 A 的 L1/L2 满、CRC 错、STATE 断开：只 flush A，置 `link_fault[A]`。
- 链路 B 的帧继续被仲裁；共享解析器不受影响。
- 如果 A 正在被仲裁器流式发送，**让当前帧发完**（它已经是完整帧）。此时不能用“立即清 L2”把正在读的 slot 抽掉。实现上给该链路一个 `flush_pending`：停止接收新帧、清 L1 和分帧器，L2 只清“尚未被仲裁器取走”的项；当前 slot 在最后一字节握手完成后随 `pop` 一起释放。
- 不要在半帧中途 abort，否则解析器可能停在 `frame_first` 之后等 `frame_last`。
- `link_fault[A]` 通知适配器：释放 A 拥有的音符、清 A 的 sustain/CC 状态。共享解析器不需要知道故障细节。

### 7.8 接口表（建议）

| 信号 | 位宽 | 方向 | 说明 |
|---|---:|---|---|
| `clk` / `rst_n` | 1 | in | 系统时钟/复位 |
| `l2_valid[1:0]` | 2 | in | 各链路有完整帧 |
| `l2_ready[1:0]` | 2 | out | 仲裁器取走一帧后 pop |
| `l2_data[1:0][7:0]` | 16 | in | 当前 payload 字节 |
| `l2_first/last[1:0]` | 4 | in | 帧边界 |
| `l2_len[1:0][5:0]` | 12 | in | payload 长度 |
| `l2_type[1:0][1:0]` | 4 | in | 1/2 |
| `l2_seq[1:0][15:0]` | 32 | in | 序号 |
| `frame_valid` | 1 | out | 到共享解析器 |
| `frame_ready` | 1 | in | 解析器反压 |
| `frame_data` | 8 | out | payload |
| `frame_first/last` | 2 | out | 边界 |
| `frame_len` | 6 | out | 1..32 |
| `frame_type` | 2 | out | 1/2 |
| `frame_seq` | 16 | out | |
| `frame_src` | 1 | out | 0/1 |

实际实现可以把 `l2_*` 打包成 `struct`，但跨模块端口建议用扁平信号，避免工具兼容性问题。

### 7.9 仲裁延迟

- 最大 payload 32 B，1 B/拍，100 MHz 下 32 拍 = 0.32 µs。
- 若解析器每字节都 ready，一帧的服务时间可忽略。
- 若解析器反压，等待时间由解析器决定；L2/L1 吸收。
- 帧级 RR 的切换开销：1–2 拍。

---

## 8. 与共享解析器／适配层的接口

### 8.1 共享解析器的输入

共享解析器只接收：

- `frame_type`：MIDI 或 CONFIG；
- `frame_seq`：仅诊断/回复；
- `frame_src`：来源；
- `frame_len`：payload 长度；
- `frame_data` + `first/last`：payload 字节流。

它**不接收**外层的 `C0`、转义、CRC、VERSION；这些已经在分帧器校验过。

### 8.2 解析器合同（双链路下必须满足）

1. **每帧开始清局部状态**：running status、pending message、expected data count、SysEx skip 状态全部清空。
2. **帧内允许 running status**：协议 v1 的包内自包含 profile。
3. **帧尾丢弃不完整消息**：不能把半条消息留到下一帧；下一帧可能来自另一条链路。
4. **不做跨帧 running status**：双链路交错时，跨帧状态一定会串。
5. **不按来源过滤字节**：解析器保留 `src` 到事件；是否播放由适配器决定。
6. **反压时保持状态**：`frame_ready=0` 只暂停读字节，不能丢已经拼好的半条消息。
7. **CONFIG 与 MIDI 共用顺序**：解析器一次只处理一帧；CONFIG commit 期间反压后续帧。

第 1、4 条是双链路正确性的核心。单链路时，跨帧 running status 可能“碰巧能跑”；双链路时，A 的 `90` 后接 B 的 `3C 64` 会变成完全错误的音符。**共享 MIDI 解析器必须是“帧级无状态”的；CONFIG 的 shadow/active 是全局状态，但必须按 §7.5 串行提交。**

### 8.3 事件格式与来源侧带

现有 MIDI 事件是 32 bit：

| Bits | 字段 |
|---|---|
| 31:28 | kind（0 Note Off，1 Note On，2 CC，3 Program，4 Bend） |
| 27:24 | channel |
| 23:17 | data1 |
| 16:10 | data2 |
| 9:0 | reserved |

建议**不要把 `src` 塞进 reserved 位**，而是加一条 1 bit 侧带：

```systemverilog
event_data[31:0]
event_src[0:0]     // 0=wired, 1=bt
```

事件 FIFO 宽度变成 33 bit。这样不破坏现有 32-bit 事件合同，也不会让下游把 reserved 位当垃圾清掉。

如果将来链路数 >2，把 `src` 扩成 2 bit；`N_LINKS` 和 `SRC_W` 参数化。

### 8.4 MIDI→fmap 适配器

适配器负责（不属于本驱动，但必须知道来源）：

```text
event(kind, channel, data1, data2, src)
    → 音符/踏板/表情/弯音状态
    → voice 分配
    → fmap_ext / 控制寄存器
    → voice_router
```

它必须处理：

- 32 音清单、16 槽、力度映射；
- 同音重叠、声部抢占；
- sustain 的按下/释放；
- Note Off 的来源归属；
- 断线清音；
- 演奏/指导模式的分流。

**驱动只提供 `src`，不代替适配器做这些决策。**

如果现有的 `midi_analyzer` 已经把“MIDI 字节 → fmap”合在一个模块里，不必为了本文强行拆成两个模块；但 `src` 必须作为侧带一路传到 fmap 写出端，并在同音重叠、断线清音、per-source sustain 时使用。不要因为 fmap 只有 16 个槽就把来源信息丢掉——槽是发声资源，来源是语义归属，两者不是一回事。

### 8.5 双链路音符归属（建议）

如果两条链路都能演奏，必须解决“同一个音被两边按下/松开”的问题。推荐 **2-bit 每音符引用计数**：

```text
note_ref[128] : 2 bit
  bit0 = wired 持有
  bit1 = bt 持有
```

规则：

- `Note On(src)`：置对应 bit；如果之前为 0，分配/触发 voice；如果已经非 0，按重触发策略处理（建议重触发，符合 MIDI 同音重复 Note On 的语义）。
- `Note Off(src)`：清对应 bit；只有 `note_ref == 0` 时才释放 voice。
- 两边都按同一个音：voice 只响一次（或按重触发策略），但只有两边都松开才停。
- `CC123` / `CC120`：只清该 `src` 的 bit；如果另一条链路还持有，声音继续。若产品要求“紧急停止全设备”，则适配器对两条链路都执行清音。
- `link_fault[src]`：清该 `src` 的所有 note bit；仅当 `note_ref==0` 时释放 voice。

这比“全局 last-writer-wins”更符合“两边同时演奏”的直觉，也比“每条链路一套完整 voice 表”省资源。

**Sustain 建议按来源分开**：

- `sustain[2]`；
- 每条链路有自己的“待释放音符”集合；
- A 的踏板不影响 B 的 Note Off。

如果首版不想做 per-source sustain，可以退化为：

- 全局 sustain last-writer-wins；
- 文档明确“两条链路同时踩踏板会互相影响”；
- 或者限制蓝牙链路只做指导/控制，不参与演奏。

这是产品决策，不是驱动能替用户决定的。见 §14。

### 8.6 配置状态

- EQ、混响是**全局**状态；两条链路共享。
- 配置帧的 `src` 只用于 ACK 路由和去重，不用于隔离配置作用域。
- 配置去重键：`{src, seq}`。
  - 同一 `src`、同一 `seq`、同一 payload：重放上次结果，不二次 commit。
  - 同一 `src`、同一 `seq`、不同 payload：`SEQ_CONFLICT`。
  - 不同 `src`、同一 `seq`：视为两个独立请求，互不冲突。
- 配置结果缓存至少保留每个来源最后一条；重连后仍保留，直到全局复位。
- 配置提交串行化：共享解析器一次只处理一个 CONFIG；第二条在 L2 等待。若等待过久，可返回 `BUSY`，但不要静默丢弃。

### 8.7 演奏模式与指导模式

驱动不感知模式。两种模式共用同一套分帧／仲裁／解析；模式只改变事件消费者的行为（是否发声、是否比对、是否点灯），不改变链路层。模式是共享解析器之后的状态，建议：

- 用一条显式的 CONFIG 命令 `MODE_SET`（例如 command `03`，payload `mode:u8`，`0=演奏`、`1=指导`），ACK 后才生效；
- 不要从“链路类型”推断模式（有线不等于演奏，蓝牙不等于指导）；
- 不要用 MIDI channel/program 兼作模式；
- 模式切换时：
  - 先清该来源（或全局）的 note/踏板状态；
  - 再切换；
  - 再 ACK；
  - 避免切换瞬间挂音。

如果“指导模式”需要设备把判定结果回传 App（例如音准、节奏），v1 的 REPLY 只用于配置 ACK，不够用。需要新增一种设备→主机的 TYPE（例如 `EVENT`/`GUIDE`）和相应的流控。**这是协议扩展，不要偷偷塞进现有 REPLY。** 如果指导判定在 App 侧完成，则不需要新 TYPE，驱动也不用改。

### 8.8 断线清音

| 事件 | 驱动动作 | 适配器动作 |
|---|---|---|
| HC-05 `STATE` 下降 | flush BT 链路，`link_fault[BT]` | 清 BT 的 note bit、sustain、pending；必要时释放 voice |
| 有线 break | flush wired 链路，`link_fault[WIRED]` | 清 wired 的 note bit、sustain、pending |
| L1 溢出 | 同上 | 同上 |
| 帧超时 | flush 当前半帧，`link_fault` | 清该来源（保守策略） |
| 对端主动 `CC123`/`CC120` | 正常帧，不置 fault | 按 CC 语义清音 |

**不要**在断线时只清 `fmap=0` 而让 release 继续发声；也不要把共享混响尾音当成“没清干净”。清音策略要和音频后级一起定义。

---

## 9. 发送／回复通路

### 9.1 回复帧

CONFIG ACK 的 REPLY 帧：

```text
VERSION=01
TYPE=80
SEQ=原 CONFIG 的 SEQ
LEN=3
PAYLOAD = request_type(02) | command | result
CRC16
SLIP
```

`result`：

| 值 | 含义 |
|---:|---|
| 00 | OK，已提交 |
| 01 | UNSUPPORTED |
| 02 | BAD_LENGTH |
| 03 | OUT_OF_RANGE |
| 04 | BUSY |
| 05 | SEQ_CONFLICT |
| 06 | NOT_READY |

只有合法 CONFIG 才回复；MIDI 帧不逐帧 ACK，避免额外延迟和重复触发。

### 9.2 发送结构

```text
共享解析器 reply_* 
    → reply formatter（组 body + CRC + SLIP）
    → 按 reply_src 写入 TX FIFO 0/1
    → uart_tx 0/1
```

- `reply_formatter` 可以共享一个，因为解析器一次只产生一条回复。
- 每条链路有自己的 TX FIFO（建议 256 B）和 UART TX；一条链路慢/断不影响另一条。
- TX FIFO 满时，反压 `reply_ready`，解析器保持回复字段；不要丢 ACK。
- 如果 `reply_src` 对应链路已断开：丢弃该回复，计数 `tx_drop`，但保留配置结果缓存；重连后主机重试，设备重放结果。

### 9.3 ACK 时点

- ACK 必须在配置**实际提交**之后发，不是“写入 shadow”或“进入 RX FIFO”。
- 如果 commit 失败，发对应错误码，不修改 active 配置。
- 重复请求只重放结果，不二次 commit。
- 主机建议 1500 ms 超时、最多 3 次重试；重试必须用相同 `{src, seq, payload}`（同一来源、同一请求号、同一内容）。
- 如果链路断开导致 ACK 丢失，主机重连后重试；设备用 `{src, seq}` 命中缓存，重放 OK，不重复修改。

### 9.4 UART TX

- 8N1，LSB first，停止位高。
- 与 RX 同波特率（HC-05 是对称的）。
- `tx_valid/tx_ready` 从 TX FIFO 取字节；移位器空闲时取。
- 发送中不要被 `flush` 打断半个字节？两种选择：
  - 立即 abort：可能在对端产生半个字节的垃圾；对端分帧器会在下一个 `C0` 重新同步，但可能误判。
  - 发完当前字节再停：更干净。建议 `flush` 只清 FIFO，当前移位字节发完；如果 STATE 已断开，发完也无所谓。
- 不要在 TX 路径做 CRC 以外的业务判断；它只负责把 REPLY 帧编码发出去。

---

## 10. 错误处理与可观测性

### 10.1 错误分类

| 错误 | 检测位置 | 是否丢当前帧 | 是否 `link_fault` | 计数 |
|---|---|---|---|---|
| 假起始 | UART RX | 否（还没成帧） | 否 | `uart_false_start` |
| Framing error | UART RX | 是 | 可选 | `uart_frame_err` |
| Break | UART RX | 是 | 是 | `uart_break` |
| 非法 SLIP 转义 | framer | 是 | 否（可恢复） | `slip_err` |
| 超长 / LEN 不匹配 | framer | 是 | 否（可恢复） | `len_err` |
| CRC 错 | framer | 是 | 否（可恢复） | `crc_err` |
| VERSION/TYPE 非法 | framer | 是 | 否 | `type_err` |
| 字节间超时 | framer | 是 | 是（保守） | `timeout` |
| L1 溢出 | L1 | 是 | 是 | `overflow` |
| L2 满 | framer | 否（反压） | 若 L1 溢出则升级 | `l2_stall` |
| STATE 下降 | link status | 是（flush） | 是 | `state_fall` |
| TX FIFO 满 | TX | 否（反压） | 否 | `tx_full` |
| 回复目标断开 | TX | 丢弃回复 | 否（已 fault） | `tx_drop` |

### 10.2 故障处理顺序

1. 检测到硬故障（break、L1 溢出、STATE 下降、超时）；
2. 置 `link_fault[src]` 脉冲 + sticky；
3. flush 该链路的 L1、分帧器、TX FIFO；L2 用 `flush_pending` 处理：停止接收新帧，只清尚未被仲裁器取走的项；
4. 分帧器回 `HUNT`；
5. 适配器清该来源的 note/CC/踏板；
6. 计数器更新；
7. 不影响另一条链路。

如果故障发生在仲裁器正在发送该链路的一帧：

- 让当前帧的剩余 payload 发完（它已经是完整帧）；
- 当前 slot 在最后一字节握手完成后随 `pop` 一起释放，不能提前清掉；
- 不要立即停止并通知解析器“帧中止”：解析器可能已经处理了前半帧，中止会留下半条 MIDI 消息；
- 当前帧发完后，该链路没有剩余帧，仲裁器继续服务另一条链路。

### 10.3 计数器

每链路建议：

```text
rx_bytes
rx_frames_ok
rx_crc_err
rx_slip_err
rx_len_err
rx_type_err
rx_timeout
rx_uart_err
rx_overflow
rx_discard_bytes
tx_frames
tx_drop
```

- 32 bit，饱和计数；
- `overflow`、`crc_err`、`timeout` 至少保留 sticky 位；
- 可以先接到 LED/调试寄存器，不必在 v1 增加协议查询命令；
- 如果 App 需要诊断，v2 再加 QUERY；不要在 v1 偷用 MIDI CC。

### 10.4 不要做的事

- **不要** CRC 失败还发布 payload；
- **不要** 对 CRC 失败的 CONFIG 发 ACK；
- **不要** 用“空闲 N 秒”判断断线并清音；
- **不要** 在 L2 满时覆盖最旧帧；
- **不要** 把两条链路的字节先混合再分帧；
- **不要** 让共享解析器保留跨帧 running status；
- **不要** 把 CONFIG ACK 广播给两条链路；
- **不要** 在驱动里解析 MIDI 或 fmap。

---

## 11. 时序、吞吐与资源

### 11.1 线上帧时间

按 8N1（10 bit/byte）计算。`wire` 含首尾 `C0`；`worst` 假设 body 每个字节都需要转义（2× + 2）。

| 帧 | Payload | Body | Wire（典型） | Wire（最坏） | 115200 典型/最坏 | 230400 典型/最坏 | 460800 典型/最坏 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Note On | 3 | 11 | 13 | 24 | 1.13 / 2.08 ms | 0.56 / 1.04 | 0.28 / 0.52 |
| Program Change | 2 | 10 | 13 | 22 | 1.13 / 1.91 | 0.56 / 0.95 | 0.28 / 0.48 |
| EQ_SET | 10 | 18 | 20 | 38 | 1.74 / 3.30 | 0.87 / 1.65 | 0.43 / 0.82 |
| CONFIG 最大 | 16 | 24 | 26 | 50 | 2.26 / 4.34 | 1.13 / 2.17 | 0.56 / 1.09 |
| MIDI 最大 | 32 | 40 | 42 | 82 | 3.65 / 7.12 | 1.82 / 3.56 | 0.91 / 1.78 |
| REPLY | 3 | 11 | 13 | 24 | 1.13 / 2.08 | 0.56 / 1.04 | 0.28 / 0.52 |

### 11.2 帧率

按典型 wire 字节数：

| 帧 | Wire | 帧/秒 @115200 | 帧/秒 @230400 | 帧/秒 @460800 |
|---|---:|---:|---:|---:|
| Note On（1 音/帧） | 13 | 886 | 1772 | 3544 |
| Program Change | 13 | 886 | 1772 | 3544 |
| EQ_SET | 20 | 576 | 1152 | 2304 |
| 批量 10 音（30 B payload） | 40 | 288 帧 = 2880 音/秒 | 576 帧 = 5760 音/秒 | 1152 帧 = 11520 音/秒 |
| 最大 MIDI（32 B payload） | 42 | 274 | 548 | 1096 |

结论：逐音符帧在 115200 下约 886 音/秒，足够单声部快速乐句；密集和弦/颤音/多轨建议批量。230400 下翻倍，推荐。

### 11.3 共享解析器与仲裁延迟

- 仲裁器服务一帧：最多 32 拍（payload 32 B，1 B/拍），100 MHz 下 0.32 µs。
- 解析器处理一条 MIDI 消息：几个到几十拍；事件 FIFO 反压时另算。
- CRC 校验：字节并行 40 拍 = 0.4 µs；位串行 320 拍 = 3.2 µs。
- 帧级 RR 切换：1–2 拍。

这些相对 UART 字节时间（115200 下 86.8 µs/字节）都可以忽略。**蓝牙路径的瓶颈是 Android SPP 和 HC-05 UART，不是 FPGA 逻辑。**

### 11.4 端到端延迟

粗略分解（Android → 声音）：

```text
App 事件处理 + 组帧                 ~1–5 ms
Android SPP/RFCOMM 调度             ~10–50 ms（可更差）
HC-05 蓝牙接收 + UART 发送          ~1–5 ms
FPGA UART + 分帧 + 仲裁 + 解析      ~0.1–1 ms
MIDI→fmap / voice 分配 / 下一个采样  ~0.02–1 ms
------------------------------------------------
合计                                ~15–60 ms（典型），可到 100 ms+
```

所以：

- 蓝牙路径**不适合**承诺赛题基础项的“≤10 ms 输入→音频”指标；那个指标应走本机压力垫/有线路径。
- 演奏/指导的节奏判定不要在设备端做“采样级”承诺；如果要做，时间戳和判定应放在 App 侧，或新增带时间戳的协议。
- 有线 WebGL 路径可以做到几毫秒（取决于 USB/驱动 latency timer），但也不是硬实时。

### 11.5 资源

按建议容量：

| 资源 | 每链路 | 两链路 |
|---|---:|---:|
| BSRAM | 约 13 kbit | 约 26 kbit（<0.5% of 6120 kbit） |
| LUT/FF | 约 1–1.5k | 约 2–3k（约 2% of 138k） |
| 时钟 | `clk_sys` | 同左 |
| DSP | 0 | 0 |

实际综合后以报告为准。UART/分帧/仲裁都是控制逻辑，不占 DSP；BSRAM 主要用于 FIFO。

### 11.6 时钟与复位

- `clk_sys` 建议 100 MHz（Tang Mega 138K Pro）；LogicPi 50 MHz 时注意 §4.8 的过采样限制。
- `rst_n` 异步置位、同步释放。
- 每条链路有独立 `flush`；全局复位清所有链路和计数器。
- 不要把 UART 逻辑放进音频采样时钟域（例如 12.288 MHz）；在 50 MHz/100 MHz 系统域收完，事件再通过现有握手/CDC 进音频域。

---

## 12. 验证计划

> 本次设计未运行仿真；实现阶段先恢复 `iverilog`/`verilator` 工具链。以下为计划，不是已运行结果。

### 12.1 UART 单元

- 115200/230400/460800 回环；
- 波特率 ±3% 扫描；
- 连续字节、随机间隔；
- 假起始、毛刺、framing error、break；
- 0x00/0xFF/0x55/0xAA 模式；
- 过采样参数 16×/8×；
- 复位/ flush 中途。

### 12.2 分帧器

- 六组 `frame_vectors`；
- 逐字节注入，随机 `valid` 间隔；
- 每个位置放 `C0`/`DB`，验证转义；
- 非法转义、截断、超时；
- LEN 过长/过短/不匹配；
- CRC 单 bit/双 bit 错；
- VERSION/TYPE 非法；
- 共享 `C0`、连续 `C0`、垃圾前缀；
- L2 满反压、L1 溢出；
- 一帧最大 32 B payload。

### 12.3 仲裁器

- 两条链路同时有帧；
- RR 顺序、每链路 FIFO 顺序；
- 一帧中途反压，数据和元数据保持；
- `frame_first/last` 与 payload 对齐；
- `src` 标签正确；
- 一条链路故障不影响另一条；
- 配置屏障：解析器 `ready=0` 时，后续帧不越过；
- 回复按 `src` 路由。

### 12.4 双链路集成

- 有线发 Note On 60，蓝牙发 Note On 64，两者都到解析器；
- 蓝牙发 CONFIG，ACK 只回蓝牙；
- 有线发 MIDI 时蓝牙发 CONFIG，验证屏障顺序；
- 同一音符两边按/松，验证 2-bit 引用计数；
- 蓝牙断开时清蓝牙音符，有线音符继续；
- 一条链路 CRC 错，另一条正常；
- 16-bit `seq` 回绕；
- 同一 `{src, seq}` 重试只重放 ACK，不二次 commit；
- 同一 `seq` 不同 `src` 互不冲突。

### 12.5 Android 主机

- 配对/连接/断开/重连；
- 发送六组向量，读取 REPLY；
- 故意把一帧拆成多次 `write`，验证设备按流处理；
- 故意把多帧合并成一次 `write`，验证设备逐帧解析；
- 1000 帧连续发送，统计 CRC/丢帧；
- 弱信号/远离/遮挡下的重连；
- App 退后台/前台切换；
- 延迟日志（发送时间、ACK 时间）。

### 12.6 板级

- HC-05 AT 配置；
- 逻辑分析仪抓 UART 波形，测实际波特率/位宽；
- `STATE` 上升/下降沿；
- 5V/3.3V 电平、共地、电源纹波；
- 连续演奏 24 h，统计溢出/CRC/断线；
- 与音频输出一起测端到端延迟；
- EMI/天线位置。

### 12.7 通过判据

- 所有合法向量 0 错误；
- 所有非法向量被丢弃且不产生下游副作用；
- 两条链路帧不交错；
- 配置 ACK 只在提交后发出，且只回原链路；
- 断线后 100 ms 内该来源无挂音；
- L1 溢出/坏帧不会让另一条链路停摆；
- 连续 1 万帧无 CRC 误接受；
- 实际波特率误差在 ±3% 内仍能工作。

---

## 13. 实施阶段

| 阶段 | 工作 | 退出条件 |
|---|---|---|
| 0 | 冻结协议与双链路语义 | §14 的 1–7 有结论 |
| 1 | `uart_rx` / `uart_tx` + TB | 115200/230400 回环，±3% 波特率扫描通过 |
| 2 | `slip_frame_rx` + TB | 六组向量 + 错误注入全部通过 |
| 3 | L1/L2 + `frame_arbiter` + TB | 双链路 RR、source tag、故障隔离通过 |
| 4 | `reply_formatter` + TX 路由 + TB | ACK 只回原链路；配置屏障正确 |
| 5 | 接共享 `midi_analyzer` / `config_analyzer` | 双链路帧不交错；每帧状态复位 |
| 6 | MIDI→fmap 适配 + 音符归属 | 同音重叠/断线清音通过 |
| 7 | Android App + HC-05 bring-up | SPP 连接、重连、1k 帧、延迟日志 |
| 8 | 板级集成 | 引脚/电平/STATE/24h soak/LA 波形 |

建议文件划分（尚未创建）：

```text
rtl/drivers/link/
  link_pkg.sv              # 参数、source ID、frame metadata 类型
  uart_rx.sv               # 过采样 + NCO + 可选多数表决
  uart_tx.sv
  byte_fifo.sv             # L1
  frame_fifo.sv            # L2
  crc16_ccitt.sv
  slip_frame_rx.sv         # 分帧 FSM
  slip_frame_tx.sv         # REPLY 编码
  frame_arbiter.sv
  link_status.sv           # STATE 去抖、故障聚合、计数器
  link_top.sv              # 单链路封装
rtl/drivers/bluetooth_hc05/
  README.md                # 本文
  hc05_link_top.sv         # BT 参数 + STATE
  hc05_state_sync.sv
rtl/drivers/wired_serial/
  wired_link_top.sv
rtl/drivers/dual_link_top.sv
sim/unit/link/
  tb_uart_rx.sv
  tb_slip_frame_rx.sv
  tb_frame_arbiter.sv
  tb_dual_link_top.sv
  tb_hc05_state.sv
```

依赖关系：

```text
link_pkg
  ├─ uart_rx / uart_tx
  ├─ byte_fifo
  ├─ crc16_ccitt
  ├─ slip_frame_rx
  ├─ frame_fifo
  ├─ slip_frame_tx
  └─ link_status
        ↓
     link_top
        ↓
  hc05_link_top / wired_link_top
        ↓
     dual_link_top
        ↓
  shared parser (separate)
```

### 13.1 建议参数

| 参数 | 建议默认 | 说明 |
|---|---:|---|
| `CLK_HZ` | 100_000_000 | 系统时钟；50 MHz 时注意过采样 |
| `BAUD` | 230_400 | 每链路独立 |
| `OVERSAMPLE` | 16 | HC-05；有线 >2 Mbaud 时改 8 |
| `NCO_W` | 24 | 相位累加器位宽 |
| `MAJORITY` | 1 | 3 样本多数表决 |
| `PLL_EN` | 0 | 可选一阶跟踪，默认旁路 |
| `L1_DEPTH` | 1024 | 字节 FIFO |
| `L2_DEPTH` | 8 | 完整帧 FIFO |
| `TX_DEPTH` | 256 | 回复 FIFO |
| `MAX_PAYLOAD` | 32 | MIDI 上限；CONFIG 另限 16 |
| `TIMEOUT_MS` | 1000 | 半帧字节间超时 |
| `HAS_STATE` | BT=1，wired=0 | 是否使用 HC-05 `STATE` |
| `SRC_W` | 1 | 两条链路 |

---

## 14. 开放决策

| # | 决策 | 建议 | 不决定的后果 |
|---:|---|---|---|
| 1 | HC-05 波特率 | **230400 8N1**；bring-up 115200 | 9600 吞吐不够；460800 可能不稳定 |
| 2 | 时钟恢复 | **16× NCO + 起始沿重置**；PLL 默认关 | 做完整 PLL 增加锁定/失锁风险，收益很小 |
| 3 | L1/L2 容量 | **L1=1024 B，L2=8 帧，TX=256 B** | 容量不足会在 Android 突发时溢出 |
| 4 | 仲裁策略 | **帧级 round-robin + src tag** | 优先级/饿死/顺序不确定 |
| 5 | 配置权限 | **两条链路都可配置，串行化，`{src,seq}` 去重** | 两路同时改 EQ/混响会互相覆盖；ACK 可能串链 |
| 6 | 音符/踏板归属 | **2-bit 每音符引用计数 + 每来源 sustain** | 同音重叠会挂音或互相切掉 |
| 7 | 模式选择 | **显式 `MODE_SET` CONFIG 命令 + ACK** | 从链路猜模式会导致行为不可预测 |
| 8 | 指导模式反馈 | **v1 App 侧判定**；设备侧判定需新增 TYPE | 偷用 REPLY 会破坏协议 |
| 9 | `STATE` 引脚 | **接线**；没有则 `HAS_STATE=0` | 蓝牙断线无法可靠清音 |
| 10 | 有线高波特率 | >2 Mbaud 用 **8× 过采样** 或 100 MHz+ | 16× 在 4 Mbaud/100 MHz 下只有 1.56 时钟/tick |
| 11 | 有线断线 | **break + 主机主动 CC123/CC120**；不靠空闲超时 | USB 拔出可能挂音 |
| 12 | 配置超时/重试 | **1500 ms，最多 3 次，相同 `{src,seq,payload}`** | ACK 丢失后主机不知道是否生效 |

其中 1、2、3、5、6、7 最好在写 RTL 前定下来；8、9、10 可以在集成阶段再定，但会影响板级接线和协议版本。

如果排期紧，首版可以收缩为：**两条链路都接收；配置只允许有线链路写，蓝牙只发 MIDI（若需要蓝牙选模式，只给 `MODE_SET` 开一条白名单）；音符归属用 2-bit 引用计数；指导模式先做 App 侧。** 这样能先打通“双链路并行 + 共享解析器”的主干，把 per-source CC、双路配置权限、设备侧指导反馈推迟到 v1.1；代价是 Android App 首版不能改 EQ/混响，模式只能走白名单或本地按键。

---

## 15. 参考

- [RFC 1055 — SLIP](https://www.rfc-editor.org/rfc/rfc1055)
- [CRC RevEng — CRC-16/IBM-3740 (CCITT-FALSE)](https://reveng.sourceforge.io/crc-catalogue/16.htm#crc.cat.crc-16-ibm-3740)
- [MIDI Association — Summary of MIDI 1.0 Messages](https://midi.org/summary-of-midi-1-0-messages)
- [Android Bluetooth 概览](https://developer.android.com/develop/connectivity/bluetooth) 与 [BluetoothSocket API](https://developer.android.com/reference/android/bluetooth/BluetoothSocket)
- 本仓库：[协议 v1](../../../analyzer/PROTOCOL_V1.md)、[MIDI 解析合同](../../../analyzer/README.md#midi)、[帧向量](../../../analyzer/frame_vectors.json)、[MIDI/UART 协议草案](../../../../../docs/MIDI接入.md)、[上位机可行性分析](../../../../../docs/上位机.md)
- HC-05 的 AT 指令集/引脚定义以具体模块厂商手册为准；不同固件/克隆模块存在差异。本文不复制厂商手册，只给出集成约束。

---

## 附：一页纸决策清单

如果只记住十件事：

1. HC-05 是透明 UART，不是 BLE，不是协议解析器。
2. 两条链路各自 `UART → L1 → framer → L2`，绝不先混字节。
3. 仲裁在完整帧粒度，RR + `src`。
4. 共享解析器每帧清状态，不能跨帧 running status。
5. 推荐 230400 8N1。
6. 16× NCO + 起始沿重置；PLL 默认关。
7. L1=1024 B，L2=8 帧，TX=256 B。
8. CONFIG ACK 按 `src` 回，去重键 `{src,seq}`。
9. 断线必须清该来源的音，不能靠空闲超时。
10. 演奏/指导模式是解析器之后的事，驱动不猜。
