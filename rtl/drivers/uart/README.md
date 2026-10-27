# UART 字节驱动

入口为 [uart_driver.sv](uart_driver.sv)。使用同一套 [RX](comm_uart_rx.sv)／[TX](comm_uart_tx.sv) 原语实现参数化 8N1 全双工通信；有线链路直接实例化，HC-05 驱动在内部独立实例化。

## 接口与状态归属

| 接口 | 定义 |
|---|---|
| `rx_i / tx_o` | UART 物理引脚；RX 的 2FF 同步在接收原语内完成 |
| `rx_valid / rx_ready / rx_data[7:0]` | RX FIFO 的输出字节流；正常背压时保持 valid/data |
| `rx_level` | 唯一 RX 字节 FIFO 的总占用量，包含预取／输出寄存器 |
| `tx_valid / tx_ready / tx_data[7:0]` | 发送字节流，握手后由 TX 完整发送；没有额外 TX 字节 FIFO |
| `tx_busy` | 当前字节尚未发送完 |
| `framing_err / break_detect / false_start / overflow` | 同域错误／诊断脉冲，不自行触发业务恢复 |
| `capture_enable` | 上层允许 RX 完整字节入队；不能暂停线上 UART 或取消正在采样的字节 |
| `flush_rx` | 同步维护清空 RX FIFO，不复位 UART 采样器，不截断当前 TX 字节 |

参数为 `CLK_HZ=100_000_000`、`BAUD=115200`、`OVERSAMPLE=16`、`RX_DEPTH=1024`。RX FIFO 使用 [comm_fifo](../common/comm_fifo.sv)，上层不得重复增加同职责的 L1 FIFO。

物理接收不可反压；新字节完成时若 `capture_enable=1` 且占用量已达 RX_DEPTH，报告 overflow。判断不依赖 `ready` 或 `flush_rx`，避免维护反馈形成组合环。沿用原设计：满队列同拍出队不额外接受新字节。

本驱动不读取 TYPE／SEQ，不处理 SLIP、来源号、MIDI、配置或音符清理。`capture_enable=0` 期间不缓存新字节；重新开放并不复位 RX 的位采样状态，上层 transport 仍依靠帧分隔符重新同步。

## 验证

从仓库根目录运行 `python3 sim/run_comm.py --test tb_comm_drivers`。测试通过独立 bit BFM 检查三路包装的 FIFO 背压、溢出、维护清理和 TX 完整发送；原语速率／采样误差／坏停止位／break 测试继续由 `tb_comm_uart`、`tb_comm_uart_rates` 覆盖。集成与时序见 [验证汇报](../../comm/VERIFICATION.md)。
