# 通信集成与协议适配

驱动分层日期：2026-10-26；2026-10-27 文档核对并重跑 13 项回归通过。入口为 [comm_top.sv](comm_top.sv)，对外端口、参数默认值和线上 v1 协议保持兼容。源码统一列在 [sim/comm_sources.f](../../sim/comm_sources.f)，仿真、Gowin 综合和时序源码哈希均读取该清单。

```text
有线 UART 引脚 ↔ uart_driver ───────↔ transport_link[0] ─┐
                                                        ├↔ frame_arbiter / 回复路由
HC-05 引脚 ↔ hc05_driver ───────────↔ transport_link[1] ─┘             │
                └─ uart_driver                             parser_dispatch
                └─ STATE 同步/去抖                          ├─ midi_analyzer
                                                           └─ config_analyzer
                         session_ctrl 协调各层隔离与恢复
```

## 责任边界

| 层 | 拥有的状态／资源 | 对外提供 |
|---|---|---|
| [uart_driver](../drivers/uart/README.md) | UART RX/TX 位状态、每路唯一的 RX 字节 FIFO | 原始字节流、物理错误 |
| [hc05_driver](../drivers/bluetooth_hc05/README.md) | 独立 UART 驱动实例、STATE 同步／去抖 | 字节流、物理连接事件／状态有效性 |
| [transport_link](transport_link.sv) | SLIP／CRC、候选与已提交帧存储、深度 2 回复队列、回复编码状态 | 已验证帧流、协议错误、TX 字节 |
| [frame_arbiter](frame_arbiter.sv)／顶层回复路由 | RR 与帧锁定；按来源转发回复 | 带来源的帧流、按链路送达的回复描述符 |
| [analyzer](../drivers/analyzer/README.md) | TYPE 分发、MIDI 状态、Config shadow／去重／在途请求 | MIDI 事件、配置请求、最终回复语义 |
| [session_ctrl](session_ctrl.sv) | 每来源隔离、重启请求、待退休事件数、诊断计数 | cancel／flush／cache_reset 等维护命令 |
| `comm_top` | 实例连接、共享事件 FIFO、准入／回复路由和屏障组合条件 | 保持原有的系统接口 |

设备与单路 transport 不持有 source_id；来源由物理入口在帧仲裁处添加，原样通过事件／配置／回复链路。事件 FIFO 是 33 bit，Event32 的保留位不变。

## 顶层接口与默认参数

[comm_top.sv](comm_top.sv) 使用系统 `clk/rst_n`，复位由平台保证异步置位／同步释放。`rx_i[0]/tx_o[0]` 是有线，`rx_i[1]/tx_o[1]` 是 HC-05 UART。

| 参数 | 默认值／含义 |
|---|---|
| `CLK_HZ` | 100_000_000 |
| `WIRED_BAUD / BT_BAUD` | 各 115200，独立配置 |
| `OVERSAMPLE` | 16；`WIRED_OVERSAMPLE/BT_OVERSAMPLE` 各自默认继承，可独立设置 |
| `RX_DEPTH / FRAME_DEPTH / EVENT_DEPTH` | 每路 RX 1024 字节、每路已提交帧 8、共享事件 64 |
| `TIMEOUT_CYCLES` | CLK_HZ，即默认 1 秒的半帧字节间超时 |
| `EQ_BANDS` | 3，只决定配置段号校验，不代表已有 EQ DSP |
| `BT_HAS_STATE / STATE_DEBOUNCE_CYCLES` | 0／CLK_HZ÷50；缺少 STATE 时不推断物理连接 |

| 顶层接口 | 接入合同 |
|---|---|
| `event_valid/event_ready/event_data[31:0]/event_source_id` | 消费者事件流；来源独立侧带，Event32 保留位全 0 |
| `midi_ops_idle` | 此前已经出队的 MIDI 操作真正完成，不表示所有音符衰减结束 |
| `cfg_valid/cfg_ready` 及 `cfg_source_id/cfg_seq/cfg_command/cfg_payload_len/cfg_shadow` | 原子配置请求；shadow byte0 位于 [7:0]，长度单位为字节 |
| `cfg_done_valid/cfg_done_ready/cfg_result` | 真实后级完成；结果码为协议 0..6，即使零延迟也须保持到握手 |
| `source_quarantine/link_fault_pending[1:0]` | 来源维护状态，保持到有序恢复；消费者不得继续将隔离来源的旧事件发声 |
| `source_cleanup_done/source_ops_idle[1:0]` | 真实消费者确认音符／踏板已清理、已接受操作已退休，不应未经处理直接绑 1 |
| `session_restart[1:0]` | 显式会话重建请求；可选 STATE connect 也会提出蓝牙重建请求 |
| `error_sticky[15:0]` | 每源 8 位，从低到高为 SLIP、LEN、CRC、VERSION/TYPE、半帧超时、framing、break、RX overflow |
| `rx_error_count[63:0]` | 每源 32-bit 饱和的错误时钟周期数，同拍多个错误只加一次，具体原因由 sticky 保留 |
| `midi_parse_error` | MIDI 语法错误单拍诊断；false_start 只在 UART 驱动提供，不自动触发会话隔离 |

