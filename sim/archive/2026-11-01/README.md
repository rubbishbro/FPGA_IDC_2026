# 2026-11-01 旧通信测试归档

原路径均相对根 `sim/`。原内容保留，不作为现协议回归。

| 文件 | 已确认的不适用原因（并已实跑失败） |
|---|---|
| `unit/comm/tb_slip_frame_rx.sv`、`tb_slip_frame_tx.sv`、`tb_comm_top.sv`、`tb_comm_faults.sv`、`tb_performance_record.sv` | 构造或解码 VERSION=1、SEQ:u16、LEN:u16 帧；当前 RTL 无 VERSION，SEQ:u8、LEN:u8，录制帧 TYPE82 后接 SEQ、LEN24。 |
| `unit/comm/tb_frame_arbiter.sv` | 双源长度按 2×6 位打包；现接口为 2×7 位，源 1 长度错位并触发 mixed frame metadata。 |
| `unit/comm/tb_midi_analyzer.sv` | 旧长度上限 32，声明 len33 预期拒绝；当前支持 1..64，且长度端口已扩到 7 位。 |
| `unit/comm/tb_config_analyzer.sv` | 旧 CONFIG 上限 16、6 位长度端口契约；当前 CONFIG 上限 64/7 位长度，len17 错误分类断言已不符。 |
| `unit/comm/tb_session_ctrl.sv` | 默认实例要求协议错误隔离来源；当前 ISOLATE_PROTOCOL_ERRORS 默认 0，旧断言第一项即失败。 |
| `check_comm_vectors.py` | `<BBHH`、VERSION=1、MIDI<=32、CONFIG<=16、reply长度3，验证旧协议 fixture，不是当前线上格式。未改写其算法来掩盖协议差异。 |

旧 fixture `rtl/drivers/analyzer/frame_vectors.json` 仍被历史文档引用，未移动。归档后的 Python 脚本使用旧相对根解析方式，仅供阅读，恢复执行应先还原目录或调整 ROOT。

`run_comm.py` 现保留 6 个实跑通过的底层/限制测试；不再代表完整协议回归。新协议需要新的收发/解析/录制/集成自检来补齐覆盖，本次归档不编造通过记录。详情见 [审计](../../TEST_AUDIT_2026-11-01.md)。
