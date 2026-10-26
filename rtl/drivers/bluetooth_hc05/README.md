# HC-05 透明串口设备驱动

日期：2026-10-26。已实现 [hc05_driver.sv](hc05_driver.sv)，内部实例化通用 [uart_driver](../uart/README.md) 和 [comm_hc05_status](comm_hc05_status.sv)。与有线串口共用 UART RTL，但实例、波特率、采样和接收 FIFO 各自独立。

## 实现范围

- 参数化 8N1 原始字节 RX／TX，RX FIFO 和 framing／break／false_start／overflow 与通用驱动一致。
- 可选 STATE 的 2FF 同步、可参数化去抖、connect/disconnect 单拍事件。只报告物理事实，不自行 flush、清音、清缓存或宣布业务会话恢复。
- HAS_STATE=0 时 `link_state_known=0`、`link_up=0`，不产生连接事件；字节流仍可正常收发。STATE 不门控字节。
- 首版使用外部已配置好的透明传输模块；没有 AT 初始化、KEY／RESET／EN 控制或蓝牙协议栈。`init_done=rst_n` 只表示本地数据通路已退出复位，不代表已连接或完成 AT 配置。

## 接口

| 端口／参数 | 定义 |
|---|---|
| `CLK_HZ / BAUD / OVERSAMPLE / RX_DEPTH` | 默认 100 MHz／115200／16／1024 |
| `HAS_STATE / DEBOUNCE_CYCLES` | 默认不接 STATE；去抖默认 CLK_HZ/50 |
| `rx_i / tx_o / state_async` | HC-05 的 UART 与可选状态引脚 |
| `rx_valid / rx_ready / rx_data / rx_level` | 接收字节流与 FIFO 占用量 |
| `tx_valid / tx_ready / tx_data / tx_busy` | 发送字节流与忙状态 |
| `capture_enable / flush_rx` | 由会话控制层决定是否缓存新字节、何时清空 RX FIFO |
| `framing_err / break_detect / false_start / overflow` | 物理诊断脉冲 |
| `link_state_known / link_up` | 状态有效性与去抖后的物理连接状态；known=0 时不推断连接 |
| `connect_event / disconnect_event / init_done` | 物理边沿事件与本地透明通路就绪状态 |

驱动不携带 source_id，不识别 SLIP／CRC／TYPE／SEQ；后者由 [transport_link](../../comm/transport_link.sv) 负责。`comm_top` 将连接事件交给 session_ctrl，等待业务清理和操作退休后重开来源。

## 验证与历史

`tb_comm_drivers` 检查有／无 STATE 两个独立设备实例、字节流、背压、overflow、断开不擅自清 FIFO 和 TX 字节完整发送；STATE 原语测试和双串口端到端测试继续保留。详见 [验证汇报](../../comm/VERIFICATION.md)。当前没有 HC-05 实物或板级验收。

早期包含主机、AT、指导模式及后续设想的长篇设计见 [历史设计](archive/2026-10-26/DESIGN.md)。当前 RTL 职责以本页和 [通信集成说明](../../comm/README.md) 为准。
