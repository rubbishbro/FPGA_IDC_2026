# 通信历史文档合集 — 2026-10-26

本文合并原有的入口、架构、协议、资料调研和早期验证快照，供追溯。各节保留当时表述；“无 RTL”“待实现”等状态以及旧时序数字不代表当前版本。当前实现见 [通信说明](../../../../comm/README.md)，当前协议见 [协议 v1](../../PROTOCOL_V1.md)。

## 阅读目录

- [整理前入口快照](#snapshot)
- [早期双链路架构](#architecture)
- [早期协议草案](#protocol)
- [MIDI 资料与实现参考](#references)
- [驱动分层前验证记录](#old-timing)


<a id="snapshot"></a>

## 整理前入口快照

日期：2026-10-26。**已实现独立通信 RTL、模块自检和双 UART 集成测试；未接真实音频／EQ 后级，未做板级验收。** 不修改现有 fmap、router 或颤音代码。实现范围、运行方法和时序证据见 [IMPLEMENTATION.md](../../../../comm/README.md)。

### 文档入口

| 文件 | 内容 |
|---|---|
| [IMPLEMENTATION.md](../../../../comm/README.md) | 实际 RTL、接口／维护语义、回归命令、已验证范围与限制 |
| [VERIFICATION.md](../../../../comm/VERIFICATION.md) | 2026-10-26 最终11项仿真、8种子故障压力回归、Gowin PnR数字及余量边界 |
| [MODULE_INTERFACES.md](../../README.md) | 分块实现接口合同；实际公开端点以 comm_top.sv 为准 |
| [COMM_ARCHITECTURE.md](HISTORY.md#architecture) | 双物理链路、共享解析、来源侧带与配置屏障架构 |
| [PROTOCOL_V1.md](HISTORY.md#protocol) | 本次明确的 v1 外层帧头、SLIP、CRC16、消息类型、配置布局、回复与错误规则 |
| [MIDI_REFERENCE.md](HISTORY.md#references) | 标准 MIDI 资料、开源解析器评审、首版解析合同、事件格式、测试清单 |
| [frame_vectors.json](../../frame_vectors.json) | 六组外层帧的 payload、CRC、转义前后字节，供未来 RTL／主机对拍 |

`PROTOCOL_V1.md` 是本次提交供审阅的字节级设计基线，不代表已实现。EQ 段数、声音映射、通道播放能力等未决项单列，不阻塞先设计分帧和 MIDI 字节解析。

### 架构边界

```text
电脑 UART / HC-05 的完整接收字节
                 │
              RX FIFO
                 │
       frame_analyzer（拟定模块名）
       SLIP 解码、长度、CRC、短帧缓存
       只发布完整验证通过的帧
                 │
            demux / 顺序调度
            ┌────┴─────────────┐
       MIDI_DATA             CONFIG
            │                  │
     midi_analyzer       config_analyzer
            │                  │
       event FIFO       shadow 配置寄存器
            │                  │
    MIDI→fmap / 控制      安全边界 commit
            │                  │
    音符／音高／表情        active EQ／混响寄存器
                               │
                        配置完成／错误回复
```

用户确定的“一个输入 FIFO + demux + 两个解析 FSM，MIDI event 用 FIFO、config 用寄存器”保留。frame_analyzer 的小帧缓存用于 CRC 通过前不产生副作用，不是额外的命令执行 FIFO。demux 可合并在分帧／调度模块中。

#### 拟定模块职责

- `frame_analyzer`：只负责外层协议，不解释音符、EQ 算法或音色。
- `midi_analyzer`：按标准 MIDI 字节规则重组短消息，筛选用户确定的子集，输出事件；不分 voice、不直接写 fmap。
- `config_analyzer`：检查私有配置的命令号、长度和取值，写 shadow 寄存器并申请 commit；不能接收一半就改 active 参数。
- MIDI→fmap／控制适配器：独立后续模块。处理 32 音符、16 槽、力度、踏板、音色和调制路由，不属于本目录当前实现范围。
- HC-05／UART 收发：与本分析层解耦。不得在 MIDI FSM 中实现波特率采样、AT 命令或手机蓝牙栈。

### 接口设计原则

先约定字节／事件 `valid && ready` 为单次交付；输出被反压时数据保持稳定。`ready=0` 只能暂停内部读 FIFO，不能让 UART 发送方自动停下来，实际 FIFO 溢出仍需报告与恢复。

帧发布时提供 `type / seq / payload_len`，payload 提供 `data / valid / ready / first / last`。输入解码、整帧验证与下游发布可用不同状态，不能边收 UART 边把尚未验 CRC 的消息交给两个 FSM。

MIDI 输出暂定 32-bit 事件，见 MIDI_REFERENCE；配置是寄存器接口，不强行装成 MIDI 事件。

配置保序：在配置帧之前的 MIDI payload 已解析完、事件 FIFO 已排空且消费者确认没有尚未完成的事件操作后，再提交配置；不等待已发声的所有音符结束。配置实际完成后才 ACK，并继续后续帧。

### 本次已核对

- 在线查阅 MIDI Association 消息表、Arduino MIDI Library、Mido tokenizer，以及 Tang Nano 的 Verilog MIDI decoder。
- 按位 CRC 算法与 Python 标准库 `binascii.crc_hqx(data, 0xFFFF)` 交叉检查。
- `123456789 → 0x29B1`；六个 frame_vectors 的 CRC 一致，SLIP 编解码往返一致。

上述六组样例计算是最初协议设计的证据；后续 RTL 仿真／时序结果另见 IMPLEMENTATION。未引入第三方源码依赖，也不把通信探针当作整机／板级验收。

### 仍待确认，但不影响分帧／MIDI FSM 起步

- 首版实际接收哪些 MIDI 通道，以及单／多音色播放策略；事件接口保留全部 16 个 channel。
- Program Change 到本机 instrument 的映射、每件乐器具体 32 音清单。
- 弯音范围、CC1 深度、音量曲线；CC11 保留为用户指定的线性表情控制。
- EQ 实际段数、系数生成与稳定性校验；本次只给高层配置字段，不上传任意 IIR 系数。
- 断线／UART 错误／FIFO 溢出的清音动作、上游流控与 FIFO 深度；需与驱动／router 联调。
- 混响首版仅选择三个预设，不虚构当前没有的独立 amount 输入口。

当前 [HC-05 双链路驱动设计](../../../bluetooth_hc05/README.md) 在设计上按同一字节接口接入：两套 `frame_analyzer` 实例分别接 L1，仲裁后共享本目录的 MIDI/Config 解析器；目前仍无 RTL，本目录不替代 HC-05 驱动。


<a id="architecture"></a>

## 早期双链路架构

日期：2026-10-26。本文原为架构基线，随后用户批准按此实现，并明确去重缓存遵循 PROTOCOL。**线上协议不变；实际实现、回归和时序证据见 [IMPLEMENTATION.md](../../../../comm/README.md)。** 下文保留设计分层与待集成边界，不将通信 RTL 等同于整机或板级交付。

本系统是“两条物理链路 × 两类业务消息”：USB-UART、HC-05 UART 各自接收 MIDI_DATA／CONFIG；不是给 MIDI 和 Config 各分配一条 UART。

### 0. 阅读依据与当前实现边界

已核对：

- [项目 README](../../../../../README.md)：当前主合成路径是 `rtl/router/`；旧 core 的历史回归不能替代当前验收。
- [analyzer README](HISTORY.md#snapshot)、[PROTOCOL_V1](HISTORY.md#protocol)、[MIDI_REFERENCE](HISTORY.md#references)、[帧测试向量](../../frame_vectors.json)。
- [HC-05 双链路设计](../../../bluetooth_hc05/README.md)：目前为设计文档，没有 UART／HC-05／仲裁 RTL。
- [`pad_voice_top.sv`](../../../../router/pad_voice_top.sv)：已有 `fmap_ext`、`src_sel`、`inst`、`reverb_preset` 等端口。
- [`voice_router.sv`](../../../../router/voice_router.sv)：接收 16×8-bit fmap，生成门控／激励／包络，装载期间会冻结输入。
- [`router_pkg.sv`](../../../../router/pkg/router_pkg.sv)、[`pad_driver_pkg.sv`](../../../pkg/pad_driver_pkg.sv)：音色／混响枚举与 fmap 类型。

“共享现有解析层”指复用已经定义的 MIDI／Config **协议合同**；当前 analyzer 目录仍只有设计文档和向量，不能写成已有可集成的解析器 RTL。WebGL 是界面渲染方式，浏览器串口接入由 Web Serial 完成。

### 1. 差异与冲突清单：先列出，不改原协议

#### 1.1 长度核对

`PROTOCOL_V1.md §2.1` 已收紧 Config，本轮不需要修改它。必须区分四种长度：

| 类型 | Payload | 解码 body：6-byte header + payload + 2-byte CRC | 无转义时 wire：body + 两个 C0 | 最坏 wire 安全上界：2×body+2 |
|---|---:|---:|---:|---:|
| MIDI_DATA | 1..32 | 9..40 | 11..42 | ≤82 |
| CONFIG | 1..16 | 9..24 | 11..26 | ≤50 |
| REVERB_SET | 2 | 10 | 12 | ≤22 |
| EQ_SET | 10 | 18 | 20 | ≤38 |
| REPLY | 3 | 11 | 13 | ≤24 |

最坏转义长度是保守容量上界，固定 header 不一定允许所有字节同时需要转义。**32／16 是 payload 上限，不是完整帧长，也不是固定填充长度。**

历史讨论中的 `CONFIG=128`、`MAX_PAYLOAD=128`、`body=136`、`wire=274` 已过时；本次读取的现行 PROTOCOL 和 HC-05 文档均已是 32／16、body≤40。不得误把 JSON 中 REPLY 的十进制 `type:128` 当成长度遗留。

#### 1.2 其他差异与处理原则

| 项目 | 现有文档／RTL 差异 | 本架构采用的原则；本轮不改原文 |
|---|---|---|
| RX 拓扑 | analyzer README 主图仍是单路 RX FIFO；末尾及 HC-05 文档已讨论双路 | 每路独立 UART、L1、SLIP／CRC、帧存储；完整帧后再共享 |
| SLIP ESC | HC-05 README §6.2／6.3／6.8 把 ESC 后的线上输入写为 C0／DB；与其自身 §6.1 和 PROTOCOL 冲突 | 严格按协议：`DB DC → C0`、`DB DD → DB`；`DB C0` 不是合法数据转义，应使候选帧失效并在分隔符重新同步 |
| 超时／UART 错误 | HC-05 §10.1 将 framing error 是否置 fault 写成可选；PROTOCOL §4 要求通知 link_fault | 按 PROTOCOL：坏字节不入业务流，半帧作废，报告对应来源；具体清音仍由恢复／适配层完成 |
| 去重缓存重连 | PROTOCOL §7.1 要求会话重建清缓存；HC-05 §7.6／8.6／9.3 设想断线后跨重连保留 | **用户已确认遵循 PROTOCOL。** 每来源会话重建清重试缓存；不承诺跨重连的 exactly-once。旧 HC-05 草案的相反建议不采用 |
| 消息类型位宽 | 线上 TYPE 是 u8；HC-05 RX 流示例用 2 bit，仅覆盖 01/02 | 内部通用 frame_type 保留 8 bit，不能把 80 截断成 0；设备 RX 的业务入口只分发 01/02，REPLY 不产生应答循环 |
| `l2_ready` | HC-05 §7.8 同时把它写成字节 ready 和帧 pop | 分开定义字节 `valid/ready` 与内部 `frame_pop`；只在末字节握手时释放队首 |
| MODE_SET／指导反馈 | HC-05 §8.7 给出新增命令／TYPE 的建议；v1 只保留 EQ、混响 CONFIG | 不采用为 v1 现成功能，不新增 MODE_SET、QUERY、GUIDE 或心跳命令 |
| 缓冲复制 | HC-05 草案为独立 40-byte staging 再复制到完整帧 FIFO | 建议使用同一槽存储的 reserve/write/commit；验证前槽不可见，验证后仅发布描述符，不复制 payload。不是改变线格式 |
| 32-bit Event | MIDI_REFERENCE 不含来源；双链路需要来源归属 | 保持 32 bit 原样，以独立 `source_id` 侧带入 FIFO；物理 FIFO 可为 33 bit，不占 reserved 位 |
| 混响枚举 | wire：NONE=0/HALL=1/BATHROOM=2；RTL：BATHROOM=0/HALL=1/NONE=2 | 配置后级显式映射，不直接强转枚举 |
| 音频端点 | 现有 router 没有通用 EQ、commit ACK、独立 MIDI 控制接口 | 设计适配端点或返回 NOT_READY；不假装通信文档已补齐 DSP |

文档冲突不通过静默改协议解决。长度已一致；其他差异应由对应模块负责人评审，本轮仅新增本文。

### 2. 保持不变的协议与业务语义

```text
wire = C0 + SLIP(VER:u8 TYPE:u8 SEQ:u16 LEN:u16 PAYLOAD CRC16:u16) + C0
```

- VER=1；TYPE=01 MIDI_DATA、02 CONFIG、80 REPLY；多字节整数小端。
- CRC-16/CCITT-FALSE：poly=1021、init=FFFF、refin/refout=false、xorout=0000；覆盖未转义 header+payload；`123456789 → 29B1`。
- source_id **不是线上新增字段**，由物理输入端口决定。
- MIDI 每帧独立；running status、pending、SysEx skip 不跨帧；实时字节不能破坏当前消息；零力度 Note On 转 Note Off。
- MIDI 不逐帧 ACK、不自动重发；Config 用绝对设置、shadow→commit→最终回复，重复请求不二次执行。
- 两个来源各自有 MIDI／Config SEQ 命名空间。相同 SEQ 不代表不同来源是同一请求。
- Config EQ／混响仍是全局后级状态，不因携带 source_id 自动变成每来源效果器。跨来源冲突以仲裁后的提交顺序为准，后提交生效；ACK 是某请求的历史执行结果，不是当前状态查询。
- CC123 是松键，CC120 是 All Sound Off；不能合并。CC7 与 CC11 独立，CC11 经用户指定的线性表情控制路径，不改变 MIDI 的标准含义。

### 3. 顶层层次与数据流

#### 3.1 建议模块层次（全部为待实现名称）

```text
comm_top
├─ comm_link_rx[0]                         // WIRED，同一模块实例 0
│  ├─ uart_rx                             // 8N1，RXD 同步、位采样
│  ├─ rx_byte_fifo                        // 每链路 L1
│  └─ slip_frame_rx                       // 一个接收控制 FSM
│     ├─ SLIP/header/length 控制           // 逻辑阶段，不强拆成多 FSM
│     ├─ crc16_update                     // 函数或小数据通路，无独立握手 FSM
│     └─ verified_frame_store             // 每链路 L2，含未提交写槽
├─ comm_link_rx[1]                         // BT，同一模块实例 1
│  └─ 与上面同样的独立状态／FIFO／缓存
├─ hc05_status                            // 可选 STATE 同步／去抖／状态事件
├─ frame_arbiter                          // RR，完整帧锁定，来源标记
├─ parser_dispatch                        // 类型分流、帧上下文与顺序屏障
│  ├─ midi_analyzer                       // 共享一份
│  └─ config_analyzer                     // 共享一份，含 shadow、每源重试缓存
├─ midi_event_fifo                        // event[31:0] + source_id
├─ config_commit_bridge                   // 对外 commit／完成接口，不计算 EQ
├─ tx_router                             // 回复描述符按来源分流
├─ comm_link_tx[0]
│  ├─ reply_fifo                          // 很小的完整回复描述符队列
│  ├─ slip_frame_tx                       // header、CRC、SLIP 编码
│  └─ uart_tx
├─ comm_link_tx[1]                         // 与实例 0 同一 RTL、独立进度
└─ recovery_ctrl / counters               // 来源级故障汇总与恢复握手
```

模块层次表达职责，不要求每个框都有一个复杂 FSM。FIFO 用计数器／指针，CRC 用更新函数；薄 wrapper 不重复数据缓冲。RX 两路绝不能复用一个 UART 移位器或一个 SLIP 状态寄存器。

#### 3.2 RX

```text
WebGL UI ─ Web Serial ─ USB-UART 桥 ─ UART_RX[0] ─ L1[0] ─ SLIP/CRC[0] ─ 完整帧 L2[0] ─┐
                                                                                      ├─ Frame Arbiter
Android ─ RFCOMM/SPP ─ HC-05       ─ UART_RX[1] ─ L1[1] ─ SLIP/CRC[1] ─ 完整帧 L2[1] ─┘
                                                                                             │
                                                                                已验证的 payload+来源
                                                                                             │
                                                                                     Parser Dispatch
                                                                                       ┌─────┴─────┐
                                                                                  MIDI FSM      Config FSM
                                                                                       │             │
                                                                                  Event FIFO     shadow registers
                                                                                       │             │ commit
                                                                               MIDI→fmap/控制    EQ／混响端点
```

#### 3.3 TX

```text
Config 最终结果 {source_id, seq, command, result}
                      │
                  TX Router
                 ┌────┴─────┐
             Reply FIFO 0  Reply FIFO 1
                 │              │
          SLIP Encoder 0   SLIP Encoder 1      // 各自组 REPLY、算 CRC、转义
                 │              │
             UART TX 0      UART TX 1
                 │              │
              USB-UART         HC-05 → Android
```

不广播回复；编码后的两个 UART 字节流不再互相仲裁。推荐把 TX Router 放在小回复描述符层，避免共享 encoder 正在为慢链路输出半帧时阻塞另一链路。每路 encoder 可直接受 UART TX 反压，无需默认再复制完整帧或加 256-byte TX FIFO。

### 4. 职责与禁止越界

| 模块 | 负责 | 不负责 |
|---|---|---|
| UART RX/TX | 电平同步／位时序、8N1、字节恢复／发送 | SLIP、MIDI、Config、来源业务 |
| HC-05 状态管理 | 可选 STATE 输入同步、去抖、链路事件 | 蓝牙栈、SPP 包解析、MIDI；首版不必做 AT FSM |
| L1 | UART 完整字节弹性缓冲 | 猜帧头、覆盖旧数据、选择音色 |
| SLIP Frame RX | 转义、定界、header／长度／CRC；仅发布已验证帧 | 音符、EQ 参数合法性、DSP、回复成功码 |
| L2／帧槽 | 完整消息发布、每源 FIFO 顺序、读出 payload | 业务解析、跨来源仲裁 |
| Frame Arbiter | 选择一个来源、锁住一帧、来源标记 | 重新 SLIP／CRC、修改 payload、声部优先级 |
| Dispatch | TYPE 分流、上下文保留、Config 全局屏障 | MIDI 语法、EQ 系数计算 |
| MIDI Parser | MIDI 短消息与标准边界、支持子集→32-bit Event | UART、帧 CRC、fmap、voice、MIDI 文件定时 |
| Config Parser | 命令／字段校验、shadow、去重／结果缓存 | 未校验时修改 active、直接 ACK 收到半帧 |
| Commit Bridge／后级 | 安全边界原子更新并确认结果 | 改变协议编号、失败后部分更新 |
| TX Router／Encoder | 按来源发既定 REPLY、CRC／SLIP | 广播 ACK、重复业务执行 |
| MIDI 适配器 | 来源／通道／音符状态、力度、踏板、fmap／控制 | 把来源信息丢掉、重新解析 UART |

HC-05 已实现 Bluetooth Classic SPP。FPGA 的 HC-05 路径只是另一条 UART；配对、RFCOMM 和蓝牙射频不在 FPGA 中实现。有线和蓝牙使用**同一份参数化 UART RTL 的两个实例**，可有不同 BAUD／OVERSAMPLE。

### 5. SystemVerilog 接口合同

以下是**文档级拟定端口**，不是改动已有模块。统一使用扁平端口，必要时在内部用 packed struct。两源固定：`source_id=0` 有线，`source_id=1` HC-05；源号由端口绑定，主机不可在 payload 中伪造。

#### 5.1 时钟、复位、握手

- 默认共用 `clk`（平台建议 100 MHz，可参数化）、低有效 `rst_n`。复位异步置位、同步释放；各协议状态只在系统时钟域运行。
- UART 过采样／波特率 tick 使用 clock enable，不另造慢时钟。RXD 与 STATE 是异步引脚，各自同步；若未来换时钟域，必须增加 CDC／异步 FIFO，不能把当前同步 FIFO直接跨域使用。
- 可背压流在 `valid && ready` 上升沿交付一次；`valid && !ready` 时，data、first、last 和 metadata 全部稳定，valid 不撤回。状态、偏移、CRC、指针只随对应交付推进。
- `first/last` 附着在 payload 字节上，不是独立单拍脉冲。LEN=1 时二者同时为 1。不得因 ready=0 丢掉帧首清状态或帧尾处理。
- reset 清 valid、FIFO／槽指针、未提交 shadow、重试缓存和上下文；配置 active 的复位默认由后级定义。错误计数不靠新增串口命令读取。

#### 5.2 UART 与 L1

| 端口组 | 方向／位宽 | 合同 |
|---|---|---|
| UART RX 引脚 | `rx_i` in 1 | 仅 uart_rx 同步／采样 |
| UART RX 字节 | `rx_stb` out 1，`rx_data` out 8 | 一字节完成给一个 clk 脉冲；物理接收不可被下游 ready 暂停，这是唯一不承诺可反压的产生端 |
| UART RX 错误 | `framing_err`、`break_detect`、`false_start` out 1 | 不把无效字节作为合法 rx_stb；framing/break 交恢复层，false start 计诊断 |
| L1 写入 | `wr_stb` in 1，`wr_data` in 8；`full` out 1 | `rx_stb && full` 置 overflow；禁止覆盖队首，不能把 overflow 当普通 stall |
| L1 读出 | `m_valid` out 1、`m_ready` in 1、`m_data` out 8 | 标准字节流；同步 RAM 读延迟用一个输出寄存器隐藏 |
| FIFO 维护 | `flush` in 1，`overflow` out 1，`level` out | flush 为同域维护操作；level 位宽由深度决定 |
| UART TX 输入 | `s_valid` in 1、`s_ready` out 1、`s_data` in 8 | ready 表示可接下一字节，不表示对端已收到；TX=8N1，空闲高，LSB first |

UART TX 接受字节后必须将当前字节发完。链路断开时可清尚未发送队列，正常恢复不得制造半个 UART 字节；复位是例外。UART 不含 SEQ／source_id；其 wrapper 通过实例编号归属错误和来源。

#### 5.3 HC-05 状态接口

```systemverilog
// hc05_status：拟定合同，不是 RTL
input  logic clk, rst_n;
input  logic state_async;           // 仅 HAS_STATE=1 使用
output logic link_up;               // 同步／去抖后的连接提示，不是数据 valid
output logic disconnect_event;      // 单拍；另有 sticky 诊断
```

无 STATE 时不得声称可靠检测断线；空闲串口不等于断线。STATE 不直接门控 RXD 或逐字节 valid，断线通过 recovery_ctrl 有序恢复，不把工作中被锁定的帧槽直接清掉。AT 配置可一次性在模块外完成，波特率／电平／引脚由平台确认。

#### 5.4 每链路 SLIP／CRC／完整帧存储

`slip_frame_rx` 只接 L1 的 `s_data[7:0]/s_valid/s_ready` 和维护 `flush`。CRC 更新是其内部数据通路；无需再把“已验证的 payload”送入共享 parser 后重算一次 CRC。

存储内部使用如下逻辑动作，不要求为每个动作另建 FSM：

| 动作 | 含义 |
|---|---|
| reserve | 候选帧开始前获得一个可写槽；槽尚不可被仲裁器看到 |
| write | header 记少量寄存器，payload 写槽；CRC trailer 单独记两字节并比较 |
| commit | 分隔符到达、实际长度／类型／版本／CRC 全对后，原子发布 metadata／队列项 |
| abort | 仅释放候选写槽，不发布；不能影响已提交的其他槽 |
| pop | 仲裁器最后一个 payload 字节握手后，释放已读队首槽 |

L2 对 Frame Arbiter 的接口是已验证 payload 流：

```systemverilog
output logic        m_valid;
input  logic        m_ready;
output logic [7:0]  m_data;
output logic        m_first, m_last;
output logic [7:0]  m_type;          // 仍是 u8，不裁成 2 bit
output logic [15:0] m_seq;
output logic [5:0]  m_payload_len;   // 1..32，需要 6 bit 才能表示 32
output logic        frame_available;// 已提交队首存在，可与首字节预取 valid 分开
output logic        frame_active;   // 给故障清理／槽 pin 使用
```

来源号可在 Arbiter 输入 wrapper 固定为实例号，不必在每个槽重复存一位。TYPE／SEQ／LEN 在整帧输出期间不变；内部 `frame_pop` 是末字节握手事件，不与每字节 ready 混用。CRC／SLIP分隔符不出现在此接口，既不携带 raw CRC，也不再携带一个可疑的“crc_ok 但还没验证完”的状态。

错误接口建议为各链路 sticky mask＋本拍 `err_valid/err_code`，包括 CRC、转义、LEN、version/type、timeout；计数不能依赖下游 ready，否则背压时错误会消失。错误原因不是 v1 新增线上字段。

#### 5.5 Frame Arbiter 与共享 Dispatch

两路输入均使用 §5.4 流；输出同字段，增加 `m_source_id[0:0]`。另接 `admit_new_frame`，来自共享 Dispatch 的新帧接收许可。

帧锁定规则：

1. 仅选择有完整已提交帧且未被隔离的来源；必须有 `admit_new_frame`。
2. 双方有帧时 RR；只有一方有帧时立即服务，不空等另一方。
3. 一旦授予，保存 owner 直到该帧 `m_last && m_valid && m_ready`；即使另一来源就绪、当前 ready=0，也不能抢占。
4. 输出寄存器与同步读预取持有当前字节；不要求每拍一字节，必须先保证稳定握手。最后字节只能 pop 一次。
5. 完帧后 `rr_next = ~owner`，而不是盲目每拍翻转。
6. 每来源内部保持 FIFO 顺序；跨来源没有可依赖的物理到达总顺序。仲裁授予顺序定义统一执行顺序，不添加线上时间戳。

Dispatch 锁存 frame_source/type/seq/len，并按 TYPE 驱动一个目标 FSM。其 `admit_new_frame=0` 可用于 MIDI 尾部收束、Config commit 和回复入队，不需要让 Arbiter理解 EQ 或 MIDI 状态。

#### 5.6 MIDI Parser、event FIFO、完成信号

```systemverilog
// 以下方向相对共享 midi_analyzer 或其薄上下文 wrapper
input  logic        s_valid;
output logic        s_ready;
input  logic [7:0]  s_data;
input  logic        s_first, s_last;
input  logic        s_source_id;
input  logic [5:0]  s_payload_len;

output logic        event_valid;
input  logic        event_ready;
output logic [31:0] event_data;
output logic        event_source_id;
output logic        frame_done;
output logic        parse_error;    // 单拍／sticky+计数，不是 Config NACK
input  logic        flush;          // 有序维护使用，不能为别的来源半途乱清
```

源码尚不存在，端口名是拟定合同。若 MIDI FSM 本身保持纯字节→32-bit Event，可由外层 wrapper 锁存来源并附带到事件；两种拆分都不得重复 MIDI 解析。

事件数据严格保留：

```text
31:28 kind      0 Off / 1 On / 2 CC / 3 Program / 4 Bend
27:24 channel   0..15
23:17 data1
16:10 data2
 9:0  reserved  全 0
```

event FIFO 一次存 `{event_source_id, event_data}`，宽度 33 bit。不能另外用两个不同步的 FIFO 分存来源和事件，也不能用 reserved 位塞 source。consumer 出队时 source 和 event 一起锁存，跨多拍操作也不能换来源。

`s_last` 被接受不等于 `frame_done`：末字节可能刚组成一个事件，仍在等 event_ready。所有该帧合法事件已交入 FIFO、尾部异常处理完、没有挂起输出后才给 frame_done；Dispatch 再允许下一帧，避免新 first 清掉上一帧的末事件。frame_done 只表示解析完成，不表示 FIFO 已清空或音符已发声。

只按握手处理 first/last；同拍 first/last 的包须先建立局部上下文再处理该字节。MIDI 错误按 MIDI_REFERENCE 恢复，已产生合法事件不回滚，也不为 MIDI 发送 REPLY。

#### 5.7 Config Parser、shadow、提交与最终结果

输入 payload 流与 MIDI相同，额外锁存 `s_seq[15:0]`，长度上限为 16。一个 CONFIG 帧一条命令；解析时写最多 16-byte shadow，小字段校验结束前不动 active。

后级提交采用请求／完成两阶段：

```systemverilog
// Config Parser → commit bridge；字段在 valid&&!ready 时保持
output logic        cfg_valid;
input  logic        cfg_ready;
output logic        cfg_source_id;
output logic [15:0] cfg_seq;
output logic [7:0]  cfg_command;
output logic [4:0]  cfg_payload_len; // 1..16，不是完整帧长度
output logic [127:0] cfg_shadow;    // byte0 在 [7:0]，只 LEN 字节有效

// 后级 → Parser；request handshake 不等于已经提交
input  logic        cfg_done_valid;
output logic        cfg_done_ready;
input  logic [7:0]  cfg_result;     // 使用现有结果码，不新增线上错误码
```

内部 128-bit shadow 是寄存器容器，**不表示允许 128-byte payload**。初版两个命令实际只有 10／2 字节；可以实现为对应字段寄存器，而不是强制综合成一条宽总线。

提交前的屏障条件至少为：当前此前 MIDI parser 无挂起事件、event FIFO 已排空、事件消费者没有尚未退休的操作。消费者提供 `midi_ops_idle`；FIFO empty 一根信号不够。不能等待所有声部自然衰减，否则 CONFIG 可无限阻塞。

`cfg_ready` 只是后级接受一次请求；后级在安全边界原子更新成功后返回 OK。明确失败不得部分改 active，返回现有错误码。无 EQ 实现返回 NOT_READY。未确认结果时不能因本地超时就伪造失败并允许后级稍后偷偷提交。

最终回复接口：

```systemverilog
output logic        reply_valid;
input  logic        reply_ready;
output logic        reply_source_id;
output logic [15:0] reply_seq;
output logic [7:0]  reply_command, reply_result;
```

request_type 固定 02，由 Encoder 填入；来源／SEQ 必须来自锁存上下文，不读此时 Arbiter 正在看的另一来源。配置实际完成、结果缓存更新且回复已被 TX 通路安全接收后，才解除全局屏障。

#### 5.8 TX Router、回复队列、Encoder、UART TX

- TX Router 接 §5.7 的完整回复描述符，只将 valid 送到选中来源，ready 取该目的队列的 ready；反压时保留完整描述符。不存在“另一队列空就换一条 UART 发”的回退。
- 每来源建议一个深度 2 的小 reply FIFO，元素仅 `{seq[15:0], command[7:0], result[7:0]}`，来源由队列编号隐含。两路同 SEQ 的回复不会混淆。
- 每路 `slip_frame_tx` 用 `reply_valid/ready/seq/command/result` 接一条描述符，形成既定 `TYPE=80/LEN=3`，输出 `tx_data[7:0]/tx_valid/tx_ready` 到对应 uart_tx。
- Encoder 保持当前 frame 的计数／CRC／escape 阶段，不需要完整 24-byte wire 缓存。CRC 对每个原始 body 字节只更新一次，不因一个字节转义成两个线上字节就更新两次。
- 若加 TX byte FIFO，只作为已证明有收益的参数化选项；不默认同时堆大回复队列、完整帧缓存、256-byte TX FIFO 三份数据。
- 可在授予 CONFIG 前预留本来源一个 reply credit；额度由 FIFO 空位和已预留槽计算，防止 commit 后才发现 ACK 无处入队。这只是内部资源握手，不新增协议。
- 有限队列仍可能满，不能声称永久故障隔离。没有 reply credit 的来源，其队首 CONFIG 暂不授予，不能跳过它读同源后帧；可以继续选择另一来源。已授予 CONFIG 的全局提交屏障仍必须遵守。

#### 5.9 错误／恢复控制侧带

错误维护接口独立于业务 valid/ready，不占 MIDI Event 或线上 reserved 字段：

| 侧带 | 产生者 → 接收者 | 合同 |
|---|---|---|
| `err_valid / err_code / err_source_id` | UART/FIFO/framer诊断汇总 → counters | clk域单拍，计数／sticky不受业务ready反压；同拍多层错误分别置mask，不能只保留优先级最高项而丢诊断 |
| `link_fault_pending[1:0]` | recovery_ctrl → Dispatch／适配层 | 每来源保持到清理确认；不是一个可能被忙消费者错过的单拍 |
| `source_quarantine[1:0]` | recovery_ctrl → Arbiter／事件消费者／TX | 禁止新授予和旧源事件重新发声；不修改已锁定帧的字节流 |
| `rx_flush[1:0]` | recovery_ctrl → 对应UART字节入口／L1／候选帧 | 同域维护，清未提交流；已授予槽另按pin／pop规则保留 |
| `source_drain_done[1:0]` | parser上下文／消费者操作跟踪 → recovery_ctrl | 本来源无锁定帧、挂起输出、排队／执行中事件；不能仅由L1 empty推出 |
| `source_cleanup_done[1:0]` | 音符／控制适配层 → recovery_ctrl | 本来源音符／踏板状态已清；通信FSM不得自行假定音频已经停止 |
| `session_restart[1:0]` | 平台／连接会话管理 → recovery_ctrl | 显式会话重建，不由串口空闲生成；旧来源上下文收束后清该来源重试缓存 |
| `tx_flush / retry_cache_flush` | recovery_ctrl → 对应来源队列／缓存 | 只在旧上下文有序收束后作用，不清另一来源或全局active EQ／混响 |

这些是未来集成所需的内部控制端口，不是本轮新增的私有命令。具体err_code的本地编码可在实现时统一，不改变v1的Config result取值。

### 6. 缓冲布局、资源与时序

#### 6.1 推荐第一版存储组织

| 存储 | 数量／建议起点 | 存什么 | 为什么需要 |
|---|---|---|---|
| RX L1 | 每来源 1 个，深度参数化；可沿用 HC-05 草案的 1024-byte 起点 | 未解析 UART 字节 | 物理 RX 不可反压，吸收服务停顿 |
| 完整帧 L2 | 每来源 1 个，建议已提交深度 8；另预留候选写槽 | payload≤32＋type/seq/len metadata | 验证前不可见，验证后可等待仲裁 |
| MIDI event FIFO | 共享 1 个，深度参数化，例如 64 | 33-bit event＋来源 | parser 与较慢适配操作解耦 |
| Config shadow | 共享一份 ≤16 bytes | 当前配置工作记录 | 参数一起验证／提交 |
| Config 最近结果缓存 | 每来源一份 | seq、len、完整 payload≤16、result、valid | `{source,seq,payload}` 去重，不能只比 CRC |
| reply FIFO | 每来源 2 条起点 | 每条 32-bit 描述符 | 两路 UART TX 独立推进 |

L2 采用单份 payload RAM：接收时写保留槽，CRC 通过再发布，失败回收；不要另建 40-byte staging 后再整帧 memcpy。header 只需少量寄存器，CRC 两字节用于比较；发布后共享解析器只需 payload，没必要在每个槽重存 header／CRC 与 metadata。

8 个 committed 槽＋1 个候选槽的 payload 逻辑容量为每路 `9×32=288 bytes`；槽是否可开始写、何时 commit／pop 由单写者指针与计数器控制。完整已提交队列满时可在新帧首反压，不覆盖旧槽。这个组织是设计建议，不能据此改 PROTOCOL 的线上上限。

#### 6.2 RAM 与流水

- L1 用同步 RAM FIFO，L2 用窄字节 RAM＋小 metadata 队列。32-byte slot 可用 `{slot_index, byte_offset}` 拼地址，避免宽乘法或 320-bit 帧总线。
- 读口按一拍 RAM 延迟设计，设置 1-byte 预取／输出保持；ready 低时冻结持有字节。任何 slot pop 都不能发生在最后字节实际握手之前。
- CRC 每接收一个解码 header／payload 字节更新一次；不在帧尾再遍历 RAM 复算第二遍。计算方式可用字节并行组合函数，后续看时序决定是否拆拍，不能假定 CRC 自带独立慢时钟。
- 两路小 CRC／SLIP 逻辑各自一份，省去跨源逐字节仲裁和额外暂存。UART 速率远低于 clk，优先正确握手而非强求所有模块连续每拍一个字节。
- 不默认加入多级 command FIFO、DMA、可变长动态内存、全功能蓝牙状态机或 PLL。实际 BSRAM 会按原语粒度分配，逻辑 bit 数不等于综合 BSRAM 数，本文不宣称面积／Fmax 已验证。

#### 6.3 容量预算不是流控保证

8N1 的持续到达速率约 `R_i=BAUD_i/10 bytes/s`。停顿期间若没有任何可用帧槽，保守弹性时间只按当前 L1 空余量计算：`T_i ≤ free_L1_i/R_i`；不要把已占用槽也算成空闲。

若要把 L2 空槽折算为可接收的 wire 字节，必须指定消息大小／转义分布／当前占用状态。原 HC-05 草案的固定帧估算不是任意流量的最坏保证，尤其 4 Mbaud 有线输入比 115200 蓝牙更快耗尽同样的 L1。两个来源的余量不能相加救一条已经溢出的链路。

应给 commit、消费者长操作、回复排队设可验证的延迟预算；主机限制突发并遵守 Config stop-and-wait。Config 最坏≤50 wire bytes，MIDI≤82，**不能用“payload只有16字节”推断整个通信无需缓冲**。

### 7. 双路并发、配置顺序与幂等

#### 7.1 顺序举例

```text
WIRED: M0 → C0 → M1
BT:    B0 → B1
一种合法仲裁序列: M0 → B0 → C0 → B1 → M1
```

每来源保序即可，跨来源谁先授予由 RR 决定。C0 接收并验证后：此前 M0／B0 的事件操作先完成，C0 commit／结果入队完成后，B1／M1 才可进入共享解析器。后续不允许通过另一条链路绕过全局 EQ／混响屏障。

MIDI 帧末事件未交入 FIFO时也不得启动下一帧的 first；这一点由 frame_done／admit 联合保证，而非只看 last 已消费。

#### 7.2 Config 状态与回复缓存

- 当前命令 shadow 可共享，因为命令串行；最近结果缓存必须每来源独立。
- 缓存键为来源所指的当前会话＋SEQ，比较完整 payload。源0的SEQ=1和源1的SEQ=1是两个请求；相同数字不能导致错误 ACK 重放。
- 同源同SEQ同payload重放旧结果，不再次 commit；同源同SEQ不同payload返回现有 SEQ_CONFLICT。
- 若源0命令已OK，随后源1改了全局混响，源0重试旧请求只重放历史OK，不能把混响改回去。
- 跨重连缓存已按用户确认采用 PROTOCOL；本文不新增线上 session_id。上层会话重建通知经有序恢复后清相应缓存，旧会话回复不能泄漏给新连接。

### 8. 背压、错误与来源恢复

#### 8.1 背压链

```text
consumer慢／Config提交
 → event FIFO满或Dispatch禁止新帧
 → Arbiter锁帧等待／不授予下一帧
 → 每来源L2满
 → framer不再读L1
 → L1满时新UART字节无法保存：overflow硬故障
```

ready 只约束 FPGA 内部，不能暂停对端 UART。任何层都不得覆盖最旧 MIDI 事件／帧来腾位置。被丢弃的可能是 Note Off，不能只增加一个计数然后继续假装状态可靠。

#### 8.2 错误合同

建议每来源有 32-bit 饱和计数及 sticky mask；内部错误脉冲不需要 ready。各层提供本层检测，恢复层统一归属，避免重复计同一次错误。

| 错误 | 检测者 | 处置 |
|---|---|---|
| 假起始 | UART | 不产生有效字节，计诊断 |
| framing／break／L1 overflow | UART／FIFO | 半帧失效，报告 source fault；不能给不可信 SEQ 发 ACK |
| SLIP／CRC／LEN／version/type | framer | 候选槽 abort、计原因、到 C0 重同步；不发布，不伪造 Config 回复 |
| 半帧字节间超时 | framer | 按 PROTOCOL 建议1000ms，abort并报告fault；不是空闲断线检测 |
| L2满／event FIFO满／reply FIFO满 | 相应队列 | 正常反压，直到真正产生无法保存的物理字节才升级 |
| MIDI语法错误／不完整包尾 | MIDI Parser | 按合同恢复与计数；同帧先前合法事件不回滚，不发Config NACK |
| 合法外层的Config参数错误 | Config Parser | active不变，返回既有错误码 |
| 后级未就绪／提交失败 | Commit端点 | 无部分生效，返回既有NOT_READY等合法结果；不假ACK |
| HC-05 STATE下降 | 状态管理 | 来源会话恢复流程；不是立刻抽掉正在读的槽 |

超时只在候选非空帧真正等待下一线上字节时计时；L1 有积压字节、内部反压、完整帧等消费、长音静止都不是字节间超时条件。实现时不得让FIFO服务延迟被误认成物理链路断线。

#### 8.3 不能只“flush FIFO”，还要防止旧事件复活

源 A 在一帧已经开始流向共享 parser 时故障，建议有序处理：

1. 将 A 置 `quarantine`，禁止新授予／新会话接入；停止发布其新帧，清 L1 和未提交候选。
2. 已授予帧的槽继续 pin，允许剩余已验证 payload 发完；“已授予”包括first尚因ready=0未握手但owner已经锁定的情况。其他未授予 A 帧可在双方知晓的维护flush下丢弃；不能无通知撤掉正在等待握手的流。不能让 parser 永远收不到 last。
3. 立即通知 MIDI 适配层将 A 标记失效并清其音符／踏板状态；恢复期间 A 的旧排队事件只消费丢弃，不能在清音后又重新触发。源 B 的事件照常按FIFO出队，不全局flush。
4. 等 A 的 parser 尾部与挂起event交付完成、该来源 outstanding事件／消费者操作计数归零后，再确认 A 已清理。可用两个小的每源计数器及当前owner跟踪，不必把epoch塞进32-bit Event。
5. 有序清 A 的重试／回复上下文后，再按可观测的会话重建信号开放其新输入，从 C0 寻帧。没有可靠断线／重建信号时该生命周期仍是集成待定项，不能用空闲自行猜测。

故障只发一个清音脉冲但仍保留可执行的 A 旧 Note On 是错误的；“当前完整帧允许发完”也不表示故障后仍应让其事件重新发声。

如果是正在处理的 A 配置：尚未提交可取消 shadow；提交请求已被后级接受则必须取得真实结果，不能凭断线回滚共享配置或捏造失败。回复按旧会话处理／丢弃，绝不能被发给刚重连的新会话。全局复位可以整体中止，但正常单源故障不随意打断另一来源的 parser。

### 9. 与现有电子琴 RTL 的最终接入

通信子系统的业务端点只有两组：

```text
{event_source_id, event_data[31:0]} → MIDI状态／fmap适配器
validated Config shadow/commit    → EQ／混响配置适配器
```

现有 `pad_voice_top.src_sel` 是**本机压力垫／外部fmap**选择，不是 WIRED／BT 来源号。两条外部链路先完成来源语义管理后输出同一个 fmap_ext；不能用这个1-bit寄存器直接混合两路UART。

fmap 只是16个压力值，不承载全部音符、通道、弯音和表情。未来适配层保留 `(source_id, channel, note, 按下实例)` 归属，解决32音选择／16声部／同音重叠／踏板／断线；HC-05草案的“每音两位持有标记”只是一种简化建议，不等价于完整同源重叠音符与多通道管理。

混响preset可适配现有端口，但通信的0/1/2需转换RTL枚举；原子提交／确认在薄适配层设计，不能直接将收到的字节变成ACK。EQ当前无完整端点时返回NOT_READY；本轮不为它新增DSP。音色切换／reload造成的忙状态要反馈到事件消费者的操作完成／反压，而不是让parser悄悄丢消息。

两个来源可同时接收帧，不等于已支持多轨多音色、远程采样级时间戳或整机音频回传。主机负责SMF解析与走带，浏览器USB-UART和Android SPP都必须实现既有SLIP／CRC封装；SPP分片边界与帧边界无关。

### 10. 实现顺序与独立验证

本轮不创建这些RTL／TB。后续每一步须能独立仿真，不要求先有整机音源。

| 阶段 | 模块／范围 | 自检Testbench退出条件 |
|---|---|---|
| 0 | 解决§1冲突，冻结文档接口命名 | 线上字段、32-bit Event不变；会话重建／故障责任有明确归属 |
| 1 | UART RX/TX＋L1；两路同RTL不同参数 | 8N1、背靠背字节、假起始、stop错误、break、波特率偏差、复位；overflow不覆盖数据 |
| 2 | 单链路SLIP＋CRC＋事务帧存储 | 六组frame_vectors；CRC check=29B1；DC/DD正确、DB C0非法、垃圾前缀、共享C0、长度边界、超时、无CRC前发布 |
| 3 | 双帧源＋Frame Arbiter＋Dispatch壳 | 模型产生独立完整帧；双路并发RR、单路连续、随机ready、元数据稳定、不交错、链路内保序、最后字节只pop一次 |
| 4 | 共享MIDI Parser＋33-bit event FIFO | MIDI_REFERENCE全部向量；最大32-byte包；单字节包、零力度、running status、实时／SysEx、异常恢复、输出stall、末事件pending与reset |
| 5 | Config Parser＋shadow＋mock commit端点 | LEN16可进语义检查、LEN17外层拒绝；EQ10／reverb2、越界、原子更新、commit失败无部分生效、ACK必须晚于真实完成 |
| 6 | 每源去重＋TX Router／Encoder／UART TX | 同SEQ双来源不冲突；重复不二次commit；ACK只回原源；TX随机stall、转义CRC与现有reply向量一致 |
| 7 | 通信闭环，无需音频RTL | 两个UART BFM发交错分片，输出事件／配置／回复scoreboard；MIDI→Config→MIDI屏障；一源坏帧不污染另一源 |
| 8 | 故障恢复／慢消费者集成 | 故障发生在候选帧、已授予帧、末事件pending、Config commit、TX半帧各阶段；清音后旧事件不复活，不串会话ACK |
| 9 | 接MIDI适配／真实router，再上板 | mock替换为业务端点；本机／外部src_sel切换、按键／踏板释放、配置枚举、router忙；最终真实USB-UART／HC-05／DAC验收 |

#### 10.1 自动断言／scoreboard重点

- `valid && !ready` 时所有流字段稳定，唯一例外是全局reset／事先定义的维护中止。
- packet可见 ⇒ CRC、TYPE、VER、实际LEN已通过；未提交槽永远不被仲裁器读。
- 帧内source/type/seq/len恒定，first只在索引0，last只在LEN−1；握手数精确等于LEN。
- Arbiter owner锁定到last握手；FIFO计数／保留槽无上溢、下溢、重复pop。
- frame_done不得早于末事件输出握手；跨帧RS不可继承；33-bit FIFO来源与事件一一对应。
- Config ACK OK之前必须有对应真实commit完成；重试同请求不再次commit；不响应坏CRC或MIDI。
- 每个回复的来源／SEQ与原配置一致，源0/源1的相同SEQ测试必须同时覆盖。
- 保序按**每来源**及**仲裁授予总顺序**建立两种scoreboard，不错误要求跨UART的物理发送时刻总顺序。

#### 10.2 最终验收边界

先做完整通信闭环的仿真：两端输入标准帧，检查32-bit事件＋来源、配置真实提交、对应来源的完整回复。然后才接音频适配器及router；最后用逻辑分析仪、USB-UART和Android SPP验证真实电平、波特率、STATE及长期运行。

本次文档核对／计算不等于任何新模块已有仿真PASS、综合时序通过或板端出声。**下一步是按本文合同分别设计模块，而不是在此轮提前实现MIDI解析器。**


<a id="protocol"></a>

## 早期协议草案

日期：2026-10-26。状态：**字节级设计方案，供审阅与后续实现；无 RTL。** 外层消息不是 MIDI 标准的一部分；MIDI_DATA 内的 MIDI 字节保持标准含义。

### 1. 分帧方式

采用 RFC 1055 的 SLIP 定界／转义约定，内部自定义 header 与 CRC：

```text
C0 | SLIP_ESCAPE(HEADER + PAYLOAD + CRC16_LE) | C0
```

SLIP 只负责边界，不自带消息分类或校验；TYPE、LEN、SEQ 和 CRC 是本机协议增加的字段。不传 IP 包，也不是直接发送裸 MIDI。

#### 1.1 转义

| 未转义字节 | 串口上发送 |
|---|---|
| C0 | DB DC |
| DB | DB DD |
| 其他 | 原字节 |

- header、payload、CRC 全部参与转义；首尾 C0 不参与。
- 每帧发送首、尾两个 C0。帧间连续 C0／空帧忽略，也接受相邻帧共享一个 C0 的接收形式。
- 开始寻找第一枚 C0 之前的垃圾字节忽略。
- 非法 `DB xx`、帧末悬空 DB、超长均将当前帧标为无效；丢弃到下一枚未转义 C0 后重新同步，不发布部分 payload。

**为何需要转义：** MIDI 的 Program Change 通道 1 状态本身就是 C0；通道压力也可能出现 DB。私有配置和 CRC 更可能包含任意字节，不能靠裸帧头匹配区分。

### 2. 固定帧头

下表 offset 均指 **SLIP 解码后的 frame body**，所有整数为小端，不受 flash 镜像的大端格式影响。

| Offset | 字段 | 字节数 | 定义 |
|---:|---|---:|---|
| 0 | VERSION | 1 | 固定 01 |
| 1 | TYPE | 1 | 01=MIDI_DATA，02=CONFIG，80=REPLY |
| 2 | SEQ | 2 | 序号／配置请求标识，低字节在前 |
| 4 | LEN | 2 | 未转义 payload 的字节数，低字节在前 |
| 6 | PAYLOAD | LEN | 按 TYPE 解释 |
| 6+LEN | CRC16 | 2 | 覆盖 VERSION 到 payload 末尾，低字节在前 |

**body 总长度必须恰好为 `LEN + 8`。** 不含首尾 C0；LEN 不包含 header、CRC 或转义增加的字节。

#### 2.1 长度限制

| TYPE | 合法 payload 长度 |
|---|---|
| MIDI_DATA | 1..32 |
| CONFIG | 1..16，且必须再匹配具体命令长度 |
| REPLY | 固定 3 |

`MAX_MIDI_PAYLOAD=32`，`MAX_CONFIG_PAYLOAD=16`；共享帧缓存按全局 `MAX_PAYLOAD=32` 设计，最大解码 body=40 字节，最坏转义后、含两个 C0 的线上帧长=82 字节。CONFIG 帧最多 24 字节 body、50 字节最坏线上长度。

长度按实际内容填写，不补齐到上限：REVERB_SET 为 2 字节、单段 EQ_SET 为 10 字节。多段 EQ 分别发送配置帧；CONFIG payload 大于 16 字节即拒绝。

LEN 越界时直接进入丢弃状态，禁止据 u16 声称的长度无限写缓存。CRC 通过、实际长度匹配、版本／类型／长度合法之后，才允许发布。

FIFO 深度需按 UART 速率、下游停顿与峰值流量另算；上述帧上限不是接收永不溢出的保证。

### 3. CRC16 完整定义

名称：**CRC-16/CCITT-FALSE**，也称 **CRC-16/IBM-3740**。

```text
width   = 16
poly    = 0x1021             // 不把 x^16 的最高项放进这个值
init    = 0xFFFF
refin   = false
refout  = false
xorout  = 0x0000
check("123456789") = 0x29B1
```

每个**原始未转义**字节先 XOR 到 CRC 高 8 位，再按 MSB-first 移位 8 次；CRC 字段本身不参与计算。UART 的字节内串行位序与 CRC 的内部算法位序不要混淆。

参考伪代码：

```text
crc = FFFF
for byte in HEADER + PAYLOAD:
    crc = crc XOR (byte << 8)
    repeat 8:
        if crc bit15 == 1: crc = ((crc << 1) XOR 1021) AND FFFF
        else:             crc = (crc << 1) AND FFFF
append crc[7:0], crc[15:8]
再对 HEADER + PAYLOAD + CRC 做 SLIP 转义
```

不混用 XMODEM（init=0000）、X25（反射／不同 xorout）或 MODBUS（不同多项式）。CRC 是错误检测，不是认证或加密。

### 4. 接收提交、超时与错误

1. RX FIFO → SLIP 解码 → 短帧缓存，边解码边计算 CRC。
2. 未转义 C0 到来后，检查 frame body 长度、LEN、CRC 和 header。
3. 全部通过才发布一帧，demux 根据 TYPE 交给 MIDI／CONFIG FSM。
4. 下游反压时持有已验证帧；不覆盖尚未消费的缓存。

半帧接收设可参数化的**字节间超时**，初始建议 1000 ms，只在已经进入非空帧且等待后续线上字节时计时。每收到线上字节重置；完整帧等待下游消费不计该超时。空闲链路不视作断线，更不能拿它判断长音是否应该停止。

超时／UART framing error／RX FIFO 溢出使当前半帧失效，并通知上层 `link_fault`。CRC 错、非法转义、长度错误也应有计数／错误标志；这些情况下不信任 SEQ，**不伪造 CONFIG ACK**。不可“发现 CRC 错但前面的 Note On 已执行”。

VERSION／TYPE 不认识：丢弃并计数；REPLY 不被当成 MIDI 或配置。错误恢复／清音由独立顶层负责，分帧 FSM 本身不修改 fmap。丢帧可能丢失 Note Off；CRC 不能保证可靠投递或消除挂音。

### 5. MIDI_DATA：包内标准 MIDI

- payload 是 MIDI 演奏字节，不是 SMF 文件字节；不含 `.mid` header、delta-time、meta event。
- v1 使用**自包含的短 MIDI 数据包**：每个包独立建立 running status，不能依赖上一个包的状态，也不能把一条短消息拆跨包。
- 允许同包内 running status；上位机优先每条消息都带 status，利于定位错误。
- 每包开始清解析局部状态；每包结束清 pending／running status／SysEx skip 状态。包间 CONFIG 不会成为 MIDI 字节。
- 完整且合法的支持消息按顺序产生事件。语法错误计数、丢弃不完整消息并按新 status 重同步；**先前已经产生的合法 MIDI 事件不做回滚**。CRC 帧提交不等于 MIDI payload 的事务回滚。
- SysEx／System Common／Real-Time 等首版不产生业务动作，但必须按 MIDI_REFERENCE 中的规则识别／跳过，不能吞掉其后的 Note Off。
- 不按通道音色策略过滤 byte parser；事件保留 channel 0..15，实际播放能力另定。

MIDI payload 的具体状态机和事件字段见 [MIDI_REFERENCE.md](HISTORY.md#references)。

### 6. CONFIG payload

一帧只包含一条配置命令，首字节为 COMMAND。配置仅作用于本机 EQ／共享混响，不假装是标准 MIDI 控制器。

#### 6.1 `01 = EQ_SET`，LEN=10

| Payload offset | 字段 | 类型 | 定义 |
|---:|---|---|---|
| 0 | command | u8 | 01 |
| 1 | band_id | u8 | 0-based 段号，必须小于实现的 EQ_BANDS |
| 2 | enable | u8 | 0=旁路此段，1=启用 |
| 3 | filter_type | u8 | v1 仅 0=peaking/bell；其他值拒绝，不偷偷换成别的滤波器 |
| 4 | frequency_hz | u16 LE | 中心频率，20..20000 Hz，并满足设备采样率约束 |
| 6 | gain_q8_8 | i16 LE | dB×256，二补码；设计范围 −12..+12 dB，即 −3072..3072 |
| 8 | q_u8_8 | u16 LE | Q×256；设计范围 26..2560，约 0.1..10 |

以上是供实现评审的首版参数编码，实际 EQ_BANDS 和 DSP 能力仍待确认。未实现 EQ 时应报 NOT_READY，而不是接收成功却无效果。

所有字段验证后写 shadow，并将该段作为完整更新提交。即使 enable=0 也校验其余字段。高层参数到 IIR 系数的计算、量化及稳定性检查另行设计，不在 UART/MIDI parser 中做；不能直接把未经检查的 32-bit 系数写进滤波器。

#### 6.2 `02 = REVERB_SET`，LEN=2

```text
command:u8 = 02
preset:u8  = 00 NONE / 01 HALL / 02 BATHROOM
```

其他 preset 拒绝。v1 无 amount、反馈或延迟字段；不虚构当前 router 没有的参数接口。

通信编号必须显式映射：当前 `router_pkg` 原生枚举为 `BATHROOM=0 / HALL=1 / NONE=2`，与线上编号不同，禁止直接强转。NONE 表示直通，不需要另发 enable。

不支持的 command 返回 UNSUPPORTED。未来扩展应分配新 command 或升版本，不改变现有 LEN=2 的含义。

### 7. 配置寄存器、顺序与回复

```text
CONFIG 解码／校验 → shadow → 等待此前 MIDI 操作完成 → commit → active → ACK
```

“此前 MIDI 操作完成”是事件 FIFO 已排空、消费者已完成对应操作且没有尚未退休的事件，不是所有声部已停止。配置等待期间不让后面的 MIDI 帧越过它；在 UART 入口缓冲，主机也须遵守 stop-and-wait。

#### 7.1 序号与重发

- MIDI_DATA 的 SEQ 是独立的 16-bit 帧标记，主机每个新 MIDI 帧递增模 65536；用于诊断，不自动重发、不依此丢弃合法同音重触发。
- CONFIG 使用独立的 16-bit 请求计数器，每个新配置递增模 65536；重试必须使用相同 SEQ 和相同 payload。
- 主机同一会话最多一条配置在途；收到最终回复前不发新的配置，也不发送需要该配置生效后的 MIDI。控制面滑杆在主机合并尚未发送的中间值。
- 设备保留最近配置的 SEQ、完整 payload 和最终结果。同 SEQ／同 payload 只重放结果，不二次 commit；同 SEQ／不同 payload 返回 SEQ_CONFLICT。
- 待处理配置的重复请求不排第二次；它们等原请求完成。缓存及影子状态在会话重建时由上层清除，不能把任意串口空闲误认为新会话。
- 初始建议主机配置超时 1500 ms 后重试，最多 3 次；最终失败明确报错，不继续假定配置已生效。超时值应大于设备操作上限和允许的半帧间隔。
- ACK 是实际生效或明确失败的结果，不是“进入 RX FIFO”或“写了一半 shadow”。

#### 7.2 REPLY，TYPE=80，LEN=3

header SEQ 回显配置请求 SEQ；payload：

```text
request_type:u8 = 02
command:u8      = 原 command；CONFIG LEN=0 在外层已拒绝
result:u8       = 下表
```

| result | 定义 |
|---:|---|
| 00 | OK，已经提交 |
| 01 | UNSUPPORTED，命令／filter_type 不支持 |
| 02 | BAD_LENGTH，命令长度不匹配 |
| 03 | OUT_OF_RANGE，字段值越界 |
| 04 | BUSY，不能接收此新配置；原配置不变 |
| 05 | SEQ_CONFLICT，同请求号内容不同 |
| 06 | NOT_READY，对应后级未实现／未就绪，或提交失败且未生效 |

OK 与错误结果都需缓存以便重复请求重放；错误不得部分修改 active。设备只为合法外层 CONFIG 生成该回复，不对 MIDI 或 REPLY 逐帧应答，不形成 ACK 循环。BUSY 失败若需再次尝试，主机用新的 CONFIG 请求号。

### 8. 可核对的线上例子

十六进制，空格只用于阅读：

```text
Note On，MIDI channel 0，note 60，velocity 100，SEQ=0
C0 01 01 00 00 03 00 90 3C 64 B3 4E C0

Program Change，channel 0，program 1，SEQ=1；payload 的 C0 必须转义
C0 01 01 01 00 02 00 DB DC 01 31 60 C0

设置 HALL，CONFIG SEQ=1
C0 01 02 01 00 02 00 02 01 85 C8 C0

上述 HALL 真正生效后的 OK 回复
C0 01 80 01 00 03 00 02 02 00 61 50 C0
```

完整六组向量见 [frame_vectors.json](../../frame_vectors.json)，含 EQ 1000 Hz／−6 dB／Q=1，以及 header 同时含 C0、DB 的转义情况。

### 9. 后续实现的最低验证项

- 正常帧、连续帧、重复 C0、垃圾前缀；逐字节随机空隙与背压。
- 在 header／payload／CRC 各处放 C0、DB，核对转义与 LEN。
- 单字节损坏、错误 CRC、LEN 过长／过短／不匹配、截断帧、非法转义、字节间超时。
- 未知 VERSION／TYPE／命令、CONFIG 长度错、EQ 越界、混响非法值均无部分副作用。
- 验证 MIDI→CONFIG→MIDI 的保序、commit ACK 时点、重复配置不二次生效。
- 下游停顿、event FIFO 满、RX 溢出报告与清音联动；不能靠丢掉 Note Off 让系统继续“看似可用”。

参考：[RFC 1055](https://www.rfc-editor.org/rfc/rfc1055)、[CRC catalogue：CRC-16/IBM-3740](https://reveng.sourceforge.io/crc-catalogue/16.htm#crc.cat.crc-16-ibm-3740)。


<a id="references"></a>

## MIDI 资料与实现参考

查阅日期：2026-10-26。这里的“参考实现”不是经 MIDI Association 认证的标准 IP。标准含义以 MIDI 规范为准，开源实现仅供状态机结构／测试参考，不能盲目照搬。

### 1. 网上查阅的来源

#### 1.1 MIDI Association：标准消息与控制器表

- [Summary of MIDI 1.0 Messages](https://midi.org/summary-of-midi-1-0-messages)
- [MIDI 1.0 Control Change Messages](https://midi.org/midi-1-0-control-change-messages)

用途：核对状态号、数据字节数、14-bit bend、CC1/7/11/64/120/123。公开表是摘要，不等于完整 Detailed Specification；不声称已取得或逐项实现全部规范。

#### 1.2 Arduino MIDI Library：主要状态机参考

- 项目：[FortySevenEffects/arduino_midi_library](https://github.com/FortySevenEffects/arduino_midi_library)
- 本次读取 master commit：`2d64cc3c2ff85bbee654a7054e36c59694d8d8e4`。
- [固定版本 MIDI.hpp](https://github.com/FortySevenEffects/arduino_midi_library/blob/2d64cc3c2ff85bbee654a7054e36c59694d8d8e4/src/MIDI.hpp)：重点看 `parse()`、`resetInput()`、`handleNullVelocityNoteOnAsNoteOff()`。
- 文件内许可：MIT。本次未复制或引入源码；将来复制／改编须保留许可声明。

值得参考：

- 分开保存 running status、pending index、expected length。
- Cn/Dn 只有一个数据字节，不把所有消息都按三个字节切分。
- 实时消息插入时保留正在拼装的普通消息。
- SysEx 独立处理，零力度 Note On 归一化为 Note Off。
- transport 与消息回调分层，与我们的 UART／parser／event FIFO 分离一致。

不能直接移植的部分：递归读串口、C++ 回调／模板、动态 SysEx 处理、1-based channel API、MIDI Thru 等不适合照搬到 FPGA。畸形输入恢复也要按本项目合同重写并测，不能仅因代码成熟就宣称完全标准兼容。

#### 1.3 Mido：主机消息工具，不作完整原始流黄金模型

- [Parsing MIDI Bytes](https://mido.readthedocs.io/en/stable/messages/parsing.html)
- 本次读取 main commit：`7c1de5df224a5f0c602af8158c8fc25497ad351b`。
- [固定版本 tokenizer.py](https://github.com/mido/mido/blob/7c1de5df224a5f0c602af8158c8fc25497ad351b/mido/tokenizer.py)，MIT。

可用于上位机生成／核对显式状态消息、SMF 事件转换和基本消息字段。但本次审阅该 tokenizer 发现：完整消息后 `_status=0`，未保持 running status；实时字节在非 SysEx 中会清 `_status`，与 MIDI 实时消息可插入普通消息的需求不一致。

所以不能只用 `mido.Parser()` 的结果证明我们的 running status／实时插入实现正确。相关边界必须写独立向量，以规范规则核对。

#### 1.4 Tang Nano 的 Verilog：仅最简硬件案例

- 项目：[kingyoPiyo/Tang-Nano_MIDI_Sounder](https://github.com/kingyoPiyo/Tang-Nano_MIDI_Sounder)，MIT。
- 本次读取 master commit：`a015c80d9b11c7e7a6c3d28a26fdfb9ba16f6d1c`。
- [固定版本 src/MIDI_Decoder.v](https://github.com/kingyoPiyo/Tang-Nano_MIDI_Sounder/blob/a015c80d9b11c7e7a6c3d28a26fdfb9ba16f6d1c/src/MIDI_Decoder.v)。

只有简单的 8n/9n → 两个数据字节 → RAM 的状态机。没有我们的 CC、Program Change、Pitch Bend，也未处理零力度归一化、running status、实时插入等完整边界，还把 voice/RAM 管理混入解析器。**可参考字节 valid 接口，不选它作为本项目完整 parser。**

交叉解释资料：[SparkFun MIDI Tutorial / Advanced Messages](https://learn.sparkfun.com/tutorials/midi-tutorial/advanced-messages)，用于核对 SysEx 中实时字节不中断、其他 status 会终止 SysEx 并开始新消息。教程不是规范替代物。

### 2. 解析器的输入／输出边界

输入是已经过外层 CRC 验证的 MIDI payload 字节，`data:u8 / valid / ready`，另带 `frame_start / frame_end` 边界，边界与对应字节交付一致。未来独立测试可直接注入这些字节，不需要真正 UART 或 HC-05。

输出是 MIDI event 的 `valid / ready / data`，接 event FIFO。输出受阻时必须保持数据稳定，输入可反压；不自行覆盖未交付事件。

不在此模块做：音符→slot、力度→压力、踏板保持、音色换表、弯音 Hz 计算、表情增益计算或 EQ。它们由事件消费者实现。

#### 2.1 当前传输 profile

标准裸 MIDI 流允许消息／running status 延续，本机外层帧另外采用**包内自包含** profile：

- MIDI 帧首清局部解析状态；首个非实时消息必须显式给 status。
- running status 允许在同一帧内使用，不跨帧。
- 短消息不得拆跨帧；包尾不完整消息丢弃并报解析错误。
- SysEx 业务暂缓，包内跳过即可；不将长 SysEx 拆帧传输。
- CONFIG 帧不送入 MIDI parser；不能把私有帧头当 MIDI status。

这是本机封装限制，不宣称标准 MIDI 原本就有这样的包边界。未来若要直接接裸 MIDI 串口，需独立定义连续流模式，不能沿用每帧清状态规则后又声称支持跨帧流。

### 3. 首版产生事件的消息

`n` 为 channel 0..15；data1/data2 均 7-bit。

| Status | 数据字节数 | 输出 |
|---|---:|---|
| 8n | 2 | NOTE_OFF，保留 note 和 release velocity；消费者可忽略释放力度 |
| 9n | 2 | NOTE_ON；velocity=0 时归一化 NOTE_OFF |
| Bn | 2 | 仅 CC1、7、11、64、120、123 输出 CONTROL_CHANGE |
| Cn | 1 | PROGRAM_CHANGE，编号原样保留，不直接转换本机 instrument_e |
| En | 2 | PITCH_BEND，原始 lsb/msb；`bend14={msb[6:0],lsb[6:0]}`，中心 8192 |

CC120/123 的 v1 发送端用 value=0；非零保留为语义不支持，不执行静音／松键，计数后忽略。CC64 的 0..63／64..127 开关解释交给消费者。

CC7 与 CC11 为独立事件和状态，不能互相覆盖；CC11 的线性调制由消费者连接，不是重新定义它为 pitch modulation。

#### 3.1 32-bit event 格式

| Bits | 字段 | 定义 |
|---|---|---|
| 31:28 | kind | 0=NOTE_OFF，1=NOTE_ON，2=CONTROL_CHANGE，3=PROGRAM_CHANGE，4=PITCH_BEND；其余保留 |
| 27:24 | channel | 0-based，0..15 |
| 23:17 | data1 | note / CC编号 / program / bend LSB |
| 16:10 | data2 | velocity / CC值 / 0 / bend MSB |
| 9:0 | reserved | 全 0 |

该格式为本机内部合同，不是 MIDI 线上消息，也不是旧 class_format Event64。Program Change 的 data2=0；9n velocity=0 归一化后 kind=NOTE_OFF、data2=0。不含 voice、时间戳或本机音色号，避免把后续适配策略锁死在 parser 中。

### 4. 支持识别但暂不执行的消息

| Status | 处理 |
|---|---|
| An | 消费 2 个数据字节，不产生事件，仍可成为 running status |
| Dn | 消费 1 个数据字节，不产生事件，仍可成为 running status |
| Bn 其他 CC | 完整消费，不产生事件，不改变当前播放参数 |
| F1 / F3 | 清 running status，消费 1 个数据字节后忽略 |
| F2 | 清 running status，消费 2 个数据字节后忽略 |
| F6 | 清 running status，零数据字节，忽略 |
| F0..F7 的保留／异常项 | 按 System Common 区处理，清 pending／running；F7 正常结束 SysEx，其他孤立数据不被猜作 Note On |
| F8..FF | 最优先识别为实时区单字节，首版不产生业务事件；不中断 pending／running／SysEx skip，包括保留 F9/FD |

System Reset FF、Active Sensing FE、Clock F8 的业务功能均暂缓；不能因为名称中有 Reset 就把它当成本机清 parser 的私有命令。连接故障走独立 fault/flush 控制，不冒充支持 MIDI Active Sensing。

#### 4.1 SysEx 跳过

- F0：清 running status，进入 SKIP_SYSEX；不缓存任意长厂商数据。
- 数据字节：跳过，不输出事件。
- F8..FF：独立忽略，保持 SKIP_SYSEX。
- F7：结束 SysEx；running status 仍无效。
- 其他非实时 status：终止当前 SysEx，将该 status 重新按新消息解析，不能一直等 F7 而吞掉之后的音符。
- v1 外层包尾：结束 skip 状态，未闭合 SysEx 计异常；下包重新建立 status。

### 5. FSM 所需状态与优先级

建议状态／寄存器：WAIT_STATUS、WAIT_DATA1、WAIT_DATA2、SKIP_SYSEX；另记 status、running_status、expected_data_count、data1，以及是否为跳过的 System Common。具体编码在 RTL 阶段决定，不采用 C++ 递归读串口。

每个接受的字节按顺序处理：

1. 链路 flush／reset 优先：清解析局部状态；event FIFO 及本机清音由上层协调。
2. F8..FF：忽略业务动作，不改变普通消息拼装位置。
3. 若为新的非实时 status：终止未完成消息，再用新 status 建立解析状态；该新字节不能丢失。
4. 若在 SysEx：跳过普通数据。
5. 普通数据：仅在 pending 或合法 running status 下消费；否则丢弃并计孤立数据错误。
6. 完整消息：按支持表输出／忽略；仅 channel status 可继续作为 running status，System Common/SysEx 不能。

包尾丢弃不完整消息，不撤销同包之前已经产生的合法事件。输出 FIFO 背压不得使正在拼装的 data1 被后续字节覆盖。

### 6. 最低测试向量

| payload hex | 应有结果 |
|---|---|
| `90 3C 64 80 3C 40` | NOTE_ON 60/100，NOTE_OFF 60/64 |
| `90 3C 00` | NOTE_OFF 60/0 |
| `90 3C 64 3E 50` | 同包 running status，两条 NOTE_ON |
| `C0 05 06` | 同包 running status，两条 PROGRAM_CHANGE；注意外层 C0 需 SLIP 转义 |
| `90 3C F8 64 3E 50` | 实时插入不破坏两条 NOTE_ON |
| `90 3C FF 64` | 首版不执行 System Reset，仍得到 NOTE_ON 60/100 |
| `E0 00 40` | bend=8192 |
| `E0 00 00 E0 7F 7F` | bend=0，16383 |
| `B0 01 20 B0 07 60 B0 0B 40` | CC1／CC7／CC11 三条不同 CONTROL_CHANGE |
| `B0 40 3F B0 40 40` | 两条 CC64，消费者解释 off／on |
| `B0 7B 00 B0 78 00` | CC123 和 CC120 必须保持不同 CC 编号 |
| `D0 10 20 90 3C 64` | 两条 Channel Pressure 跳过，随后 NOTE_ON 正常 |
| `A0 3C 20 3D 30 90 40 64` | 两条 Poly Pressure 跳过，随后 NOTE_ON 正常 |
| `F0 7D 01 F8 02 F7 90 3C 64` | 跳过 SysEx／实时，保留 NOTE_ON |
| `F0 7D 01 90 3C 64` | 新 channel status 终止未闭合 SysEx，得到 NOTE_ON |
| `90 3C F2 00 00 3E 50` | 不完整 Note On 终止，F2 清 running，尾部孤立数据不发音 |
| `90 3C 90 3D 64` | 丢弃前一条不完整消息，得到 NOTE_ON 61/100 |
| 包A=`90 3C 64`，包B=`3D 64` | 包B 不继承 running status，不产生新事件 |
| 包A=`90 3C`，包B=`64` | 不跨包拼装 Note On |

还需覆盖 channel 0/15、所有 CC 值、随机 valid 间隔、事件 FIFO 满时稳定保持、复位／flush、字节级错误恢复。以上为未来验证合同，不是已经运行过的 RTL 测试。


<a id="old-timing"></a>

## 驱动分层前验证记录

### 结论与范围

**最终11项自检仿真全部通过，故障压力TB额外8个随机种子通过；独立通信探针完成真实Gowin综合／布局布线，100MHz目标setup／hold违规均为0。**

范围是 `comm_top` 及其UART、FIFO、SLIP／CRC、帧仲裁、MIDI／Config解析、来源维护和回复通路。消费者／配置后级为mock；不含真实音频核、MIDI→fmap、EQ DSP、App、HC-05实物或整机板级验收。

### 1. 统一仿真

命令：`python3 sim/run_comm.py`。

| Testbench | 结果 |
|---|---|
| tb_comm_fifo | PASS，含深度1/3/16、各5000周期随机流量 |
| tb_comm_uart | PASS，独立bit解码、8N1、偏差、坏stop、break、假起始 |
| tb_comm_uart_rates | PASS，100MHz下3Mbaud的8x/16x、230400、NCO等频边界与连续break |
| tb_comm_hc05_status | PASS，有／无STATE、去抖／复位 |
| tb_slip_frame_rx | PASS，既有向量、边界、错误、队列、pin／flush |
| tb_slip_frame_tx | PASS，既有ACK、header／CRC转义、背压／复位 |
| tb_frame_arbiter | PASS，8帧20字节、锁帧／来源／随机背压 |
| tb_midi_analyzer | PASS，215个事件，完整协议测试合同与异常边界 |
| tb_config_analyzer | PASS，参数、真实完成ACK、每源缓存／会话／取消 |
| tb_comm_top | PASS，双串口端到端；26事件、8回复、3次成功mock提交 |
| tb_comm_faults | PASS，实际RX溢出、单源隔离／重连、延迟Config完成、pinned尾事件；13事件、10回复、8次mock提交 |

所有最终compile日志无警告。`build/comm/results.json`及逐项compile/run log保留实际命令产物。不是旧core的21项回归，也没有声称重新跑音频整机测试。

`tb_comm_faults`另外用种子1、2、7、17、42、99、2026、65535复跑，全部PASS。官方模型只增加独立压力TB；集成方审查后把事件握手采样改为posedge、并发发送的payload改为automatic局部值，重新运行统一回归和多种子测试。未通过跳过断言或放宽预期来消除错误。

`python3 sim/check_comm_vectors.py`验证六组既有frame_vectors、标准库CRC、EQ字段、100个分片／粘包流、共享C0及坏转义恢复；它是样例／参考模型检查，不是硬件证明。

### 2. 最终综合／时序

命令：`python3 sim/check_comm_timing.py`。

| 项目 | 实测 |
|---|---|
| 工具 | Gowin V1.9.12.04 |
| 器件 | GW5AST-LV138FPG676AES，device B |
| 探针 | sim/synth/comm_probe.sv，BT_HAS_STATE=1，UART／业务端点可观测 |
| 目标时钟 | 100.000MHz，10.000ns |
| 报告Fmax | **100.371MHz** |
| 最差setup slack | **+0.037ns** |
| 最差hold slack | +0.214ns |
| setup / hold违规端点 | **0 / 0** |
| 分析路径／端点 | 9737 / 8922 |
| PnR Logic | 3404 |
| PnR Register | 2891 |
| BSRAM | 6 |
| 综合组合环／通用时钟布线警告 | 无／无；最终Gowin日志未发现WARN或ERROR |

报告路径：

```text
build/comm_timing/results.json
build/comm_timing/gowin.log
build/comm_timing/comm_probe/impl/pnr/comm_probe.tr
build/comm_timing/comm_probe/impl/pnr/comm_probe.rpt.txt
```

最新工具报告时间为2026-10-26 18:57:58（记录JSON为10:57:58 UTC）。增加独立WIRED_OVERSAMPLE／BT_OVERSAMPLE参数后重新综合／PnR，默认逻辑、资源与100.371MHz结果保持不变；原OVERSAMPLE参数继续作为默认继承值，未改端口或线上协议。源码清单含12份通信SV、probe SV／CST／SDC／Tcl，共16文件；构建前后与最终工作树SHA256一致。

该清单按路径排序、每行 `path + 空格 + 文件SHA256 + 换行` 的SHA256为：

```text
94069127b379a41c92a1078f99ff6e60b050abc8b813b7bd7089e26fc2ae5b49
```

单文件摘要在results.json中。RTL后续改动必须重新运行，不能继续引用此结果。

#### 时序限制

37ps余量很小。最差路径在蓝牙frame store的metadata到队列tail控制附近；布局、参数、器件／工具版本或接入真实消费者均可能改变结果。SDC只例外异步物理输入／reset，不切掉内部同步路径来制造通过。

clk的G5为当前封装的专用时钟**探针位置**，其他UART引脚工具放置，不是板卡最终引脚声明。该探针位流不得当作电子琴整机烧录交付。

### 3. 审查修复过程

官方API模型分块产出后，由集成方审阅、改动并复跑：

1. 修复NCO增量等于2^24时被截断为0的边界；break改为连续低电平计数。
2. Config reset统一异步断言，后级仍使用真正的两阶段完成握手。
3. SLIP RX的坏header／越界LEN提前discard；解码计数器从32位限缩为6位，地址按32-byte槽拼接，保持协议上限不变。
4. 发现并去除顶层 `ready→overflow→fault→flush→ready` 组合环；overflow改看占用量。
5. 大FIFO独立同步RAM读写，小回复FIFO不强制占BSRAM，资源从早期10块降至6块。
6. 消除组合环后曾实测Fmax90.279MHz、210个setup违规、hold0；该失败轮保存在 `build/comm_timing/attempt_90MHz/`。
7. 按真实关键路径，将128-bit配置缓存相等比较分成4个32-bit寄存比较结果，再在下一阶段合并；FIFO总占用量改为寄存计数，不把RAM／预取／输出的组合加法放在全局fault路径上。
8. 最终原参数100MHz重新PnR通过，随后扩展独立采样倍率参数，PnR结果不变；11项仿真与8种子故障回归通过。未改SLIP、CRC、Event32或Config线上语义，也未放宽100MHz目标。

### 4. 当前验证边界与外部接口约束

- 按PROTOCOL在会话重建清对应来源的去重缓存；不承诺断线重连后的exactly-once。
- 正确连接source清音／操作退休接口，不能因为mock测试置1就让真实消费者也直接置1。
- 未完成的EQ端点必须明确返回NOT_READY，不能在收到配置时立即假ACK。
- 当前记录未覆盖实物电平／串口波特率／HC-05 STATE、真实 router 忙状态或音频整机；独立探针结果不构成全顶层 PnR／STA 或板级端到端验收。
- 当前仅有parse_error及汇总错误诊断，不提供所有忽略消息的独立统计或v1诊断查询命令。