帧 payload 直接写入 32-byte 槽，每路另有一个候选槽；每路回复描述符 FIFO 固定深度 2。大 FIFO／帧存储为同步 RAM 读，预取与 pop 允许气泡。没有物理流控时，有限缓冲不能保证无限突发不溢出。

## transport 接口

- RX 字节：`rx_valid/rx_ready/rx_data[7:0]`；TX 字节：`tx_valid/tx_ready/tx_data[7:0]`。
- 帧输出：`frame_valid/frame_ready/frame_data[7:0]`，附 `frame_first/frame_last/frame_type[7:0]/frame_seq[15:0]/frame_payload_len[5:0]`。完整帧通过版本／类型／长度／CRC 后才可见，payload 仍按字节读取。
- 回复输入：`reply_valid/reply_ready/reply_seq/reply_command/reply_result`；按既定 TYPE80／LEN3 编码，不判断 command 是否正确或 result 是否成功。
- `protocol_errors[7:0]`：低 5 位依次为 SLIP、长度、CRC、版本／类型、半帧超时。
- `flush/pin`：同步维护。flush 丢弃候选和未授权帧；pin=1 时保留已锁定队头到最后一次 payload 握手。回复队列和编码器同步清理；UART 完成已经接受的字节。

正常 valid/ready 背压保持数据与附属元数据，reset／显式维护为取消例外。每路持有独立 SLIP、CRC 和帧存储，不在字节层混合来源。

## 会话与顺序

`session_ctrl` 接收物理错误、协议错误及连接事件，不通过层级路径访问 FIFO／parser 状态。集成层通过入队／出队握手、arbiter/parser busy 与来源、消费者 `source_ops_idle/source_cleanup_done` 提供恢复证据。

1. framing／break／overflow／半帧超时／物理断开使对应来源隔离；CRC／转义／长度错误只丢弃候选并诊断。
2. 同拍的 `cancel_source` 禁止新帧准入、抑制新配置提交／旧回复并丢弃该来源的排队事件。`flush_link` 清理对应驱动与 transport；已 pin 的帧继续收束。
3. 已被后级接受的配置必须等真实结果；parser 忙状态包含这段退休等待。共享效果已经生效时，不因单源故障回滚。
4. 来源事件计数为 0、帧与 parser 均退休、消费者清理／操作完成，且已锁存重启请求后，解除隔离并脉冲 `cache_reset`，清该来源 Config 重试缓存及旧链路状态。

物理 connect 只提出重启请求，不绕过业务清理；无 STATE 时不生成自动连接事件。物理断开本身不计入原有 error_sticky 的 8 位布局。

配置屏障由顶层计算：`event FIFO empty && midi_ops_idle`。最后一个 payload 字节完成只释放帧锁，parser 的 frame_done 才允许下一帧进入。CONFIG 的回复准入沿用单个配置在途、单一回复生产者条件；不承诺慢后级期间另一来源的解析也能独立前进。

## 验证与边界

```bash
python3 sim/run_comm.py
python3 sim/check_comm_vectors.py
GOWIN_SH=/home/rubbishbro/gowin/IDE/bin/gw_sh python3 sim/check_comm_timing.py
```

13 项仿真、8 个故障种子和重构后的独立探针 PnR 结果见 [验证汇报](VERIFICATION.md)。没有新增 AT 初始化、TX 字节 FIFO 或线上命令；真实 MIDI→fmap、EQ／混响后级和板级端点仍由调用者提供。线上字段和结果码见 [协议 v1](../drivers/analyzer/PROTOCOL_V1.md)，MIDI Event32 与 Config 子模块握手见 [解析说明](../drivers/analyzer/README.md)。

与当前侧栏的统一配置口还未直连：comm 的 source_id/SEQ/command/shadow 需显式转换为统一请求并保留回复上下文。sidebar 的外部来源槽不能区分两条物理链路，远程权限/会话恢复应在保留物理来源的适配端执行。
